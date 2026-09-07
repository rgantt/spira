#!/usr/bin/env bash
#
# test-landing.sh — the landing worker: what it does to branches, and what it tells the
# sentinel afterwards.
#
#   ./test-landing.sh
#
# These cases used to live in test-sentinel.sh, because landing used to be CHECK 6 and ran
# inside the pass. It does not any more (sp-gatecost): the sentinel dispatches this as a
# transient unit and never waits, so the two programs need two suites — one for what the
# worker DOES, which is this file, and one for how the pass DISPATCHES it and counts what it
# reports, which stays in test-sentinel.sh.
#
# The database is a REAL bd on a fixture created for the run and dropped by a trap, and git
# is real too, with a real bare remote, because every claim here is a claim about ancestry
# or about what `git merge` does when there is nothing to merge. A model of a dependency is
# a second implementation of it, and the two disagreeing is a bug in neither and a failure
# in both. `gate.sh` IS a stub whose exit status the test dictates: it has its own suite, and
# what is under test here is what landing does with a verdict, not how one is reached.
#
# THE HANDOFF IS UNDER TEST TOO, and it is the part with no second reader. Fire and forget
# means nothing in the pass can notice a worker that quietly stopped working, so the status
# file and the mailbox are the only evidence there is — a suite that checked the branches
# and not those two files would pass against a worker whose reports had gone silent.
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

# conf.sh travels with lib.sh. lib.sh resolves every path through it and refuses to run
# without it, so a fixture harness that copies one and not the other fails at source time —
# every case in this suite reporting exit 127 and no landing, which reads as landing being
# broken rather than the fixture being incomplete.
cp "$HERE/landing.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub gate.sh 'exit ${GATE_RC:-0}'

B() { bd -C "$SPIRA_DB" "$@"; }
status_of() { B show "$1" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(d[0].get("status") or "")'; }
assignee_of() { B show "$1" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(d[0].get("assignee") or "")'; }

# The mailbox is drained by the sentinel in production, so each run here starts from empty —
# otherwise every assertion after the first would be reading an earlier run's lines.
landing() {
    rm -f "$RUN/landing.progress"
    # SPIRA_REPO_MAP EXPLICITLY, never left to the fallback chain. The cases below that run
    # before a map is written were reading the operator's own seven repositories and counting
    # THEIR branches, so a pass over an empty fixture reported two branches seen and the
    # suite looked like a counting bug in landing.sh (law-gates-run-in-a-clean-environment).
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_REPO_MAP="$SH/repo-map" \
        bash "$SH/landing.sh" 2>&1
}
mailbox() { cat "$RUN/landing.progress" 2>/dev/null; }
status()  { cat "$RUN/landing.status" 2>/dev/null | tr '\n' ' '; }

seed() {
    testdb_reset
    testdb_seed <<'JSONL'
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
}
closed_child() {         # closed_child <id> <repo-label-or-empty>
    local id="$1" lab="$2" labels='[]'
    [ -n "$lab" ] && labels="[\"repo:$lab\"]"
    printf '{"id":"%s","title":"%s","status":"closed","issue_type":"task","labels":%s,"updated_at":"2026-09-04T00:00:00Z","closed_at":"2026-09-04T00:00:00Z","dependencies":[{"issue_id":"%s","depends_on_id":"sp-goal","type":"parent-child"}]}\n' \
        "$id" "$id" "$labels" "$id" | testdb_seed
}
branch_in() {            # branch_in <repo-path> <id> <repo-label> [base]
    local r="$1" id="$2" lab="$3" b="${4:-main}"
    git -C "$r" worktree add -q -b "spira/$id" "$RUN/worktree/$id" "$b"
    echo "$id" > "$RUN/worktree/$id/$id.txt"
    git -C "$RUN/worktree/$id" add -A
    git -C "$RUN/worktree/$id" commit -q -m "feat: $id — work"
    closed_child "$id" "$lab"
}
branch() { branch_in "$REPO" "$1" ""; }
mkrepo2() {              # mkrepo2 <name> [default-branch] — a second world, own bare origin
    local n="$1" b="${2:-main}"
    git init -q --bare -b "$b" "$TMP/$n.git"
    git init -q -b "$b" "$TMP/$n"
    git -C "$TMP/$n" commit -q --allow-empty -m base
    git -C "$TMP/$n" remote add origin "$TMP/$n.git"
    git -C "$TMP/$n" push -q origin "$b"
    git -C "$TMP/$n" fetch -q origin
}

echo "test-landing.sh"

# --------------------------------------------------------------------------------------
# THE POSITIVE CONTROL, first, because everything below it is read through these two files.
# A run over a world with no branches at all must still say so — "saw nothing" is the report
# that makes a later silence meaningful (law-absence-needs-a-positive-control).
# --------------------------------------------------------------------------------------
seed; out="$(landing)"
want "an empty run still reports its exit status" "SP_LAND_RC=0"       "$(status)"
want "and says how many branches it saw"          "SP_LAND_BRANCHES=0" "$(status)"
is   "and leaves the mailbox empty"               ""                   "$(mailbox)"
want "and says a pass happened at all"            "pass complete"      "$out"

# --------------------------------------------------------------------------------------
# A real land. The branch must actually reach the remote — the assertion is ancestry in the
# bare origin, not a line in a log.
# --------------------------------------------------------------------------------------
seed; branch sp-land; out="$(landing)"
want "a real land is reported" "landed spira/sp-land" "$out"
want "and posted to the mailbox for the sentinel to count" "landed spira/sp-land" "$(mailbox)"
want "and counted in the status file" "SP_LAND_MOVED=1" "$(status)"
want "and the branch it saw is counted too" "SP_LAND_BRANCHES=1" "$(status)"
git -C "$REPO" fetch -q origin
git -C "$REPO" merge-base --is-ancestor "spira/sp-land" origin/main \
    && ok "the work is an ancestor of origin/main" || bad "landing" "not an ancestor"

# The branch is still there — its worktree holds it, exactly as after a refused reap. A
# second run must not merge it again and must not report a movement, or the sentinel counts
# an action the DAG never made and mutes its own judgement tier with it.
out="$(landing)"
want   "an already-landed branch is skipped"  "already contains every change on spira/sp-land" "$out"
nowant "and is not reported again"            "landed spira/sp-land"      "$out"
is     "and posts nothing to the mailbox"     ""                          "$(mailbox)"
want   "while still reporting that it looked" "SP_LAND_BRANCHES=1"        "$(status)"

# --------------------------------------------------------------------------------------
# A branch that fails the gate is reopened, which IS a movement. The status in the database
# is what is checked, not a note the fake kept: `bd reopen` is what landing calls, and
# whether it took is a fact about bd rather than about this script.
# --------------------------------------------------------------------------------------
# THE DEAD AEON'S NAME COMES OFF. `bd reopen` keeps the assignee, and `bd ready --claim`
# skips an assigned bead while `bd ready` still lists it — so a reopened bead that kept its
# claimant's name went back into the graph unclaimable, and seven sat that way at P0 for
# hours while P1 work was taken around them. The assignee here is the one the aeon that
# closed it would have left behind.
seed; branch sp-bad; B update sp-bad --assignee aeon-dead >/dev/null 2>&1
out="$(GATE_RC=1 landing)"
want "a failed gate reopens the bead"   "reopened sp-bad — failed the gate" "$out"
want "and the reopen is a movement"     "reopened sp-bad"                   "$(mailbox)"
is   "the reopen actually happened"     open                                "$(status_of sp-bad)"
is   "and the dead claimant's name is gone, so it can be claimed again" "" "$(assignee_of sp-bad)"

# ======================================================================================
# ACROSS REPOSITORIES. The bead names its repository through a `repo:` label, so a branch
# lives in the checkout its aeon cut it from — and a worker that landed only one repository
# would leave every other repository's finished work standing forever while reporting clean
# runs.
# ======================================================================================
mkrepo2 two
cat > "$SH/repo-map" <<MAP
two | $TMP/two | push | |
MAP
seed; branch_in "$TMP/two" sp-two two; out="$(landing)"
want "a branch in a second repository lands there" "landed spira/sp-two" "$out"
git -C "$TMP/two" fetch -q origin
git -C "$TMP/two" merge-base --is-ancestor "spira/sp-two" origin/main \
    && ok "and it is really an ancestor of that repository's origin/main" \
    || bad "the second repository's land" "not an ancestor"
git -C "$REPO" rev-parse --verify -q "refs/heads/spira/sp-two" >/dev/null \
    && bad "and nothing was written into the home repository" "the branch exists there too" \
    || ok "and nothing was written into the home repository"

# A `repo:` label naming a repository the map does not carry must not be worked ANYWHERE.
# Silently falling back to the home repo is the failure the repo-map exists to prevent, and
# it is the one that looks like success from every angle downstream.
seed; branch_in "$REPO" sp-lost nosuchrepo; out="$(landing)"
nowant "an unmapped repo: label is never landed in the home repo" "landed spira/sp-lost" "$out"
want   "and the mismatch is named rather than passed over" "the bead names repo:nosuchrepo" "$out"
git -C "$REPO" branch -D spira/sp-lost >/dev/null 2>&1
git -C "$REPO" worktree remove --force "$RUN/worktree/sp-lost" >/dev/null 2>&1

# --------------------------------------------------------------------------------------
# `pr` mode. A repository with branch protection and its own CI is not landed by pushing its
# main — the branch becomes a pull request with auto-merge armed, and CI is the authority
# (law-green-prs-merge-themselves). `gh` is stubbed through SPIRA_GH for the same reason `bd`
# is: lib.sh rewrites PATH outright, so a stub cannot get in front by prepending a directory.
# --------------------------------------------------------------------------------------
mkrepo2 three
cat > "$SH/repo-map" <<MAP
three | $TMP/three | pr | |
MAP
cat > "$TMP/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")   [ -f "$GH_STATE" ] && cat "$GH_STATE"; exit 0 ;;
  "pr create") cat >/dev/null; echo "${GH_NUM:-7}" > "$GH_STATE"; exit "${GH_CREATE_RC:-0}" ;;
  "pr merge")  exit "${GH_MERGE_RC:-0}" ;;
esac
exit 1
GH
chmod +x "$TMP/gh"
export GH_LOG="$TMP/gh.log" GH_STATE="$TMP/gh.state"
: > "$GH_LOG"; rm -f "$GH_STATE"

seed; branch_in "$TMP/three" sp-pr three
out="$(SPIRA_GH="$TMP/gh" landing)"
want "a pr-mode branch becomes a pull request" "opened a pull request for spira/sp-pr" "$out"
want "the pull request is actually created"    "pr create" "$(cat "$GH_LOG")"
want "and auto-merge is armed"                 "pr merge --auto" "$(cat "$GH_LOG")"
git -C "$TMP/three" rev-parse --verify -q "refs/remotes/origin/spira/sp-pr" >/dev/null \
    && ok "and the branch really reached origin" \
    || bad "and the branch really reached origin" "no remote ref"
git -C "$TMP/three" fetch -q origin
git -C "$TMP/three" merge-base --is-ancestor "spira/sp-pr" origin/main \
    && bad "and main was NOT pushed" "the branch landed on main" \
    || ok "and main was NOT pushed"

# THE SECOND RUN MUST DO NOTHING. `pr` and `hold` leave the branch standing by design, so the
# ancestry test that stops push-mode from re-landing says nothing about them: without a
# submission marker this would push the branch and ask GitHub for the pull request again
# every two minutes, forever, and report a movement for it each time.
: > "$GH_LOG"
out="$(SPIRA_GH="$TMP/gh" landing)"
nowant "an open pull request is not reopened next run" "opened a pull request" "$out"
[ -s "$GH_LOG" ] && bad "and gh is not called again" "$(cat "$GH_LOG")" \
                 || ok "and gh is not called again"
is     "and nothing reaches the mailbox" "" "$(mailbox)"

# A gh that fails is retried, not marked done — but the bead is not reopened either, because
# nothing is wrong with the work.
mkrepo2 four
cat > "$SH/repo-map" <<MAP
four | $TMP/four | pr | |
MAP
rm -f "$GH_STATE"; : > "$GH_LOG"
seed; branch_in "$TMP/four" sp-prfail four
out="$(SPIRA_GH="$TMP/gh" GH_CREATE_RC=1 landing)"
want   "a failed pull request says so" "gh pr create failed" "$out"
nowant "and does not reopen the bead"  "reopened sp-prfail" "$out"
want   "and the run still reports a clean exit" "SP_LAND_RC=0" "$(status)"

# --------------------------------------------------------------------------------------
# `hold` mode. A repository with no origin has nowhere to push and a local `main` that is
# somebody's checked-out working tree, so the branch is gated and left — noted ONCE.
# --------------------------------------------------------------------------------------
git init -q -b main "$TMP/five"
git -C "$TMP/five" commit -q --allow-empty -m base
cat > "$SH/repo-map" <<MAP
five | $TMP/five | hold | |
MAP
seed; branch_in "$TMP/five" sp-hold five
out="$(landing)"
want "a hold-mode branch is gated and held" "gated and held spira/sp-hold" "$out"
out="$(landing)"
nowant "and is not re-noted every run" "gated and held spira/sp-hold" "$out"

# ======================================================================================
# A REPOSITORY WHOSE DEFAULT BRANCH IS `master`. Three of the seven repositories this
# harness manages are not `main`-named — some have no ref called `main`
# anywhere, remote or local — and every step of the landing path took the name literally.
# `rebase_branch "$br" main` failed and REOPENED the bead with "does not rebase onto main",
# so finished work was reopened for a defect it did not cause, three of those poisoned it,
# and the operator was escalated to about work that was fine.
#
# This is the end-to-end proof rather than a unit test of the resolver, because the resolver
# was never the only thing that said `main`: the push target, the rebase retry, the pull
# request base and the shared-checkout fast-forward each carried their own copy.
# ======================================================================================
mkrepo2 six master
cat > "$SH/repo-map" <<MAP
six | $TMP/six | push | origin/master | |
MAP
seed; branch_in "$TMP/six" sp-master six master; out="$(landing)"
want   "a master-default repository lands its branch" "landed spira/sp-master" "$out"
nowant "and is not reopened for failing to rebase"    "reopened sp-master" "$out"
git -C "$TMP/six" fetch -q origin
git -C "$TMP/six" merge-base --is-ancestor "spira/sp-master" origin/master \
    && ok "the work really reached origin/master" \
    || bad "the master land" "not an ancestor of origin/master"
git -C "$TMP/six" rev-parse --verify -q main >/dev/null 2>&1 \
    && bad "and no branch named main was invented" "one exists" \
    || ok "and no branch named main was invented"

# ======================================================================================
# A SQUASH-MERGED BRANCH IS LANDED, AND "DOES NOT REBASE" IS THE PROOF OF IT RATHER THAN
# THE COUNTER-EVIDENCE. Auto-merge is armed with --squash, so the whole branch is replayed
# as ONE new commit with a new SHA and a parentage the branch does not appear in: its
# commits are not ancestors of the base and never will be. The rebase that followed then
# conflicted — precisely BECAUSE the base already held those changes — and the pair was read
# as a branch in trouble, so a bead closed over merged work was reopened, and reopened again
# on the next pass, forever, because nothing about the situation changes between passes.
#
# The branch here is built to conflict on rebase and to be a no-op on merge, which is the
# exact shape: two commits taking a file "" -> A -> B, against a base that went "" -> B in
# one. Replaying the first patch onto the base collides; merging the endpoints changes
# nothing.
# ======================================================================================
mkrepo2 eight
cat > "$SH/repo-map" <<MAP
eight | $TMP/eight | push | origin/main | |
MAP
squashed() {             # squashed <repo-path> <id> <repo-label> — land it the way GitHub does
    local r="$1" id="$2" lab="$3"
    git -C "$r" worktree add -q -b "spira/$id" "$RUN/worktree/$id" main
    printf 'A\n' > "$RUN/worktree/$id/f.txt"
    git -C "$RUN/worktree/$id" add -A
    git -C "$RUN/worktree/$id" commit -q -m "feat: $id — first pass"
    printf 'B\n' > "$RUN/worktree/$id/f.txt"
    git -C "$RUN/worktree/$id" add -A
    git -C "$RUN/worktree/$id" commit -q -m "feat: $id — second pass"
    closed_child "$id" "$lab"
    git -C "$r" merge -q --squash "spira/$id" >/dev/null
    git -C "$r" commit -q -m "$id: work (#7)"
    git -C "$r" push -q origin main
    git -C "$r" fetch -q origin
}
seed; squashed "$TMP/eight" sp-squash eight
before="$(git -C "$TMP/eight" rev-parse spira/sp-squash)"

# THE POSITIVE CONTROL, and it is the whole reason this case is trustworthy: both of the old
# signals must really be present, or the assertions below are passing against a world in
# which nothing was ever wrong (law-absence-needs-a-positive-control).
git -C "$TMP/eight" merge-base --is-ancestor spira/sp-squash origin/main \
    && bad "the squashed branch is not an ancestor of its base" "it is one — no squash happened" \
    || ok "the squashed branch is not an ancestor of its base"
git -C "$TMP/eight" worktree add -q --detach "$TMP/eight-replay" spira/sp-squash 2>/dev/null
if git -C "$TMP/eight-replay" rebase -q origin/main >/dev/null 2>&1; then
    bad "and genuinely does not rebase onto it" "the rebase succeeded"
else
    ok "and genuinely does not rebase onto it"
fi
git -C "$TMP/eight-replay" rebase --abort >/dev/null 2>&1
git -C "$TMP/eight" worktree remove --force "$TMP/eight-replay" >/dev/null 2>&1

out="$(landing)"
want   "a squash-merged branch is recognised as landed" "already contains every change on spira/sp-squash" "$out"
nowant "and is not reopened"                            "reopened sp-squash" "$out"
nowant "and is not re-landed"                           "landed spira/sp-squash" "$out"
is     "and its bead stays closed"                      "closed"   "$(status_of sp-squash)"
is     "and its branch is left exactly as it was"       "$before"  "$(git -C "$TMP/eight" rev-parse spira/sp-squash)"
is     "and nothing reaches the mailbox"                ""         "$(mailbox)"

# AND THE CHECK CAN STILL SAY NO. A content test that answered "landed" for everything would
# pass every assertion above while silently disabling the reopen path, so the branch that
# really does carry something the base lacks must still come back. Same conflicting shape,
# different content: the base went "" -> C by work of its own.
mkrepo2 nine
cat > "$SH/repo-map" <<MAP
nine | $TMP/nine | push | origin/main | |
MAP
seed
git -C "$TMP/nine" worktree add -q -b spira/sp-real "$RUN/worktree/sp-real" main
printf 'A\n' > "$RUN/worktree/sp-real/f.txt"
git -C "$RUN/worktree/sp-real" add -A
git -C "$RUN/worktree/sp-real" commit -q -m "feat: sp-real — first pass"
printf 'B\n' > "$RUN/worktree/sp-real/f.txt"
git -C "$RUN/worktree/sp-real" add -A
git -C "$RUN/worktree/sp-real" commit -q -m "feat: sp-real — second pass"
closed_child sp-real nine
B update sp-real --assignee aeon-dead >/dev/null 2>&1
printf 'C\n' > "$TMP/nine/f.txt"
git -C "$TMP/nine" add -A
git -C "$TMP/nine" commit -q -m "somebody else's work"
git -C "$TMP/nine" push -q origin main
git -C "$TMP/nine" fetch -q origin
# SPIRA_GH is a gh that knows no pull requests, so the merged-PR reading below cannot be what
# carries this case: the reopen must come from the content test alone.
out="$(SPIRA_GH="$TMP/gh" landing)"
want "a branch the base does not contain is still reopened" "reopened sp-real — does not rebase" "$out"
is   "and its bead is open again"                           "open"  "$(status_of sp-real)"
is   "and unassigned, so the rebase can be claimed"         ""      "$(assignee_of sp-real)"

# A MERGED PULL REQUEST IS THE OTHER READING OF "ALREADY LANDED", and it is the one that
# survives what the content test cannot: a squash that merged and was then amended on the
# base. The content genuinely differs, so merging would change something and the branch reads
# as unlanded — but re-landing it would revert whoever amended it. The network call sits
# behind the rebase failure, so it is paid for only by a branch about to be reopened.
cat > "$TMP/gh-merged" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in "pr view") echo MERGED; exit 0 ;; esac
exit 1
GH
chmod +x "$TMP/gh-merged"
mkrepo2 ten
cat > "$SH/repo-map" <<MAP
ten | $TMP/ten | push | origin/main | |
MAP
seed
git -C "$TMP/ten" worktree add -q -b spira/sp-amended "$RUN/worktree/sp-amended" main
printf 'A\n' > "$RUN/worktree/sp-amended/f.txt"
git -C "$RUN/worktree/sp-amended" add -A
git -C "$RUN/worktree/sp-amended" commit -q -m "feat: sp-amended — first pass"
printf 'B\n' > "$RUN/worktree/sp-amended/f.txt"
git -C "$RUN/worktree/sp-amended" add -A
git -C "$RUN/worktree/sp-amended" commit -q -m "feat: sp-amended — second pass"
closed_child sp-amended ten
git -C "$TMP/ten" merge -q --squash spira/sp-amended >/dev/null
git -C "$TMP/ten" commit -q -m "sp-amended: work (#8)"
printf 'B, then somebody fixed a typo\n' > "$TMP/ten/f.txt"
git -C "$TMP/ten" add -A
git -C "$TMP/ten" commit -q -m "follow-up on the squashed work"
git -C "$TMP/ten" push -q origin main
git -C "$TMP/ten" fetch -q origin
out="$(SPIRA_GH="$TMP/gh-merged" landing)"
want   "a merged pull request is landed however the content reads" "its pull request is merged" "$out"
nowant "and the bead is not reopened"                              "reopened sp-amended" "$out"
is     "and it stays closed"                                       "closed" "$(status_of sp-amended)"

# A REPOSITORY WHOSE BASE CANNOT BE ESTABLISHED IS SKIPPED, NOT GUESSED AT. The bare origin
# here publishes a default branch nothing ever pushed, so there is genuinely no answer — and
# the old code would have said `main` and rebased a finished branch onto a ref that is not
# there. Skipping is the whole point of failing closed: the branch survives untouched and the
# bead is not reopened with a reason that is not a reason.
git init -q --bare "$TMP/seven.git"          # HEAD -> refs/heads/master, never pushed
git init -q -b main "$TMP/seven"
git -C "$TMP/seven" commit -q --allow-empty -m base
git -C "$TMP/seven" remote add origin "$TMP/seven.git"
git -C "$TMP/seven" push -q origin main
git -C "$TMP/seven" fetch -q origin
cat > "$SH/repo-map" <<MAP
seven | $TMP/seven | push | |
MAP
seed; branch_in "$TMP/seven" sp-noba seven; before="$(git -C "$TMP/seven" rev-parse spira/sp-noba)"
out="$(landing)"
want   "an unresolvable repository says so"     "cannot resolve the ref its branches land on" "$out"
nowant "and does not reopen the bead"           "reopened sp-noba" "$out"
nowant "and does not claim to have landed it"   "landed spira/sp-noba" "$out"
is     "and leaves the branch exactly as it was" "$before" "$(git -C "$TMP/seven" rev-parse spira/sp-noba)"

# --------------------------------------------------------------------------------------
# THE STRUCTURAL REGRESSION. This worker is fire-and-forget: nothing waits on it and nothing
# reads its exit status, so if it ever stops writing the status file its silence becomes
# indistinguishable from a quiet week. The trap is what guarantees the write happens on
# every exit path — including the one where systemd's RuntimeMaxSec cuts it off mid-gate —
# and it can be removed in one line by someone who reads it as boilerplate.
# --------------------------------------------------------------------------------------
want "the status file is written from an EXIT trap" "trap finish EXIT" "$(cat "$HERE/landing.sh")"
want "and a systemd kill routes through it"         "trap 'exit 143' TERM INT" "$(cat "$HERE/landing.sh")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
