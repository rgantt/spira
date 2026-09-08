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
# covers: spira/landing.sh spira/lib.sh
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
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree" "$SH"

# conf.sh travels with lib.sh — lib.sh refuses to run without it, and a harness that copies
# one and not the other fails at source time, which reads as landing being broken.
cp "$HERE/landing.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$SH/"
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
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_REPO_MAP="$SH/repo-map" SPIRA_GH="$SH/gh" \
        bash "$SH/landing.sh" 2>&1
}
notes_of() { B show "$1" 2>/dev/null; }

seed() {
    testdb_reset
    testdb_seed <<'JSONL'
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
}
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
