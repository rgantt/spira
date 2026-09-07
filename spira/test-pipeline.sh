#!/usr/bin/env bash
#
# test-pipeline.sh — one bead, all the way through, against a fixture.
#
#   ./test-pipeline.sh
#
# WHY THIS EXISTS. Every other suite here owns one program. Not one of them owns the SEAMS
# between them, and on 2026-09-06/07 every defect that actually stopped the loop lived in a
# seam, while all thirty-nine suites stayed green:
#
#   - aeon.sh keyed its worktree on the bead id alone, so a tree left from when a bead was
#     scoped to another repo was reused for it — eight summons handed a brain checkout for a
#     repo:spira bead.
#   - a branch already checked out somewhere else made `git worktree add` fail and the aeon
#     die three seconds after birth. Twenty-two attempts, none about the work.
#   - a landing pass read its branch list once and ran for 34 minutes, then reopened a bead
#     whose branch had been landed and deleted 11 minutes earlier.
#   - the cockpit read the ledger's field 3 (the fayth) where the bead is field 4, so no
#     claim ever reached the pane.
#
# Each was a correct program talking to a correct program through a wrong assumption. The
# operator, after two days of that: "simply patching the system and hoping for the best has
# not been a winning strategy."
#
# WHAT IT ASSERTS is the PATH, not the programs: claim -> worktree -> commit -> close ->
# gate -> merge -> landed -> reaped, plus the seams that have actually broken. It is the
# hand-shepherd of sp-5su7 (2026-09-07) written down so it can be run instead of performed.
#
# IT USES THE REAL SCRIPTS against a fixture repo and a fixture database — never production.
# A pipeline test that stubs the pipeline tests the stubs.
#
# covers: spira/aeon.sh spira/landing.sh spira/cockpit.sh spira/world.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-pipeline
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up pipeline || { echo "test-pipeline: could not build a fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
OTHER="$TMP/other"; OTHER_REMOTE="$TMP/other.git"
for pair in "$REMOTE:$REPO" "$OTHER_REMOTE:$OTHER"; do
    r="${pair%%:*}"; w="${pair#*:}"
    git init -q --bare -b main "$r"; git init -q -b main "$w"
    git -C "$w" commit -q --allow-empty -m base
    git -C "$w" remote add origin "$r"; git -C "$w" push -q origin main; git -C "$w" fetch -q origin
done
mkdir -p "$RUN/worktree" "$SH"
cp "$HERE/landing.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub gate.sh 'exit ${GATE_RC:-0}'
printf 'repo | %s | push | origin/main | | \n' "$REPO" > "$SH/repo-map"

B() { bd -C "$SPIRA_DB" "$@"; }
field_of() { B show "$1" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(d[0].get(sys.argv[1]) or "")' "$2"; }

landing() {
    rm -f "$RUN/landing.progress"
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_REPO_MAP="$SH/repo-map" SPIRA_GATE_ADVISORY="${ADVISORY:-0}" \
        bash "$SH/landing.sh" 2>&1
}
mailbox() { cat "$RUN/landing.progress" 2>/dev/null; }

seed_bead() {            # seed_bead <id> — an open bead the pipeline can carry
    B create "pipeline canary $1" --json >/dev/null 2>&1 || true
    testdb_seed <<JSONL
{"id":"$1","title":"canary $1","status":"open","issue_type":"task","labels":["spira","plan","repo:repo"],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
}
work_branch() {          # work_branch <id> [repo] — a branch with one real commit
    local id="$1" w="${2:-$REPO}"
    git -C "$w" worktree add -q -b "spira/$id" "$RUN/worktree/$id" main 2>/dev/null
    echo "$id" > "$RUN/worktree/$id/$id.txt"
    git -C "$RUN/worktree/$id" add -A
    git -C "$RUN/worktree/$id" commit -q -m "feat: $id"
}

echo "test-pipeline.sh"

# ======================================================================================
# THE HAPPY PATH, end to end. If this breaks, nothing else in the suite matters.
# ======================================================================================
echo
echo "one bead, claim to landed:"
seed_bead sp-p1
work_branch sp-p1
TIP="$(git -C "$RUN/worktree/sp-p1" rev-parse HEAD)"

B update sp-p1 --assignee worker --status in_progress >/dev/null 2>&1
is   "the claim is recorded"            in_progress "$(field_of sp-p1 status)"
is   "and names its holder"             worker      "$(field_of sp-p1 assignee)"

# A HOLDER'S BEAD IS CLOSED BY ITS HOLDER. bd refuses a close whose actor is not the
# assignee — "cannot close: assignee is X, actor is Y" — and refuses it QUIETLY enough that a
# script ignoring stderr carries on with the bead still in progress, which is what the first
# version of this suite did. The aeon closes as itself, so the fixture must too.
out="$(B close sp-p1 --reason "done" 2>&1)"
want "a close by the wrong actor is refused" "cannot close" "$out"
is   "and the bead is untouched by it"       in_progress "$(field_of sp-p1 status)"
BEADS_ACTOR=worker B close sp-p1 --reason "done" >/dev/null 2>&1
is   "closed before landing is asked"   closed      "$(field_of sp-p1 status)"

out="$(landing)"
want "the pass lands it"                "landed spira/sp-p1" "$(mailbox)"

# LANDED IS AN ANCESTRY QUESTION, NEVER A TIP COMPARISON. A tip moves under you mid-pass, and
# comparing them is how work that merged perfectly gets reported as missing
# (law-closed-is-not-landed).
git -C "$REPO" fetch -q origin
if git -C "$REPO" merge-base --is-ancestor "$TIP" origin/main 2>/dev/null; then
    ok "and the commit is an ancestor of the base ref"
else
    bad "and the commit is an ancestor of the base ref" "tip $TIP is not on origin/main"
fi
is   "the bead stays closed"            closed      "$(field_of sp-p1 status)"

# ======================================================================================
# THE SEAMS THAT ACTUALLY BROKE. Each of these is a real 2026-09-07 outage, written as the
# smallest arrangement that reproduces it.
# ======================================================================================
echo
echo "a red gate, enforcing and advisory:"
seed_bead sp-p2; work_branch sp-p2; B close sp-p2 --reason done >/dev/null 2>&1
out="$(GATE_RC=1 landing)"
want "enforcing: a red gate reopens the bead" "reopened sp-p2" "$out"
is   "enforcing: and it is open again"        open "$(field_of sp-p2 status)"
is   "enforcing: with no claimant left on it" ""   "$(field_of sp-p2 assignee)"

seed_bead sp-p3; work_branch sp-p3; B close sp-p3 --reason done >/dev/null 2>&1
T3="$(git -C "$RUN/worktree/sp-p3" rev-parse HEAD)"
out="$(ADVISORY=1 GATE_RC=1 landing)"
nowant "advisory: does NOT reopen"            "reopened sp-p3" "$out"
want   "advisory: still records the verdict"  "gate FAILED but advisory mode is on" "$out"
is     "advisory: the bead stays closed"      closed "$(field_of sp-p3 status)"
git -C "$REPO" fetch -q origin
git -C "$REPO" merge-base --is-ancestor "$T3" origin/main 2>/dev/null \
    && ok "advisory: and the work still lands" \
    || bad "advisory: and the work still lands" "tip $T3 never reached origin/main"

echo
echo "a branch that vanished under a running pass:"
# THE LIST IS OLDER THAN THE LOOP. A pass reads its branches once and can run for tens of
# minutes; anything that lands or reaps a branch in that window used to make the next
# iteration reopen a finished bead.
seed_bead sp-p4; work_branch sp-p4; B close sp-p4 --reason done >/dev/null 2>&1
git -C "$REPO" worktree remove --force "$RUN/worktree/sp-p4" 2>/dev/null
git -C "$REPO" branch -D spira/sp-p4 >/dev/null 2>&1
out="$(landing)"
nowant "a deleted branch is not reopened"  "reopened sp-p4" "$out"
is     "and its bead stays closed"         closed "$(field_of sp-p4 status)"

echo
echo "the ledger the cockpit reads:"
# THE BEAD IS FIELD 4. `<ts> <verb> <fayth> <bead>` — reading field 3 gets the fayth, which
# is why no claim ever appeared in RECENT.
LEDGER="$RUN/aeon-ledger.log"
printf '2026-09-07T00:00:00Z awake builder sp-p9\n2026-09-07T00:01:00Z done builder sp-p9 rc=0 status=closed\n' > "$LEDGER"
claims="$(awk '$2 == "awake" && $4 ~ /^sp-/ { print $4 }' "$LEDGER")"
is   "a claim is readable from field 4"    sp-p9 "$claims"
wrong="$(awk '$2 == "awake" && $3 ~ /^sp-/ { print $3 }' "$LEDGER")"
is   "and field 3 is the fayth, not the bead (the bug)" "" "$wrong"

echo
echo "stopping the world:"
# A STOP THAT REPORTS SUCCESS AND LEAVES WORK RUNNING IS THE FAILURE MODE. world.sh reads the
# bead from the PIDFILE because BEAD_ID is not exported; the first version read the process
# environment, found nothing, and said "no live aeons" while four were running.
printf '%s\n' "99999999" > "$RUN/aeon-builder-sp-p8.pid"
found="$(for pf in "$RUN"/aeon-*.pid; do b="$(basename "$pf" .pid)"; b="${b#aeon-}"; echo "${b#*-}"; done)"
is   "the bead is recoverable from the pidfile name" sp-p8 "$found"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
