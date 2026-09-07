#!/usr/bin/env bash
#
# test-capacity-reclassify.sh — giving an attempt back is a thing that happens ONCE.
#
#   ./test-capacity-reclassify.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# `capacity.sh reclassify --apply` withdraws one attempt from every bead whose surviving
# session log ends in an account refusal. The evidence is a file, and a file is still there
# on the second run — so with no record of the withdrawal it had already made, the same log
# justified another one, and another: an observed run took sp-<x> from 3 to 2, and the very
# next dry run offered to take it from 2 to 1. Counts walking to zero is not a cosmetic
# error. Poison latches at a threshold on that count, so a bead eroded past it can never be
# poisoned again however genuinely it keeps failing, and the erosion is silent because a
# bead that is never poisoned looks exactly like a bead being retried.
#
# THE TWO PROPERTIES PULL IN OPPOSITE DIRECTIONS, and only holding both is the fix:
#
#   * the same refusal is paid back once, however many times the command is run; and
#   * a NEW refusal — a new session, a rewritten log — is still paid back.
#
# A mark keyed on the bead satisfies the first and destroys the second, quietly, in the
# direction where the only symptom is attempts that were charged for an outage staying
# charged. So the ordering below is deliberate: apply, re-apply, re-apply dry, then rewrite
# the log with a second refusal and require that one to be withdrawn.
#
# WHY THE REAL `bd`. The property is about labels — which one is the highest, whether poison
# is still on the bead after a withdrawal — and every earlier defect in this area was in code
# that read correctly function by function. A stub would model the label surface as remembered
# rather than as it is (law-prefer-the-real-dependency). Only `claude` is absent here, and it
# is not needed: this suite drives `capacity.sh` directly against logs it writes itself.
#
# covers: spira/capacity.sh
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
testdb_require test-capacity-reclassify

TMP="$(mktemp -d)"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up capreclass || { echo "test-capacity-reclassify: could not build a fixture database"; exit 1; }

RUN="$TMP/run"; mkdir -p "$RUN"
# PINNED OFF THEIR DEFAULTS ON PURPOSE. The ledger's default is `$SPIRA_RUN/capacity-withdrawn`
# and the poison threshold's is 3; asserting against either would pass just as well if the
# value were written into the code, which is the one thing the variable exists to stop.
MARKS="$TMP/paid-back-marks"
POISON_AT=2

# The command under test, in an explicit minimal environment: no spira.conf, no inherited
# SPIRA_*, nothing ambient deciding a verdict (law-gates-run-in-a-clean-environment). PATH is
# the caller's because conf.sh has already extended it to wherever `bd` lives, and HOME is the
# REAL one because `bd` may be a shim that locates the real binary through it — a scratch HOME
# makes every `bd` call exit 127, which this script reads as "no labels" and reports as
# "nothing to reclassify", a clean pass on a suite that tested nothing.
cap() {
    env -i HOME="$HOME" PATH="$PATH" TERM=dumb BD_NON_INTERACTIVE=1 \
        SPIRA_CONF="$TMP/no-such.conf" \
        SPIRA_DB="$SPIRA_DB" SPIRA_RUN="$RUN" \
        SPIRA_CAPACITY_WITHDRAWN="$MARKS" SPIRA_POISON_AT="$POISON_AT" \
        bash "$HERE/capacity.sh" "$@" 2>&1
}
labels_of() { bd -C "$SPIRA_DB" label list "$1" 2>/dev/null; }
attempt_of() {   # the top of the ladder, or 0 — never an empty string, which reads as a broken query
    local n; n="$(labels_of "$1" | grep -oE 'sp-attempt-[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)"
    printf '%s' "${n:-0}"
}
poisoned()  { case "$(labels_of "$1")" in *spira-poison*) echo yes ;; *) echo no ;; esac; }

# ---- fixtures --------------------------------------------------------------------------
# A refusal trace, verbatim in shape from the corpus: the `rate_limit_event` carrying
# `status: rejected` plus the terminal `result` record that says so in prose. $1 makes each
# refusal a DIFFERENT file, which is the whole point — a second outage is a second session.
refusal_log() {   # refusal_log <path> <session-id>
    local f="$1" sid="$2" resets; resets="$(( $(date +%s) + 3600 ))"
    { printf '{"type":"system","subtype":"init","session_id":"%s"}\n' "$sid"
      printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":1,"resetsAt":%s}}},"session_id":"%s"}\n' "$resets" "$resets" "$sid"
      printf '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit","num_turns":1,"session_id":"%s"}\n' "$sid"
    } > "$f"
}
# An ordinary failure: is_error, no rate_limit_event, no limit text. This is the shape that
# MUST go on being charged, or nothing ever poisons.
failure_log() {   # failure_log <path>
    printf '{"type":"result","subtype":"success","is_error":true,"result":"Error: the test suite failed","num_turns":4}\n' > "$1"
}

# THE WHOLE LADDER, because that is what the harness leaves behind: bump_attempt ADDS
# `sp-attempt-<n>` and never removes the rung below, so a bead on its third attempt carries
# all three and `attempts_of` reads the maximum. Seeding only the top rung would make a
# single withdrawal look like every attempt being erased at once, and the assertions would
# then be measuring the fixture rather than the code.
testdb_seed <<'JSONL'
{"id":"sp-refused","title":"refused by the account","status":"open","issue_type":"task","labels":["spira","plan","sp-attempt-1","sp-attempt-2","sp-attempt-3","spira-poison"],"updated_at":"2026-09-06T00:00:00Z"}
{"id":"sp-failed","title":"failed at its own work","status":"open","issue_type":"task","labels":["spira","plan","sp-attempt-1","sp-attempt-2","sp-attempt-3","spira-poison"],"updated_at":"2026-09-06T00:00:00Z"}
JSONL
refusal_log "$RUN/sp-refused.log" first-session
failure_log "$RUN/sp-failed.log"

# THE FIXTURE ITSELF IS A CLAIM. If the seed did not take, every assertion below reads as a
# well-behaved no-op and the suite passes having tested nothing.
is "the fixture starts at attempt 3"       "3"   "$(attempt_of sp-refused)"
is "and poisoned"                          "yes" "$(poisoned sp-refused)"

printf 'capacity: the first withdrawal\n'

out="$(cap reclassify)"
want "a dry run offers to restore the refused bead" "would restore" "$out"
want "and names the attempt it would take"          "attempt 3 -> 2" "$out"
# POISON_AT is 2 here, so dropping to 2 does not clear the threshold. Asserting the ABSENCE
# of a lift is what proves the printed offer is computed rather than boilerplate.
nowant "and does not promise a lift it cannot make" "poison would lift" "$out"
nowant "a session that failed at its own work is not offered" "sp-failed" "$out"
is  "a dry run changes nothing"            "3"   "$(attempt_of sp-refused)"

out="$(cap reclassify --apply)"
want "applying withdraws the attempt"      "RESTORED" "$out"
is  "and the count comes down by one"      "2"   "$(attempt_of sp-refused)"
is  "poison stands, the count is still at the threshold" "yes" "$(poisoned sp-refused)"
is  "the bead that genuinely failed is untouched"        "3"   "$(attempt_of sp-failed)"
[ -f "$MARKS/sp-refused" ] && ok "the withdrawal is recorded at the configured path" \
    || bad "the withdrawal is recorded at the configured path" "no mark in $MARKS"
[ -e "$MARKS/sp-failed" ] && bad "and nothing is recorded for a bead never withdrawn" "mark exists" \
    || ok "and nothing is recorded for a bead never withdrawn"

printf 'capacity: THE SAME REFUSAL IS PAID BACK ONCE\n'

# THE BUG. The log is untouched, so the evidence is identical — and the evidence is all the
# first version had. It withdrew again.
out="$(cap reclassify --apply)"
is   "a second apply leaves the count where it was" "2" "$(attempt_of sp-refused)"
want "and says the withdrawal was already made"     "ALREADY" "$out"
nowant "rather than reporting another one"          "RESTORED" "$out"

out="$(cap reclassify)"
want "a dry run agrees, so it does not misdescribe what --apply would do" "ALREADY" "$out"
nowant "and offers nothing"                         "would restore" "$out"
want "the summary distinguishes 'none found' from 'already paid'" "0 to give back, 1 already marked" "$out"
nowant "so it must not claim nothing was found"     "nothing to reclassify" "$out"

# Three more times, because erosion is cumulative and one repetition would not have caught a
# guard that only skips every other run.
cap reclassify --apply >/dev/null; cap reclassify --apply >/dev/null; cap reclassify --apply >/dev/null
is "and it holds however many times it is run" "2" "$(attempt_of sp-refused)"

printf 'capacity: A NEW REFUSAL IS STILL PAID BACK\n'

# THE POSITIVE CONTROL FOR THE MARK. Everything above is also satisfied by a mark that blocks
# the bead for ever — which would leave a real second outage charged, silently, in the
# direction nothing complains about. A new session rewrites the log; the fingerprint moves.
refusal_log "$RUN/sp-refused.log" second-session
out="$(cap reclassify --apply)"
want "a rewritten log is withdrawn again"  "RESTORED" "$out"
is   "and the count comes down again"      "1"   "$(attempt_of sp-refused)"
is   "now below the threshold, poison lifts" "no" "$(poisoned sp-refused)"
want "and the lift is reported"            "poison lifted" "$out"

out="$(cap reclassify --apply)"
is   "and the new withdrawal is itself only made once" "1" "$(attempt_of sp-refused)"
want "with the new log recorded in its turn" "ALREADY" "$out"

printf 'capacity: nothing to do at all\n'

# The ledger must not be able to make an empty run look like a paid-off one. A directory with
# no refused logs in it reports the original message, and the summary agrees.
rm -f "$RUN/sp-refused.log"
failure_log "$RUN/sp-failed.log"
out="$(cap reclassify --apply)"
want "no refusal at all says exactly that" "nothing to reclassify" "$out"
want "and the counts back it up"           "0 to give back, 0 already marked" "$out"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
