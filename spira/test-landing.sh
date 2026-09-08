#!/usr/bin/env bash
#
# test-landing.sh — a landing pass may put finished work back on the board only when the
# work itself disagrees with the base.
#
#   ./test-landing.sh
#
# THE CASE THIS IS WRITTEN FOR. A pass reads its branch list once and then runs for minutes,
# so by the time it reaches the tail of that list the head of it may be gone. The Sending
# reaps a landed branch on its own timer, and `rebase_branch` against a ref that is no longer
# there fails with exactly the exit status and exactly the empty conflict list that a real
# disagreement produces:
#
#   21:51:17  landed spira/<id>                      pass A lands it
#   21:52:13  landing: starting a pass               pass B enumerates, <id> still present
#   21:52:36  REMOVED branch spira/<id>              the Sending reaps it
#   22:00:51  landed spira/<other>                   pass B is eight minutes into one gate
#   22:00:55  reopened <id> — does not rebase onto origin/main; conflicts in unknown
#
# Nothing recreated that ref and nothing needed to: the branch list was twenty-three seconds
# older than the reap, refs sort by name, and the branch ahead of it in the list held the
# pass for eight minutes. "conflicts in unknown" is the tell — a real conflict names files.
# The cost is a whole session: an aeon is summoned onto a bead whose work is already on the
# base, finds nothing to rebase, and learns that.
#
# So the property under test is not "the reaped branch is skipped" but the stronger one the
# skip is a special case of: A REOPEN REQUIRES AN ATTRIBUTED CONFLICT. Both routes into a
# reopen are exercised, the classification they rest on is exercised directly, and a genuine
# conflict is required to still reopen — without that last one every silence here is vacuous.
#
# The database is a REAL bd on a fixture dropped by a trap and git is real, with a real bare
# remote, because every claim is about ancestry, about what `git rebase` does against a ref
# that is not there, and about a bead's status afterwards. `gate.sh` and `confine.sh` are
# stubs: each has its own suite, and what is under test here is what landing does with a
# verdict, not how one is reached. The gate stub is also the clock — it is the only point in
# the pass this suite can reach, and reaping a branch from inside it reproduces the real
# sequence exactly rather than approximating it.
#
# covers: spira/landing.sh spira/lib.sh spira/incident.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-landing
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up landing || { echo "test-landing: could not build a fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
REPONAME=fixture-repo
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree" "$SH"

# conf.sh travels with lib.sh — lib.sh refuses to run without it, and a harness that copies
# one and not the other fails at source time, which reads as landing being broken.
# incident.sh IS THE REAL ONE, not a stub. The claim under test is "one incident, however
# many branches and however many passes", and that dedupe is incident.sh's dedupe on the
# external ref — a stub would reproduce the surface remembered here and prove nothing about
# it (law-prefer-the-real-dependency). What landing.sh owns is the KEY it hands over; what
# the intake owns is finding the open bead under it, and both have to hold for the count to
# stay at one.
cp "$HERE/landing.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/incident.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub confine.sh 'exit 0'

# THE GATE IS ALSO THE REAPER, and that is the whole fixture. A pass holds its branch list
# across the gate, which is the only long call in it, so a branch removed from inside the
# stub is removed at precisely the point the Sending removed the real one — after the list
# was read and before the loop reached the tail of it. Anything staged outside the pass would
# be testing a list that was stale before it was taken, which is a different bug.
#
# It speaks the gate's PROTOCOL, not just its exit status: landing.sh reads the VERDICT line
# for the reason it records.
stub gate.sh '
r="$SPIRA_RUN/reap-during-gate"
if [ -s "$r" ]; then
    while read -r id; do
        [ -n "$id" ] || continue
        git -C "'"$REPO"'" worktree remove --force "'"$RUN"'/worktree/$id" >/dev/null 2>&1
        git -C "'"$REPO"'" branch -D "spira/$id" >/dev/null 2>&1
    done < "$r"
    : > "$r"
fi
# THE TIP AS THE LOOP SAW IT. The gate is the last thing the loop does to a branch, so the
# tip recorded here is the branch as the loop left it — and anything that moves it afterwards
# moved it after the loop had walked past. That is the whole discriminator for the sweep
# below: without it "the branch is on the base" is true whether the loop rebased it or the
# sweep did, and the case would pass against a landing.sh with no sweep in it at all.
mkdir -p "$SPIRA_RUN/tip-at-gate"
git -C "'"$REPO"'" rev-parse "$1" > "$SPIRA_RUN/tip-at-gate/${1//\//-}" 2>/dev/null
# A WITHHELD VERDICT, which is what leaves a branch judged, rebased and standing. The
# repository gate tree being busy is far and away the commonest way a real pass walks past a
# branch it will not reach again, and it is the state every sweep case starts from. The
# status is the protocol constant, not a literal: a fixture asserting against 75 would go on
# passing if landing.sh stopped meaning 75 by it.
w="$SPIRA_RUN/withhold-gate"
if [ -s "$w" ] && grep -qx "$1" "$w"; then
    echo "gate: VERDICT=NO_VERDICT reason=stub-busy branch=$1 repo=${2:-?}" >&2
    exit "${SPIRA_GATE_NOVERDICT:?the gate protocol constant is not in the environment}"
fi
# AN AEON ARRIVING MID-PASS, on the PASS path only — so it lands in the window between the
# loop walking past an earlier branch and the landing that sweeps it, which is the window the
# sweep repeats its own liveness check for. Each line is "<bead> <pid>"; the pid belongs to a
# process the suite started, because aeon_alive reads /proc and will not be fooled by a
# pidfile naming something that is not a runner.
c="$SPIRA_RUN/claim-during-gate"
if [ -s "$c" ]; then
    while read -r id pid; do
        [ -n "$id" ] || continue
        printf "%s\\n" "$pid" > "$SPIRA_RUN/aeon-builder-$id.pid"
    done < "$c"
    : > "$c"
fi
echo "gate: VERDICT=PASS reason=${GATE_REASON:-stub} branch=$1 repo=${2:-?}" >&2; exit 0'

# gh IS NEVER REACHED FROM A SUITE. pr_merged sits on the path to a reopen, and left to the
# real binary it would decide a verdict here from whether this box happens to be logged in
# to a forge — the ambient configuration law-gates-run-in-a-clean-environment names. A stub
# that always fails is the honest fixture: this repository lands by push and has no pull
# requests, so "no merged pull request" is the true answer.
stub gh 'exit 1'

B() { bd -C "$SPIRA_DB" "$@"; }
status_of() { B show "$1" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(d[0].get("status") or "")'; }

landing() {
    rm -f "$RUN/landing.progress"
    # SPIRA_REPO_MAP EXPLICITLY and nothing else inherited: a pass that falls back reads the
    # repositories the operator has registered and counts THEIR branches, so a suite
    # asserting about one fixture branch would be asserting about a box.
    # AND THE ESCALATION CHANNEL IS PINNED SHUT. Two paths out of this pass reach the
    # operator — the repeated-NO_VERDICT ask and the intake's Sin escalation — and both
    # resolve their command from configuration. Left unpinned a suite inherits whatever this
    # box has installed there and puts a fixture's verdict in a real pane
    # (law-gates-run-in-a-clean-environment).
    # SPIRA_HOME_REPO IS PINNED, AND TO A NON-DEFAULT. conf.sh only derives it when it is
    # unset, so an aeon session that exports it hands this pass the name of a real repository
    # — and the incident below is labelled `repo:<name>`, so the suite would file a fixture's
    # finding against somebody's actual checkout and then assert against whatever leaked.
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_HOME_REPO="$REPONAME" \
    SPIRA_REPO_MAP="$SH/repo-map" SPIRA_GH="$SH/gh" \
    SPIRA_NOTIFY="$TMP/no-such-ask.sh" SPIRA_ASK="$TMP/no-such-ask.sh" \
        bash "$SH/landing.sh" 2>&1
}
notes_of() { B show "$1" 2>/dev/null; }

seed() {
    testdb_reset
    rm -rf "$RUN/tip-at-gate"; rm -f "$RUN/withhold-gate" "$RUN/claim-during-gate"
    testdb_seed <<'JSONL'
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
}
withhold_gate() { printf 'spira/%s\n' "$@" > "$RUN/withhold-gate"; }
claim_during_gate() { printf '%s %s\n' "$1" "$2" > "$RUN/claim-during-gate"; }
tip_at_gate()   { cat "$RUN/tip-at-gate/spira-$1" 2>/dev/null; }
tip_of()        { git -C "$REPO" rev-parse "spira/$1" 2>/dev/null; }
on_base()       { git -C "$REPO" merge-base --is-ancestor origin/main "spira/$1" 2>/dev/null && echo yes || echo no; }
branch() {               # branch <id> [file] [content] — a closed bead with a branch of its own
    local id="$1" f="${2:-$1.txt}" c="${3:-$1}"
    git -C "$REPO" worktree add -q -b "spira/$id" "$RUN/worktree/$id" main
    printf '%s\n' "$c" > "$RUN/worktree/$id/$f"
    git -C "$RUN/worktree/$id" add -A
    git -C "$RUN/worktree/$id" commit -q -m "feat: $id — work"
    printf '{"id":"%s","title":"%s","status":"closed","issue_type":"task","labels":[],"updated_at":"2026-09-04T00:00:00Z","closed_at":"2026-09-04T00:00:00Z","dependencies":[{"issue_id":"%s","depends_on_id":"sp-goal","type":"parent-child"}]}\n' \
        "$id" "$id" "$id" | testdb_seed
}
drop_branch() {
    local id="$1"
    git -C "$REPO" worktree remove --force "$RUN/worktree/$id" >/dev/null 2>&1
    git -C "$REPO" branch -D "spira/$id" >/dev/null 2>&1
}
reap_during_gate() { printf '%s\n' "$@" > "$RUN/reap-during-gate"; }

echo "test-landing.sh"

# --------------------------------------------------------------------------------------
# THE POSITIVE CONTROL, first, because every silence below is read against it: this pass can
# land, and it can reopen. A suite whose assertions are all "did not happen" passes just as
# well against a landing.sh that does nothing at all.
# --------------------------------------------------------------------------------------
seed; branch sp-plain; out="$(landing)"
want "an uncontested land is reported" "landed spira/sp-plain" "$out"
drop_branch sp-plain

# THE VERDICT CACHE IS PRUNED BY THE PASS, at the age the gate refuses to read at. The gate
# computes each verdict once and reuses it, so what accumulates here is one file per gated
# tree, forever; the pass is the only thing that runs on a clock and already touches every
# repository, which is why the janitor lives in it.
#
# THE AGE IS THE CONFIGURED ONE and that is the whole point of the case: two numbers here —
# a reader's and a janitor's — would be two answers to how long a verdict lives, and the
# operator would have tuned one of them. Pinned to a non-default, because asserting against
# the shipped default passes just as well against a literal written into the code.
# AND A REUSED VERDICT IS VISIBLE IN THE PASS. The gate returns the same status either way,
# so without this line a pass that skipped every gate and one that ran every gate read
# identically — and "nothing is being reused any more" is the first symptom of a key that has
# stopped matching anything, which otherwise looks exactly like a busy queue.
seed; branch sp-reused
out="$(GATE_REASON=cached landing)"
want "a pass says when a gate was skipped" "this tree had already passed, so no suite ran" "$out"
want "and still lands the branch"          "landed spira/sp-reused" "$out"
drop_branch sp-reused
# bash keeps a temporary assignment to a FUNCTION set after the call returns, so every later
# pass in this suite would go on claiming a reused verdict.
unset GATE_REASON

export SPIRA_VERDICT_TTL=600
mkdir -p "$RUN/verdicts"
: > "$RUN/verdicts/stale"; touch -d '3 hours ago' "$RUN/verdicts/stale"
: > "$RUN/verdicts/fresh"
seed; landing >/dev/null 2>&1
[ -e "$RUN/verdicts/stale" ] && bad "a verdict past the TTL is deleted by a pass" "stale entry survived" \
    || ok "a verdict past the TTL is deleted by a pass"
[ -e "$RUN/verdicts/fresh" ] && ok "and one inside it is kept" \
    || bad "and one inside it is kept" "the pass deleted a live verdict"
unset SPIRA_VERDICT_TTL

# A REAL DISAGREEMENT STILL REOPENS. The branch and the base both write the same file with
# different content after they diverged, so the rebase genuinely conflicts and the bead
# genuinely belongs back on the board. Everything below asserts that a reopen did NOT happen;
# this is what makes those assertions mean something.
seed; branch sp-clash shared.txt "from the branch"
printf '%s\n' "from the base" > "$REPO/shared.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "base writes shared.txt"
git -C "$REPO" push -q origin main; git -C "$REPO" fetch -q origin
out="$(landing)"
want "a branch that truly conflicts is reopened"   "reopened sp-clash" "$out"
is   "and its bead goes back to open"              open "$(status_of sp-clash)"
want "and the note names the file that collided"   "shared.txt" "$(notes_of sp-clash)"
drop_branch sp-clash

# --------------------------------------------------------------------------------------
# THE CASE ITSELF: landed on one pass, reaped during the next, reached from a stale list.
#
# sp-aaa sorts before sp-zzz and refs are enumerated by name, so the pass is inside sp-aaa's
# gate when sp-zzz's ref goes — which is where the real one went. sp-zzz's work is already on
# the base by then, exactly as the reaped branch's was.
# --------------------------------------------------------------------------------------
seed; branch sp-zzz; out="$(landing)"
want "the branch lands on the first pass" "landed spira/sp-zzz" "$out"
git -C "$REPO" fetch -q origin
zzz_tip="$(git -C "$REPO" rev-parse spira/sp-zzz)"
git -C "$REPO" merge-base --is-ancestor "$zzz_tip" origin/main \
    && ok  "and its commit is on the base before the second pass begins" \
    || bad "the fixture" "sp-zzz did not actually land"

branch sp-aaa; reap_during_gate sp-zzz; out="$(landing)"
nowant "a branch reaped mid-pass is not reopened as a conflict" "reopened sp-zzz" "$out"
is     "and its bead stays closed"                              closed "$(status_of sp-zzz)"
nowant "and no note claims a conflict it never had"             "conflicts in unknown" "$(notes_of sp-zzz)"
want   "and the pass names the branch it lost"                  "spira/sp-zzz is gone since this pass began" "$out"
want   "and says the commit is on the base, not merely that it is gone" \
       "$zzz_tip is on origin/main — landed and reaped" "$out"
want   "the branch that held the pass still landed"             "landed spira/sp-aaa" "$out"
drop_branch sp-aaa

# A BRANCH REMOVED WITH WORK STILL ON IT READS DIFFERENTLY, and it has to. Both cases end in
# the same non-action, so a single line covering both would report a destroyed branch in the
# words used for the ordinary reap — the reassuring reading, given for free, to the one case
# that deserves a look.
seed; branch sp-lost; branch sp-bbb; reap_during_gate sp-lost
lost_tip="$(git -C "$REPO" rev-parse spira/sp-lost)"
out="$(landing)"
nowant "a branch slain mid-pass is not reopened either" "reopened sp-lost" "$out"
is     "and its bead stays closed"                      closed "$(status_of sp-lost)"
want   "but the pass says its work is NOT on the base"  "$lost_tip is NOT on origin/main" "$out"
drop_branch sp-bbb

# --------------------------------------------------------------------------------------
# THE SECOND ROUTE INTO A REOPEN. Losing the push race sends the pass back through
# rebase_branch, and that arm falls through to "branch conflicts with the base" — so a ref
# reaped between the losing push and the replay is reported as a disagreement that never
# happened, the identical defect by a different path. Two guards were needed and only one of
# them is on the path the first case takes.
# --------------------------------------------------------------------------------------
cat > "$REMOTE/hooks/pre-receive" <<HOOK
#!/usr/bin/env bash
# Reject the first push only, and remove the branch behind the pusher's back as it goes —
# the Sending running on its own timer, arriving in the one window this arm occupies.
#
# OUTSIDE THE QUARANTINE. A pre-receive hook runs with GIT_QUARANTINE_PATH set and git
# refuses to touch refs from inside it, so a hook that does not clear the environment
# changes nothing and the case passes against the bug it is written for.
[ -f "\$GIT_DIR/rejected-once" ] && exit 0
: > "\$GIT_DIR/rejected-once"
env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_DIR \\
    bash -c '
      git -C "$REPO" worktree remove --force "$RUN/worktree/sp-raced" >/dev/null 2>&1
      git -C "$REPO" branch -D spira/sp-raced >/dev/null 2>&1
    ' >&2 || echo "the hook could not remove the branch" >&2
echo "rejected once, on purpose" >&2
exit 1
HOOK
chmod +x "$REMOTE/hooks/pre-receive"
seed; branch sp-raced; out="$(landing)"
rm -f "$REMOTE/hooks/pre-receive" "$REMOTE/rejected-once"
want   "the push is rejected, as the case requires"        "push rejected" "$out"
nowant "and a branch gone by the retry is not a conflict"  "reopened sp-raced" "$out"
is     "and its bead stays closed"                         closed "$(status_of sp-raced)"
want   "and the retry says it could not attempt a rebase"  "the retry could not attempt a rebase of spira/sp-raced" "$out"
want   "naming the reason rather than a file list"         "(no-branch)" "$out"
drop_branch sp-raced

# --------------------------------------------------------------------------------------
# A BASE THAT FAILS ITS OWN GATE: THE BRANCH IS HELD, THE REPOSITORY IS CHARGED
#
# The gate has said "it fails against the base too — this branch did not cause it" since
# BASE_FAIL existed, and the pass already declines to reopen on it. What it did with that
# sentence afterwards was nothing: a log line saying the next pass would take it, said again
# every two minutes, while every branch of the repository sat behind a red nobody owned.
#
# So three properties, and the third is what makes the first two worth anything. The branch
# is held rather than reopened; ONE incident is filed however many branches are behind the
# same red and however many passes go by; and the held branch lands on the pass after the
# base is green, which is the whole reason holding is the right answer rather than refusing.
#
# The gate stub speaks BASE_FAIL's protocol — status 76 and the anchored VERDICT line with
# its suite — because that line is the contract landing.sh reads, and reading it from prose
# is the thing the bead forbids.
# --------------------------------------------------------------------------------------
echo
BASE_SUITE=test-fx-base.sh
stub gate.sh '
echo "gate: the fixture repository gate failed: '"$BASE_SUITE"' FAILED" >&2
echo "gate: it fails against origin/main too — this branch did not cause it." >&2
echo "gate: VERDICT=BASE_FAIL reason=base-red branch=$1 repo=${2:-?} suite='"$BASE_SUITE"'" >&2
exit 76'

# Every open bead in the builder partition for this repository — by LABEL, not by the dedupe
# ref, so a second filing under a DIFFERENT ref is counted rather than hidden. Counting the
# ref alone would report "still one" against exactly the bug this case is written for.
incidents() {
    B list --status open,in_progress --limit 0 --label "spira,plan,repo:$REPONAME" --json 2>/dev/null \
      | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
for i in (d if isinstance(d, list) else [d]): print(i["id"])'
}
n_lines() { printf '%s' "$1" | grep -c . || true; }

seed; branch sp-held; branch sp-heldtoo
out="$(landing)"
want   "a base that fails its own gate holds the branch" \
       "gate: held — the base fails its own gate" "$out"
want   "and the hold names the suite the gate named"     "suite $BASE_SUITE" "$out"
nowant "the bead is not reopened"                        "reopened sp-held" "$out"
is     "and stays closed"                                closed "$(status_of sp-held)"
nowant "nor is the second branch behind the same red"    "reopened sp-heldtoo" "$out"
nowant "and nothing is landed on a withheld verdict"     "landed spira/sp-held" "$out"

inc="$(incidents)"
is "one incident is filed for the repository" 1 "$(n_lines "$inc")"
inc_id="$(printf '%s\n' "$inc" | head -1)"
if [ -n "$inc_id" ]; then
    shown="$(B show "$inc_id" 2>&1)"
    want "it names the failing suite"                  "$BASE_SUITE" "$shown"
    want "and the repository whose base is red"        "$REPONAME" "$shown"
    want "and says no bead was reopened or charged"    "no attempt charged" "$shown"
    want "and carries the gate's own output"           "this branch did not cause it" "$shown"
    labels="$(B label list "$inc_id" 2>&1)"
    want "it lands in the builders partition"          "plan" "$labels"
    want "labelled with the repository"                "repo:$REPONAME" "$labels"
fi

# THE SECOND PASS IS THE IDEMPOTENCE. Nothing is reseeded: the same two branches meet the
# same red, and a pass that filed per branch or per pass would have four beads by now.
out2="$(landing)"
is   "a second pass files no second incident"  1 "$(n_lines "$(incidents)")"
want "it bumps a recurrence on the first"      "sp-recur-2" "$(B label list "$inc_id" 2>&1)"
want "and holds the branch again"              "gate: held — the base fails its own gate" "$out2"
is   "with the bead still closed"              closed "$(status_of sp-held)"

# AND THE HOLD IS A HOLD, NOT A LOSS. Holding is only the right answer if the work still
# lands once the base is fixed; without this the case above is equally satisfied by a pass
# that quietly dropped the branch on the floor.
stub gate.sh 'echo "gate: VERDICT=PASS reason=stub branch=$1 repo=${2:-?} suite=-" >&2; exit 0'
out3="$(landing)"
want "a held branch lands on the pass after the base is green" "landed spira/sp-held" "$out3"
want "and so does the one behind it"                           "landed spira/sp-heldtoo" "$out3"
drop_branch sp-held; drop_branch sp-heldtoo

# --------------------------------------------------------------------------------------
# THE CLASSIFICATION BOTH GUARDS REST ON. rebase_branch returns 1 four ways and only one of
# them is a fact about the branch; before it said which, every caller that reopens on a
# rebase failure reopened for all four. Asserted directly, because the pass can only be
# steered into two of these and a guard reading a value nothing pins is a guard on a comment.
# --------------------------------------------------------------------------------------
classify() {             # classify <branch> <onto> -> the recorded failure kind, or "clean"
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_REPO_MAP="$SH/repo-map" \
    bash -c '. "$1/lib.sh" >/dev/null 2>&1
             if rebase_branch "$2" "$3" "$4" fixture >/dev/null 2>&1
             then printf clean; else printf "%s" "${REBASE_FAILURE:-unset}"; fi' \
        _ "$SH" "$1" "$2" "$REPO" 2>/dev/null
}
seed; branch sp-kind
is "a ref that is not there is named no-branch" no-branch "$(classify spira/sp-nothere origin/main)"
is "a base that does not resolve is named no-base" no-base "$(classify spira/sp-kind refs/heads/no-such-base)"
is "a branch that rebases cleanly records no failure" clean "$(classify spira/sp-kind origin/main)"
drop_branch sp-kind

seed; branch sp-kindclash shared.txt "from the branch"
printf '%s\n' "and the base disagrees" > "$REPO/shared.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "base writes shared.txt again"
git -C "$REPO" push -q origin main; git -C "$REPO" fetch -q origin
is "and a real disagreement is named conflict" conflict "$(classify spira/sp-kindclash origin/main)"
drop_branch sp-kindclash

# THE FENCE. Every route from a rebase failure to a reopen lives in landing.sh and must read
# the classification first; the two above are the ones that exist today and a third would
# arrive silently. It requires each `! rebase_branch` arm to mention REBASE_FAILURE within
# the handful of lines that follow — the cheap check for the shape, rather than for a
# behaviour a future arm would not yet have.
#
# COMMENTS AND BLANK LINES ARE NOT COUNTED toward the window. They are the bulk of this
# repository by design, and a window measured in raw lines put the guard eight lines below an
# arm it sits directly under — a fence that fires on every correctly written arm is deleted
# by the second person who meets it.
arms() {                 # arms <file> -> "line" per rebase_branch failure arm that ignores the kind
    awk '
        { c = $0; sub(/#.*/, "", c) }
        c ~ /^[ \t]*$/ { next }
        n { if (c ~ /REBASE_FAILURE/) guarded = 1
            if (++k >= 6) { if (!guarded) print "line " n; n = 0 } }
        c ~ /![ \t]*rebase_branch/ { n = NR; k = 0; guarded = 0 }
        END { if (n && !guarded) print "line " n }' "$1"
}
is "every rebase failure arm in landing.sh reads the kind" "" "$(arms "$HERE/landing.sh")"

# ITS OWN POSITIVE CONTROL. A grep reporting a clean file looks the same whether it fired or
# never could, and the value of this fence is entirely in its silence.
printf '%s\n' 'if ! rebase_branch "$br" "$base"; then' '    bead_reopen "$id" "conflicts"' 'fi' > "$TMP/plant.sh"
want "and the fence can see an arm that does not" "line 1" "$(arms "$TMP/plant.sh")"

# --------------------------------------------------------------------------------------
# THE SURVIVORS ARE REBASED WHEN THE BASE MOVES, not when some later pass reaches them.
#
# The loop rebases a branch immediately before gating it, so a branch is never gated stale.
# What it does not do is go back: a branch it has already walked past — because the gate tree
# was busy and no verdict was reached — keeps the base it was rebased onto while the pass
# lands other branches on top of it. It is then behind until a later pass reaches it, which
# has been as long as eighty-five minutes and several landings, ending in "reopened <bead> —
# does not rebase onto the base" for a branch nobody had touched. Eleven of those in one day
# and twelve the next, each a finished bead back on the board and an agent session spent.
#
# THE DISCRIMINATOR IS THE TIP AT GATE TIME. "The branch is on the base afterwards" is true
# whether the loop rebased it or the sweep did, so on its own it passes against a landing.sh
# with no sweep at all. The gate stub records the tip as the loop left it; the assertion is
# that the tip MOVED after that, which only the sweep can do.
# --------------------------------------------------------------------------------------
seed; branch sp-held held.txt; branch sp-lands lands.txt
withhold_gate sp-held                    # sorts first, so the loop walks past it, then lands sp-lands
out="$(landing)"
want "the branch whose gate was withheld is not landed" "gate NO_VERDICT on spira/sp-held" "$out"
want "and the branch behind it lands"                   "landed spira/sp-lands" "$out"
want "the survivor is rebased onto the new base at once" \
     "rebased spira/sp-held onto origin/main after landing spira/sp-lands" "$out"
is   "and its tip moved after the loop had walked past it" \
     moved "$([ "$(tip_at_gate sp-held)" != "$(tip_of sp-held)" ] && echo moved || echo "same as at gate time")"
is   "so it now carries the commit that landed"         yes "$(on_base sp-held)"
nowant "and a clean rebase never reopens the bead"      "reopened sp-held" "$out"
is   "which stays closed"                               closed "$(status_of sp-held)"
want "and the pass counts what the sweep did"           "1 survivor(s) rebased after a landing, 0 conflicted" "$out"
drop_branch sp-held; drop_branch sp-lands

# THE SWEEP MUST STILL REOPEN A REAL DISAGREEMENT, or the silence above is worth nothing: a
# sweep that swallowed conflicts would pass every assertion in the case above and quietly
# leave unlandable work sitting closed forever. Both branches create the same file with
# different content, so once one of them is on the base the other genuinely cannot replay.
seed; branch sp-cheld shared.txt "from the held branch"
branch sp-clands shared.txt "from the branch that lands"
withhold_gate sp-cheld
out="$(landing)"
want "the branch behind it still lands"            "landed spira/sp-clands" "$out"
want "and the survivor that truly conflicts is reopened" "reopened sp-cheld" "$out"
is   "its bead goes back to open"                  open "$(status_of sp-cheld)"
want "the note names the file that collided"       "shared.txt" "$(notes_of sp-cheld)"
want "and names the landing that moved the base"   "after spira/sp-clands landed" "$(notes_of sp-cheld)"
want "and the pass counts the conflict separately" "0 survivor(s) rebased after a landing, 1 conflicted" "$out"
drop_branch sp-cheld; drop_branch sp-clands

# A BRANCH AN AEON TOOK WHILE THE PASS RAN IS NEVER REWRITTEN. Minutes pass between the loop
# judging a branch and a landing that triggers the sweep — a whole gate run — and in that
# window a bead can be reopened elsewhere and claimed. Rebasing rewrites commits beneath a
# live worktree and destroys work that exists in exactly one place, which is the one failure
# here that nothing can undo, so the liveness check is repeated at sweep time rather than
# inherited from the loop.
seed; branch sp-taken taken.txt; branch sp-tlands tlands.txt
withhold_gate sp-taken
# A REAL PROCESS RUNNING A FILE ACTUALLY CALLED aeon.sh: aeon_alive reads /proc/<pid>/cmdline
# and requires the runner's own name in it, so a fixture that invented a pid would assert the
# guard fires where the guard would in fact have seen nobody home. `bash -c '<cmd>' aeon.sh`
# is not enough — bash execs a lone simple command in place, and the cmdline that survives is
# the command's, with no aeon.sh anywhere in it.
#
# IT HOLDS NO INHERITED FILE DESCRIPTOR and it sleeps in one-second slices. A backgrounded
# process keeps the suite's stdout open, so `./test-landing.sh | tail` hangs until it exits
# however long ago the suite finished; and killing it does not kill the `sleep` it is blocked
# in, which inherits the same descriptor. Redirected and sliced, the stray outlives the suite
# by at most a second and is holding nothing while it does.
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$TMP/aeon.sh"; chmod +x "$TMP/aeon.sh"
"$TMP/aeon.sh" >/dev/null 2>&1 & aeon_pid=$!
claim_during_gate sp-taken "$aeon_pid"
out="$(landing)"
claimed="$(cat "$RUN/aeon-builder-sp-taken.pid" 2>/dev/null)"
kill "$aeon_pid" 2>/dev/null; wait "$aeon_pid" 2>/dev/null
rm -f "$RUN/aeon-builder-sp-taken.pid"
is     "the fixture did claim it mid-pass"      "$aeon_pid" "$claimed"
want   "the pass says an aeon took it"          "an aeon took spira/sp-taken while this pass ran" "$out"
is     "and its tip is exactly as the loop left it" \
       "$(tip_at_gate sp-taken)" "$(tip_of sp-taken)"
nowant "and nothing rebased it"                 "rebased spira/sp-taken" "$out"
drop_branch sp-taken; drop_branch sp-tlands

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
