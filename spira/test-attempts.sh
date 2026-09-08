#!/usr/bin/env bash
#
# test-attempts.sh — what counts as an attempt at the work, and what only counts as a worker
# that died.
#
#   ./test-attempts.sh
#
# THE FAILURE THIS SUITE EXISTS FOR. Beads were poisoned without their work having been tried
# once. Three separate defects composed into it, and each has a case below:
#
#   1. `bd unclaim --if-assignee` was passed the FAYTH's name while the claim records the
#      AEON's, so the compare-and-swap could never match and a dying aeon never released its
#      bead.
#   2. The teardown ran under `set -e`, so that failing unclaim ended the shell inside its own
#      EXIT trap — after the counter had been bumped, before anything was logged.
#   3. strand.sh then reclaimed the ghost and bumped the SAME counter again. One death, two of
#      the three attempts, and the third summon poisoned the bead.
#
# The counter is now two counters, which is the property under test throughout: poison must
# measure the work and nothing else. And the charging rule is default-DENY — only an outcome
# that names what the WORK did wrong may charge — because every failure mode that cost the
# most was unenumerated when it fired, so a list of exemptions could not have saved any of
# them.
#
# A REAL bd ON A THROWAWAY DATABASE, because every claim here is a claim about what bd does
# with a label, a lease and a compare-and-swap. A stub would be a second implementation of the
# one thing being asked about (law-prefer-the-real-dependency).
#
# covers: spira/lib.sh spira/attempts.sh spira/aeon.sh spira/strand.sh spira/capacity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }

# ======================================================================================
# session_outcome — what ended this session? Pure text over a trace file, so it runs with no
# database at all. Only `unlanded` may charge an attempt; every other answer, INCLUDING the
# one that means "we cannot tell", is about the worker.
# ======================================================================================
TMP="$(mktemp -d)"
export SPIRA_DB="${SPIRA_DB:-$TMP/no-such-db}" SPIRA_RUN="$TMP/run"
# shellcheck disable=SC1090
. "$HERE/lib.sh"

echo "session_outcome:"

: > "$TMP/empty.log"
is "an empty trace is a session that never ran" refused "$(session_outcome "$TMP/empty.log")"

# NOT `refused`. A trace that is not there and a session that wrote nothing are different
# facts, and collapsing them would make a mis-aimed log path indistinguishable from a healthy
# harness reading a quiet one (law-absence-needs-a-positive-control). Both decline to charge;
# only the recorded cause tells a human which happened.
is "a missing trace is not classified at all" unknown "$(session_outcome "$TMP/no-such.log")"
is "an unnamed trace is not classified at all" unknown "$(session_outcome "")"

# The verbatim shape of a refusal: a synthetic assistant message and a result carrying an
# api_error_status, seconds after the claim.
cat > "$TMP/ratelimit.log" <<'LOG'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"session limit reached"}]},"error":"rate_limit"}
{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"session limit reached"}
LOG
is "a rate-limited session is not an attempt" refused "$(session_outcome "$TMP/ratelimit.log")"

# A session that acted and then ended badly at the API is still not a verdict about the work:
# the terminal record says the account refused it, and that is a fact about the account.
cat > "$TMP/worked-then-refused.log" <<'LOG'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"result","subtype":"success","is_error":true,"api_error_status":429}
LOG
is "a session refused after it acted is still not an attempt" refused "$(session_outcome "$TMP/worked-then-refused.log")"

cat > "$TMP/clean.log" <<'LOG'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":40}
LOG
is "a session that ran to its own end and left the bead open IS an attempt" unlanded "$(session_outcome "$TMP/clean.log")"

# A trace with tool calls and no terminal record is a session that was killed part-way — the
# host died, the cgroup was torn down, or its worktree was deleted under it. Nothing in it is
# a verdict about the bead.
cat > "$TMP/killed.log" <<'LOG'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Now I will"}]}}
LOG
is "a session killed mid-work is not an attempt" killed "$(session_outcome "$TMP/killed.log")"

cat > "$TMP/truncated.log" <<'LOG'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look at the bead."}]}}
LOG
is "a truncated trace with no tool call is not an attempt" refused "$(session_outcome "$TMP/truncated.log")"

# THE TRACE IS APPENDED TO ACROSS ATTEMPTS, so the classifier must read the LAST SEGMENT and
# not the file. Without that, a session refused before it wrote anything inherits the previous
# attempt's terminal `result` — which reads as `unlanded` and charges the refusal as a verdict
# about the work. That is default-allow restored through the back door, in exactly the case
# the whole rule exists for, and nothing about it would look wrong: the count just grows.
#
# THE PAIR IS THE POINT. The same two segments read as `unlanded` while the first is the last
# one, so a green result here cannot be a classifier that answers `refused` to everything
# (law-absence-needs-a-positive-control).
cp "$TMP/clean.log" "$TMP/appended.log"
is "one finished segment reads as an attempt" unlanded "$(session_outcome "$TMP/appended.log")"
printf '%s 2 aeon-t
' "$SPIRA_TRACE_MARK" >> "$TMP/appended.log"
is "a second segment that never spoke is not" refused "$(session_outcome "$TMP/appended.log")"
# And a second segment that DID run to its own end is judged on its own terms, not the first's.
cat >> "$TMP/appended.log" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"result","subtype":"success","is_error":true,"api_error_status":429}
LOG
is "and a refused second segment reads as refused" refused "$(session_outcome "$TMP/appended.log")"

# THE CHARGING RULE ITSELF, stated once over every outcome the classifier can return. This is
# the assertion that has to fail if someone adds an outcome and forgets to decide about it:
# default-deny is only default-deny while this list is exhaustive.
charges() { if outcome_charges "$1"; then echo charges; else echo free; fi; }
is "only a work verdict charges"     charges "$(charges unlanded)"
is "a refusal does not charge"       free    "$(charges refused)"
is "a killed worker does not charge" free    "$(charges killed)"
is "and UNKNOWN does not charge"     free    "$(charges unknown)"
is "nor does an outcome nobody has enumerated" free "$(charges something-new)"

# ======================================================================================
# THE TEARDOWN MUST RUN TO ITS END. Structural, and deliberately so: the regression was that
# a LATER line failed, so nothing short of reading the first line proves the guard is where it
# has to be. The behaviour it guards is exercised right below it.
# ======================================================================================
echo
echo "aeon teardown:"

first="$(sed -n '/^cleanup() {/,/^}/p' "$HERE/aeon.sh" | tail -n +2 \
          | grep -vE '^\s*(#|local |$)' | sed -n 1p)"
is "cleanup disarms errexit before anything can fail" "    set +e" "$first"

# The hazard itself, so the assertion above is not a rule nobody can see fire: under `set -e`
# a failing command inside an EXIT trap ends the shell where it stands, and every later step
# of the teardown is skipped in silence.
cat > "$TMP/hazard.sh" <<'H'
set -uo pipefail
cleanup() { echo ENTERED; false; echo LEDGER; }
trap cleanup EXIT
set -e
H
is "errexit ends a trap mid-teardown" "ENTERED" "$(bash "$TMP/hazard.sh" 2>/dev/null)"
cat > "$TMP/guarded.sh" <<'H'
set -uo pipefail
cleanup() { set +e; echo ENTERED; false; echo LEDGER; }
trap cleanup EXIT
set -e
H
is "set +e first lets it finish" "ENTERED
LEDGER" "$(bash "$TMP/guarded.sh" 2>/dev/null)"

# ======================================================================================
# TWO DOORS ONTO THE ATTEMPT COUNTER — one for each site that has authority to say
# "this work failed", and no more. The original bug was an unintended third door:
# aeon.sh bumped on the way out and strand.sh bumped again reclaiming the ghost,
# so one aeon dying cost two of the three attempts.
#
# aeon.sh:    the session ran and the model's own verdict was "not done" — session_outcome
#             returns unlanded, which is the one outcome that charges.
# sentinel.sh CHECK 5: a bead closed with no commit naming it, where the aeon's own post-
#             session check did not catch it (the aeon exited before reaching that code).
#             The normal case is handled by aeon.sh's cleanup after bead_reopen reopens
#             the bead; sentinel.sh is the safety net for the escape path.
#
# A charge site added later would be silent — nothing fails, a number is just larger —
# so the count of sites is the assertion.
# ======================================================================================
echo
echo "the counter has two doors:"
sites="$(grep -l 'bump_attempt' "$HERE"/*.sh | grep -v '/lib\.sh$' | grep -v '/test-' \
         | xargs -r -n1 basename | sort | tr '\n' ' ' | sed 's/ $//')"
is "aeon.sh and sentinel.sh charge an attempt" "aeon.sh sentinel.sh" "$sites"
# And it charges through the rule rather than around it: the call must sit inside the branch
# outcome_charges decides, not beside it.
guarded="$(sed -n '/if outcome_charges/,/^        else$/p' "$HERE/aeon.sh" | grep -c 'bump_attempt' || true)"
is "and only inside the charging branch" 1 "$guarded"
# THE THIRD COUNTER IS ALSO NOT A DOOR ONTO THE FIRST. A session that committed, closed the
# bead and was reopened over a rebase leaves a trace that reads `unlanded` — the one outcome
# that charges — so the exemption has to be decided BEFORE session_outcome is consulted, not
# after. Both halves are structural because a later edit could move the branch below the
# classifier and nothing would fail; the count would simply be larger.
requeue="$(sed -n '/if \[ -n "\$REQUEUE_CAUSE" \]; then/,/^        fi$/p' "$HERE/aeon.sh")"
is "the requeue path records a requeue"   1 "$(grep -c 'bump_requeue' <<<"$requeue")"
is "and charges no attempt for it"        0 "$(grep -c 'bump_attempt' <<<"$requeue")"
before="$(grep -n 'REQUEUE_CAUSE" \]; then' "$HERE/aeon.sh" | sed -n 1p | cut -d: -f1)"
after="$(grep -n 'cause="\$(session_outcome' "$HERE/aeon.sh" | sed -n 1p | cut -d: -f1)"
is "and it is decided before the trace is classified" yes \
   "$( [ -n "$before" ] && [ -n "$after" ] && [ "$before" -lt "$after" ] && echo yes || echo no)"

# strand.sh's reclaim path is the door that was closed. It must record the death and must not
# charge for it.
ghost="$(sed -n '/^                ghost)/,/^                    ;;/p' "$HERE/strand.sh")"
is "the reclaim path records a reclaim"   1 "$(grep -c 'bump_reclaim' <<<"$ghost")"
is "and charges no attempt for it"        0 "$(grep -c 'bump_attempt' <<<"$ghost")"
# capacity.sh withdraws a rung by finding it, never by rebuilding its name: a rung carries its
# cause now, so `sp-attempt-$cur` matches no label and the removal would withdraw nothing
# while still printing RESTORED.
is "a withdrawal looks the rung up" 1 "$(grep -c 'counter_label "$id" sp-attempt' "$HERE/capacity.sh")"

# ======================================================================================
# The counters and the release, against a real bd.
# ======================================================================================
# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-attempts
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up attempts || { echo "test-attempts: could not build a fixture database"; exit 1; }

seed() {   # seed <id> — one open, claimable bead
    testdb_reset
    testdb_seed <<JSONL
{"id":"$1","title":"a bead","status":"open","issue_type":"task","labels":["spira","plan"],"updated_at":"2026-09-06T00:00:00Z"}
JSONL
}
status_of() { bdjson show "$1" | python3 -c '
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]
print(d[0].get("status","") if d else "")' 2>/dev/null; }
num() { local v="$1"; printf '%d' "${v:-0}"; }

echo
echo "counters (real bd):"

seed sp-c1
# THE POSITIVE CONTROL. A counter helper that silently read nothing would report 0 for both
# kinds forever, and every assertion below would pass against a broken reader
# (law-absence-needs-a-positive-control).
is "a fresh bead has no attempts"      0 "$(num "$(attempts_of sp-c1)")"
is "a fresh bead has no reclaims"      0 "$(num "$(reclaims_of sp-c1)")"
is "the first attempt reads back as 1" 1 "$(num "$(bump_attempt sp-c1 unlanded)")"
is "and is visible to the reader"      1 "$(num "$(attempts_of sp-c1)")"

# THE RUNG CARRIES ITS CAUSE. "Three attempts" is only a reason to stop if all three were the
# work failing, so a poison that cannot name what charged it is a bead removed from
# circulation for reasons that have already scrolled away.
is "the rung records what charged it"  "sp-attempt-1-unlanded" "$(counter_label sp-c1 sp-attempt 1)"
is "and reads back as a cause"         "1 unlanded"            "$(attempt_causes sp-c1)"
# The number still leads the label, so every existing reader of the count is unchanged.
bump_attempt sp-c1 unlanded >/dev/null
is "a second rung still counts as 2"   2 "$(num "$(attempts_of sp-c1)")"
# A rung written before causes existed is `unrecorded`, not a guess about what it was.
bdq label add sp-c1 sp-attempt-3 >/dev/null 2>&1
is "a bare legacy rung still counts"   3 "$(num "$(attempts_of sp-c1)")"
is "and is reported as unrecorded"     "1 unlanded
2 unlanded
3 unrecorded" "$(attempt_causes sp-c1)"
# Withdrawing a rung must find the label that exists, not the one its name would suggest.
is "the legacy rung is findable"       "sp-attempt-3" "$(counter_label sp-c1 sp-attempt 3)"
# A cause carrying a space would split into two labels and desynchronise the ladder.
seed sp-c1b
bump_attempt sp-c1b "two words" >/dev/null
is "a cause with a space is one label" "sp-attempt-1-two-words" "$(counter_label sp-c1b sp-attempt 1)"
is "and the count is still readable"   1 "$(num "$(attempts_of sp-c1b)")"

# THE BEAD'S OWN ACCEPTANCE: an aeon reclaimed twice in a row carries no attempts at all.
seed sp-c2
bump_reclaim sp-c2 refused >/dev/null; bump_reclaim sp-c2 killed >/dev/null
is "two reclaims are two reclaims"          2 "$(num "$(reclaims_of sp-c2)")"
is "two reclaims cost the work no attempts" 0 "$(num "$(attempts_of sp-c2)")"
is "and each names how its worker died"     "1 refused
2 killed" "$(counter_causes sp-c2 sp-reclaim)"

# THE HARNESS PUTTING FINISHED WORK BACK IS THE THIRD KIND, and it must cost the work
# nothing. A bead cycling eight times over a moving base was charged eight attempts and
# poisoned with a branch that merged cleanly the whole time.
seed sp-c2b
bump_requeue sp-c2b rebase-conflict >/dev/null; bump_requeue sp-c2b merge-conflict >/dev/null
is "two requeues are two requeues"          2 "$(num "$(requeues_of sp-c2b)")"
is "two requeues cost the work no attempts" 0 "$(num "$(attempts_of sp-c2b)")"
is "and neither is a reclaim either"        0 "$(num "$(reclaims_of sp-c2b)")"
is "each names why the harness put it back" "1 rebase-conflict
2 merge-conflict" "$(requeue_causes sp-c2b)"

# AND THE OTHER HALF: genuine failure still poisons. This is the sentinel's own predicate,
# `attempts_of >= POISON_AT`, run against the same labels the sentinel would read.
poisons() { local n; n="$(num "$(attempts_of "$1")")"; [ "$n" -ge 3 ] && echo yes || echo no; }
is "two reclaims and nothing else do not poison"  no  "$(poisons sp-c2)"
is "and neither do requeues"                     no  "$(poisons sp-c2b)"
seed sp-c3
bump_attempt sp-c3 unlanded >/dev/null; bump_attempt sp-c3 unlanded >/dev/null
is "two real failures do not poison yet"          no  "$(poisons sp-c3)"
bump_attempt sp-c3 unlanded >/dev/null
is "three real failures still poison"             yes "$(poisons sp-c3)"

# Reclaims mixed in must not move the poison verdict either way.
seed sp-c4
bump_reclaim sp-c4 killed >/dev/null; bump_attempt sp-c4 unlanded >/dev/null
bump_reclaim sp-c4 killed >/dev/null; bump_attempt sp-c4 unlanded >/dev/null
bump_reclaim sp-c4 refused >/dev/null
is "reclaims interleaved with attempts do not poison" no "$(poisons sp-c4)"
is "the attempts are still counted exactly"           2 "$(num "$(attempts_of sp-c4)")"

# ======================================================================================
# attempts.sh reclassify — the same rule read backwards over history.
#
# The tool reads the chamber for its candidate set, so the suite gives it a chamber of its
# own rather than inheriting whichever personas the box happens to ship
# (law-gates-run-in-a-clean-environment).
# ======================================================================================
echo
echo "reclassifying rungs that name no cause:"

export SPIRA_HOME="$TMP/home"; mkdir -p "$SPIRA_HOME/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/attempts.sh" "$SPIRA_HOME/"
printf 'FAYTH_LABELS="spira,plan"\nFAYTH_EXCLUDE_LABELS="spira-poison"\nFAYTH_MAX_CONCURRENT=0\n' \
    > "$SPIRA_HOME/chamber/t.fayth"
ATT="$SPIRA_HOME/attempts.sh"

seed sp-h1
# The state the board was actually in: rungs written before a charge had to name what it was.
bdq label add sp-h1 sp-attempt-1 >/dev/null 2>&1
bdq label add sp-h1 sp-attempt-2 >/dev/null 2>&1
bdq label add sp-h1 sp-attempt-3 >/dev/null 2>&1
is "history poisons before the sweep" yes "$(poisons sp-h1)"
# THE AUDIT IS ITS OWN POSITIVE CONTROL: a candidate query that returned nothing would make
# every reclassify assertion below pass against a tool that looked at no beads at all.
want_audit="$("$ATT" audit 2>&1)"
case "$want_audit" in *"sp-h1"*"attempts=3"*) ok "the audit finds the bead and its count" ;;
                      *) bad "the audit finds the bead and its count" "got [$want_audit]" ;; esac
"$ATT" reclassify >/dev/null 2>&1
is "a dry run changes nothing"        3 "$(num "$(attempts_of sp-h1)")"
"$ATT" reclassify --apply >/dev/null 2>&1
is "unnamed rungs stop feeding poison" 0 "$(num "$(attempts_of sp-h1)")"
is "and are kept, on the counter that stops nothing" 3 "$(num "$(reclaims_of sp-h1)")"
is "recorded as what they are"         "1 unrecorded
2 unrecorded
3 unrecorded" "$(counter_causes sp-h1 sp-reclaim)"

# THE LADDER IS ITS TOP RUNG, NOT ITS RUNG COUNT. Removing rung 1 from a bead whose top rung
# is 2 would leave a gap that still reads as 2 — the withdrawal would be invisible in the one
# number the threshold consults. The survivors have to come back renumbered.
seed sp-h2
bdq label add sp-h2 sp-attempt-1 >/dev/null 2>&1
bump_attempt sp-h2 unlanded >/dev/null
is "a mixed ladder starts at 2"        2 "$(num "$(attempts_of sp-h2)")"
"$ATT" reclassify --apply >/dev/null 2>&1
is "the surviving rung is renumbered"  1 "$(num "$(attempts_of sp-h2)")"
is "and it keeps its cause"            "1 unlanded" "$(attempt_causes sp-h2)"
is "the withdrawn one moved across"    1 "$(num "$(reclaims_of sp-h2)")"

# A BEAD ALREADY POISONED KEEPS ITS LABEL. Clearing a false count is arithmetic; re-queueing a
# bead somebody has an open decision about is not, so the tool leaves the label for a human.
# It must still SEE the bead: a poisoned bead is excluded from dispatch and is precisely the
# one whose count most needs repairing, so a candidate query filtered by the personas'
# exclusions would skip every bead this exists for.
seed sp-h3
bdq label add sp-h3 sp-attempt-1 >/dev/null 2>&1
bdq label add sp-h3 sp-attempt-2 >/dev/null 2>&1
bdq label add sp-h3 sp-attempt-3 >/dev/null 2>&1
bdq label add sp-h3 spira-poison >/dev/null 2>&1
"$ATT" reclassify --apply >/dev/null 2>&1
is "its false count is cleared"        0 "$(num "$(attempts_of sp-h3)")"
poison_label() { bdq label list "$1" 2>/dev/null | sed -n 's/^ *- \(spira-poison\)$/\1/p'; }
is "but the poison label is left alone" "spira-poison" "$(poison_label sp-h3)"

# And it is idempotent: a second sweep finds nothing, because every rung now names a cause.
out="$("$ATT" reclassify --apply 2>&1)"
case "$out" in *"nothing to reclassify"*) ok "a second sweep finds nothing" ;;
               *) bad "a second sweep finds nothing" "got [$out]" ;; esac

echo
echo "prune-reclaims — strip ghost-storm unrecorded reclaim labels:"

# The five beads that accumulated unrecorded reclaims from the 2026-09-06 429 storm are all
# closed; this test uses an open bead to exercise the same code path through the real bd.
seed sp-p1
bump_reclaim sp-p1 unrecorded >/dev/null; bump_reclaim sp-p1 unrecorded >/dev/null
bump_reclaim sp-p1 ghost >/dev/null       # a named-cause rung — must survive pruning
is "pre-prune: 3 reclaims total"  3 "$(num "$(reclaims_of sp-p1)")"
is "pre-prune: reclaims are 1 unrecorded, 2 unrecorded, 3 ghost" \
   "1 unrecorded
2 unrecorded
3 ghost" "$(counter_causes sp-p1 sp-reclaim)"

"$ATT" prune-reclaims sp-p1 >/dev/null 2>&1
is "a dry run removes nothing"    3 "$(num "$(reclaims_of sp-p1)")"

"$ATT" prune-reclaims sp-p1 --apply >/dev/null 2>&1
# The named-cause rung stays; only the unrecorded ones come off. The rung does NOT get
# renumbered — unlike the attempt counter (where position is what the poison threshold reads),
# the reclaim counter is diagnostic only, and leaving the ghost at rung 3 is the faithful record.
is "named-cause rung survives at its original position" "3 ghost" "$(counter_causes sp-p1 sp-reclaim)"
# counter_of reads the maximum N; the remaining label is sp-reclaim-3-ghost, so it reads 3.
is "counter reflects the surviving rung"                3 "$(num "$(reclaims_of sp-p1)")"

# IDEMPOTENT: a second apply on a clean bead prints "nothing to prune".
out="$("$ATT" prune-reclaims sp-p1 --apply 2>&1)"
case "$out" in *"nothing to prune"*) ok "idempotent: a second sweep finds nothing" ;;
               *) bad "idempotent: a second sweep finds nothing" "got [$out]" ;; esac

# POSITIVE CONTROL: a bead with no unrecorded reclaims is skipped.
seed sp-p2
bump_reclaim sp-p2 ghost >/dev/null
out="$("$ATT" prune-reclaims sp-p2 --apply 2>&1)"
case "$out" in *"nothing to prune"*) ok "a bead with only named reclaims is skipped" ;;
               *) bad "a bead with only named reclaims is skipped" "got [$out]" ;; esac

# NO IDs = error, not a sweep.
if "$ATT" prune-reclaims 2>/dev/null; then r=0; else r=1; fi
is "prune-reclaims with no args exits non-zero" 1 "$r"

echo
echo "the release (real bd):"

# THE DISCRIMINATING FACT, seen both ways. The claim records BEADS_ACTOR; the teardown must
# name that same actor or the compare-and-swap can never match.
seed sp-r1
BEADS_ACTOR=aeon-cindy bdq update sp-r1 --claim >/dev/null 2>&1
is "the claim records the aeon, not the fayth" in_progress "$(status_of sp-r1)"

if bdq unclaim sp-r1 --if-assignee aeon-builder >/dev/null 2>&1; then r=0; else r=1; fi
is "releasing as the fayth fails"        1           "$r"
is "and leaves the bead held"            in_progress "$(status_of sp-r1)"

if bdq unclaim sp-r1 --if-assignee aeon-cindy >/dev/null 2>&1; then r=0; else r=1; fi
is "releasing as the aeon succeeds"      0    "$r"
is "and the bead is claimable again"     open "$(status_of sp-r1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
