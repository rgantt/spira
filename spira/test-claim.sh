#!/usr/bin/env bash
#
# test-claim.sh — a claim that ends is a claim that is cleared, and "ready" means claimable.
#
#   ./test-claim.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# On 2026-09-06 the plan was starved with thirteen ready beads and free aeon slots. The
# sentinel logged "13 ready, 2 free — summoning" every two minutes and the aeon it summoned
# reported idle within one second. Both programs were correct. They were answering different
# questions:
#
#   * `bd ready` counts a bead by status and blockers, and counted all thirteen;
#   * `bd ready --claim` SKIPS a bead already carrying another actor's assignee, and took
#     none of them.
#
# Every one of the thirteen was status=open, lease_expires_at=null, assignee=an aeon that no
# longer existed. `bd reopen` sets the status and leaves the name standing, and `bd reclaim`
# reverts stale-lease IN_PROGRESS issues only — so an open bead with a null lease is outside
# its predicate by construction. Ready forever, claimable never, and it presented as a
# HEALTHY queue, which is why it ran for a day (law-absence-needs-a-positive-control).
#
# So this suite holds three properties, and every one of them is a claim about what `bd`
# actually does rather than about what the harness intends:
#
#   1. the substrate really does leave an assignee behind — asserted FIRST, as the positive
#      control, because cases 2 and 3 would all pass against a `bd` that never wrote one;
#   2. every path that ends a claim clears it — bead_reopen, release_own_claim, and the
#      sweep that catches whatever those two miss;
#   3. the count the sentinel summons on and the query the aeon claims through are the same
#      question.
#
# A fourth section covers the sibling defect in the same family: state left behind by an
# ended claim that makes a bead permanently unworkable. There the state is a WORKTREE rather
# than an assignee, and it is what trapped this very bead.
#
# A REAL `bd` ON A FIXTURE DATABASE, dropped by a trap. A stub would assert only that the
# author's model of `bd ready --claim` agrees with the author's model of `bd reopen` — and
# the entire defect lived in the gap between what those two commands really do
# (law-prefer-the-real-dependency).
#
# The call sites are covered as well as the functions, because half of these assertions are
# about the TEXT of the dispatch path — that aeon.sh claims through READY_ARGS rather than a
# copy, that no bare `bdq reopen` survives in aeon.sh, landing.sh or sentinel.sh, and that
# the sweep is called before the summon. A suite asserting on a file it does not declare is
# one the gate will not run on the change that breaks it.
#
# covers: spira/lib.sh spira/aeon.sh spira/landing.sh spira/sentinel.sh spira/cockpit.sh spira/drain.sh spira/strand.sh
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
testdb_require test-claim

TMP="$(mktemp -d)"
cleanup() { testdb_drop; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
testdb_up claim || { echo "test-claim: could not build a fixture database"; exit 1; }

export SPIRA_RUN="$TMP/run"
export SPIRA_HOME="$TMP/home"
mkdir -p "$SPIRA_RUN" "$SPIRA_HOME"

# shellcheck disable=SC1090
. "$HERE/lib.sh"

# The exclusion is a literal, not $SPIRA_ASK_LABEL, so the fixture asserts the same thing on
# an installation that renamed the label (law-gates-run-in-a-clean-environment).
PARKED="spira-poison,needs-operator"

# ---- reading the fixture -------------------------------------------------------------
field() {   # field <id> <name> -> the field, or the empty string for null
    bdjson show "$1" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
d = d if isinstance(d, list) else [d]
print("" if not d else (d[0].get(sys.argv[1]) or ""))' "$2" 2>/dev/null
}
assignee_of() { field "$1" assignee; }
status_of()   { field "$1" status; }

beads() {   # beads [row ...] — the whole database, one row per argument
    testdb_reset
    [ $# -gt 0 ] || return 0
    printf '%s\n' "$@" | testdb_seed
}
bead() {    # bead <id> [assignee] [status] -> one import row under spira,plan
    printf '{"id":"%s","title":"t %s","status":"%s","issue_type":"task","assignee":"%s","labels":["spira","plan"],"updated_at":"2026-09-04T00:00:00Z"}\n' \
      "$1" "$1" "${3:-open}" "${2:-}"
}

# claim_one <actor> -> the id that actor actually got, through the harness's own query
claim_one() {
    BEADS_ACTOR="$1" bdq "${READY_ARGS[@]}" --claim --label spira,plan \
        --exclude-label "$PARKED" --json 2>/dev/null | json_only | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
d = d if isinstance(d, list) else [d]
print(d[0]["id"] if d else "")' 2>/dev/null
}

count() { ready_count spira,plan "$PARKED"; }

# ======================================================================================
echo "the harness under test has the machinery these cases assert about:"
# ======================================================================================
# Established FIRST. Every case below asserts that an assignee ends up CLEARED, and a
# missing function also leaves nothing behind — so against a harness without the fix this
# suite would score a clean sweep of green it never earned.
for fn in bead_reopen release_claim release_own_claim orphan_claims release_orphan_claims \
          worktree_evict_foreign; do
    declare -F "$fn" >/dev/null && ok "lib.sh defines $fn" || bad "lib.sh defines $fn" "it does not"
done
declare -p READY_ARGS >/dev/null 2>&1 && ok "lib.sh defines READY_ARGS" \
    || bad "lib.sh defines READY_ARGS" "it does not"
if [ "$fail" -ne 0 ]; then
    printf '\nrefusing to run: this harness has no claim-release path, so the assertions\n'
    printf 'below would pass by accident. %d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

# ======================================================================================
echo
echo "the substrate really does strand an assignee (the positive control):"
# ======================================================================================
# THE BUG ITSELF, reproduced against the real bd. If any of this stops being true — bd
# starts clearing the assignee on reopen, or --claim starts taking an orphaned one — then
# the sweep below is dead weight, and this is where that gets noticed rather than the sweep
# quietly guarding nothing.
beads "$(bead sp-held aeon-yojimbo closed)"
bdq reopen sp-held >/dev/null 2>&1
is "bd reopen sets the status"            "open"         "$(status_of sp-held)"
is "bd reopen leaves the assignee behind" "aeon-yojimbo" "$(assignee_of sp-held)"
is "and no lease is left to expire"       ""             "$(field sp-held lease_expires_at)"

beads "$(bead sp-orph aeon-yojimbo)"
is "bd reclaim does not reach an open bead" "aeon-yojimbo" \
   "$(bdq reclaim --older-than 0s --label spira,plan >/dev/null 2>&1; assignee_of sp-orph)"

beads "$(bead sp-orph aeon-yojimbo)" "$(bead sp-free)"
is "--claim skips the orphan and takes the free bead" "sp-free" "$(claim_one aeon-shiva)"
beads "$(bead sp-orph aeon-yojimbo)"
is "with only orphans queued an aeon claims nothing" "" "$(claim_one aeon-shiva)"

# ======================================================================================
echo
echo "'ready' counts what an aeon can actually take:"
# ======================================================================================
# The acceptance criterion, and the reason it is one array rather than two queries: CHECK 7
# summons on ready_count and aeon.sh claims through the same READY_ARGS, so they cannot
# disagree.
beads "$(bead sp-orph aeon-yojimbo)" "$(bead sp-free)"
is "an orphaned bead is not counted ready" 1 "$(count)"
is "and the count is what an aeon gets"    "sp-free" "$(claim_one aeon-shiva)"
is "which leaves nothing countable"        0 "$(count)"

# The whole starvation, at its real proportions: counted, and none of them claimable.
beads "$(bead sp-a aeon-yojimbo)" "$(bead sp-b aeon-valefor)" "$(bead sp-c aeon-mindy)"
is "three orphans read as zero ready, not three" 0 "$(count)"

want "aeon.sh claims through READY_ARGS, not its own copy" 'claim_args=("${READY_ARGS[@]}"' \
     "$(cat "$HERE/aeon.sh")"

# NOR MAY ANY OTHER PROGRAM KEEP A COPY. cockpit.sh held one whose comment claimed it was
# the sentinel's predicate "verbatim", and it had already drifted a flag — so the dashboard
# would have gone on reporting unclaimable beads as ready work while the queue starved,
# which is the reading that displaces the suspicion that would prompt a look. A copy is a
# rule that agrees only until somebody edits one of them.
copies="$(grep -rln -e 'ready --limit 0 --exclude-type epic' "$HERE" --include='*.sh' \
          | grep -v '/test-' | grep -v '/lib\.sh$' | tr '\n' ' ')"
is "no program outside lib.sh keeps a copy of the ready predicate" "" "$copies"

# ======================================================================================
echo
echo "every path that ends a claim clears it:"
# ======================================================================================
beads "$(bead sp-held aeon-yojimbo closed)"
bead_reopen sp-held
is "bead_reopen reopens"             "open" "$(status_of sp-held)"
is "bead_reopen releases"            ""     "$(assignee_of sp-held)"
is "and the bead is claimable again" "sp-held" "$(claim_one aeon-shiva)"

# No bare `bdq reopen` may survive at a call site in the dispatch path: the defect was never
# that somebody forgot the second call, it was that the two facts could be written apart at
# all. slay.sh is deliberately excluded — it is the operator's own --force path and clears
# the assignee itself, before it reopens.
for f in aeon.sh landing.sh sentinel.sh; do
    nowant "$f reopens only through bead_reopen" "bdq reopen" "$(cat "$HERE/$f")"
done

# IT MUST NOT ABORT A CALLER UNDER `set -e`. Callers reopen with -e in force and write the
# note explaining WHY the bead came back on the NEXT line, so a non-zero return here would
# leave a reopened bead with no record of the reason — and the next aeon would read an
# ordinary open bead and repeat whatever produced it. Given a bead id bd cannot resolve,
# both the reopen and the release fail, which is the only way to exercise the guarantee.
#
# THE SUBSHELL MUST NOT SIT IN AN `if` CONDITION. bash suppresses -e for a command whose
# status is being tested, and the suppression propagates into a subshell even one that sets
# -e itself — written as `if ( set -e; ... )` this case passes against a bead_reopen that
# returns 1, which is precisely the mutant it exists to catch. Run it as a plain statement
# and read what it printed.
is "bd refuses a reopen of a bead that does not exist" \
   "1" "$(bdq reopen sp-no-such-bead >/dev/null 2>&1; echo $?)"
( set -e; bead_reopen sp-no-such-bead 2>/dev/null; echo REACHED ) >"$TMP/seteq" 2>&1
is "bead_reopen does not abort a caller running under set -e" \
   "REACHED" "$(tail -1 "$TMP/seteq")"

# An aeon hands back its own bead under the name the CLAIM was written with. Release sites
# that asked for `aeon-$FAYTH` while bd had recorded `aeon-$AEON` got "assignee mismatch",
# exit 1 into /dev/null, and the name stayed on the bead.
beads "$(bead sp-mine)"
is "an aeon claims a bead" "sp-mine" "$(claim_one aeon-yojimbo)"
( export BEADS_ACTOR=aeon-yojimbo SPIRA_AEON=yojimbo; release_own_claim sp-mine )
is "release_own_claim clears the aeon's own name" "" "$(assignee_of sp-mine)"
is "and returns the bead to open"                 "open" "$(status_of sp-mine)"

# ...and only its own. --if-assignee is a compare-and-swap for exactly this: a supervisor
# may have reclaimed the bead and handed it on while this aeon was dying.
beads "$(bead sp-yours)"
claim_one aeon-valefor >/dev/null
( export BEADS_ACTOR=aeon-yojimbo SPIRA_AEON=yojimbo; release_own_claim sp-yours ) \
    && bad "release_own_claim refuses another aeon's bead" "it returned 0" \
    || ok "release_own_claim refuses another aeon's bead"
is "and leaves the holder in place" "aeon-valefor" "$(assignee_of sp-yours)"

# aeon.sh must not hand-write that release. Deriving the actor a second time is what let the
# two names disagree, so there is one function and no copies of it.
nowant "aeon.sh releases only through release_own_claim" 'bdq unclaim' "$(cat "$HERE/aeon.sh")"

# ======================================================================================
echo
echo "the sweep catches what the paths above miss:"
# ======================================================================================
beads "$(bead sp-a aeon-yojimbo)" "$(bead sp-b aeon-valefor)" "$(bead sp-free)"
out="$(release_orphan_claims spira,plan)"
want "it names the bead it released"    "RELEASED	sp-a" "$out"
want "and the aeon it released it from" "aeon-yojimbo"  "$out"
is   "it releases every orphan"         2 "$(grep -c '^RELEASED' <<< "$out" || true)"
is   "sp-a is free"                     "" "$(assignee_of sp-a)"
is   "sp-b is free"                     "" "$(assignee_of sp-b)"
is   "all three are now countable"      3 "$(count)"
is   "a swept database sweeps to nothing" "" "$(release_orphan_claims spira,plan)"

# THE PROPERTY THAT KEEPS THIS SAFE TO RUN FROM A TIMER. The sweep is `bd assign <id> ""`
# and not `bd unclaim --force` precisely because assign REFUSES a live in_progress claim: an
# aeon claiming out of this database concurrently must never be robbed by a supervisor
# racing it.
beads "$(bead sp-live)"
claim_one aeon-shiva >/dev/null
is "a live claim is in_progress with a lease" "in_progress" "$(status_of sp-live)"
is "the sweep does not see a live claim"      "" "$(orphan_claims spira,plan)"
is "and cannot take it even asked directly"   "aeon-shiva" \
   "$(release_claim sp-live >/dev/null 2>&1; assignee_of sp-live)"

# Nor does it reach outside the plan's own partition. A predecessor's imported beads share
# this database and several carry a permanent assignee that is not an aeon at all.
beads "$(bead sp-a aeon-yojimbo)" \
      '{"id":"pd-x","title":"imported","status":"open","issue_type":"task","assignee":"mayor","labels":["gastown"],"updated_at":"2026-09-04T00:00:00Z"}'
release_orphan_claims spira,plan >/dev/null
is "another partition's bead keeps its assignee" "mayor" "$(assignee_of pd-x)"
is "and the plan's orphan is still released"     "" "$(assignee_of sp-a)"

# ======================================================================================
echo
echo "the sentinel actually runs the sweep:"
# ======================================================================================
# The sweep existing in lib.sh and never being called is the same defect wearing a different
# face, so the wiring is asserted rather than assumed.
SENT="$HERE/sentinel.sh"
want "sentinel.sh calls release_orphan_claims" 'release_orphan_claims "spira,plan"' "$(cat "$SENT")"

# BEFORE the count it corrects. A sweep that ran after the summon would free the beads one
# pass too late, every pass, and the log would still read "13 ready" while an aeon reported
# idle within the second.
sweep_at="$(grep -n 'release_orphan_claims "spira,plan"' "$SENT" | head -1 | cut -d: -f1)"
summon_at="$(grep -n '^for f in \$FAYTHS; do' "$SENT" | tail -1 | cut -d: -f1)"
if [ -n "$sweep_at" ] && [ -n "$summon_at" ] && [ "$sweep_at" -lt "$summon_at" ]; then
    ok "the sweep runs before the summon"
else
    bad "the sweep runs before the summon" "sweep at [$sweep_at], summon at [$summon_at]"
fi

# ======================================================================================
echo
echo "a worktree left by an ended claim does not outlive the repository it was cut in:"
# ======================================================================================
# THE SAME DEFECT IN THE OTHER FIELD. A worktree path is derived from the bead id alone, so
# repointing a bead's `repo:` label — the harness's own answer to a branch cut in the wrong
# repository — leaves the old repository's tree sitting at the path the next summon reuses.
# A repointed bead kept the OLD repository's tree, and summon after summon attached to it,
# rebased that repository's branch onto that repository's base, and was handed a checkout in
# which the files the bead named do not exist. Nothing failed: `git worktree add` was never
# reached.
G="$TMP/git"; mkdir -p "$G"
mkrepo() {   # mkrepo <name> -> an initialised repository with one commit
    local r="$G/$1"
    git init -q -b main "$r" 2>/dev/null
    git -C "$r" config user.email t@t; git -C "$r" config user.name t
    echo "$1" > "$r/f"; git -C "$r" add f; git -C "$r" commit -qm "$1"
    printf '%s' "$r"
}
A="$(mkrepo alpha)"; B="$(mkrepo beta)"
WT="$G/work"

git -C "$A" worktree add -q -b topic "$WT" main
is "a tree of the right repository is left alone" "1" \
   "$(worktree_evict_foreign "$WT" "$A" >/dev/null 2>&1; echo $?)"
is "and it is still there"                        "alpha" "$(cat "$WT/f")"

# The uncommitted half is what makes removal unacceptable: it may be the only copy.
echo "work in progress" > "$WT/uncommitted"
moved="$(worktree_evict_foreign "$WT" "$B")"; rc=$?
is "a tree of another repository is evicted"  "0" "$rc"
is "and named where it went"                  "$G/work.alpha" "$moved"
is "the path is free for the right repository" "" "$(ls -d "$WT" 2>/dev/null)"
is "nothing was deleted"                      "work in progress" "$(cat "$moved/uncommitted" 2>/dev/null)"
is "and the moved tree is still git"          "topic" "$(git -C "$moved" branch --show-current 2>/dev/null)"
is "so the repository still registers it"     "1" \
   "$(git -C "$A" worktree list --porcelain | grep -c "^worktree $moved\$")"

# A second eviction must not overwrite the first tree it saved.
git -C "$A" worktree add -q -b topic2 "$WT" main
again="$(worktree_evict_foreign "$WT" "$B")"
[ -n "$again" ] && [ "$again" != "$moved" ] && ok "a second eviction does not clobber the first" \
    || bad "a second eviction does not clobber the first" "got [$again] again"
is "the first tree survives it" "work in progress" "$(cat "$moved/uncommitted" 2>/dev/null)"

is "an empty path is nothing to do" "1" \
   "$(worktree_evict_foreign "$G/nope" "$A" >/dev/null 2>&1; echo $?)"

# A TREE WHOSE `.git` RESOLVES TO NOTHING is evicted on the same grounds as a foreign one.
# It satisfies the caller's `-e "$WORK/.git"` check, so left in place it is reused exactly as
# silently — the aeon gets a broken checkout and no command fails. The test is "not
# demonstrably ours", so a tree that cannot answer the question is moved aside.
BROKE="$G/broken"; mkdir -p "$BROKE"; echo "gitdir: /nowhere/at/all" > "$BROKE/.git"
echo "salvage me" > "$BROKE/uncommitted"
broke_moved="$(worktree_evict_foreign "$BROKE" "$A")"; broke_rc=$?
is "an unreadable tree is evicted"       "0"   "$broke_rc"
is "the path is freed"                   ""    "$(ls -d "$BROKE" 2>/dev/null)"
is "and it too was moved, not deleted"   "salvage me" \
   "$(cat "$broke_moved/uncommitted" 2>/dev/null)"

# And aeon.sh must actually consult it before it reuses a worktree, or the function is a
# guard over nothing.
AEON="$(cat "$HERE/aeon.sh")"
want "aeon.sh calls worktree_evict_foreign" 'worktree_evict_foreign "$WORK" "$REPO"' "$AEON"
evict_at="$(grep -n 'worktree_evict_foreign "\$WORK"' "$HERE/aeon.sh" | head -1 | cut -d: -f1)"
reuse_at="$(grep -n 'if \[ ! -d "\$WORK/.git" \]' "$HERE/aeon.sh" | head -1 | cut -d: -f1)"
if [ -n "$evict_at" ] && [ -n "$reuse_at" ] && [ "$evict_at" -lt "$reuse_at" ]; then
    ok "and calls it before it reuses what it finds"
else
    bad "and calls it before it reuses what it finds" "evict at [$evict_at], reuse at [$reuse_at]"
fi

# ======================================================================================
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
