#!/usr/bin/env bash
#
# test-capacity.sh — the account running out of capacity must cost a bead nothing.
#
#   ./test-capacity.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# The harness had no concept of API capacity. aeon.sh took the session's exit code and any
# non-zero became a failed attempt, so a session the account refused to serve was recorded as
# work that could not be done — and because attempts poison at a threshold, an outage did not
# merely stall the queue, it removed beads from it permanently.
#
# TWO PROPERTIES CARRY THE WEIGHT, AND THEY PULL IN OPPOSITE DIRECTIONS:
#
#   * a refused session is returned unchanged and charged nothing; and
#   * a bead that genuinely fails three times still poisons.
#
# A detector that is too eager satisfies the first and destroys the second — silently, and
# in the direction where nothing ever complains, because a bead that is never poisoned just
# looks like a bead being retried. So every case below that asserts a refusal is matched by
# one asserting an ordinary failure is still an ordinary failure.
#
# THE FIXTURES ARE VERBATIM CAPTURES, NOT SKETCHES (law-prefer-the-real-dependency). The
# rejection is the one real `status: rejected` event this harness has ever recorded, at
# `utilization: 1`, and the healthy event is a real one
# from the same corpus. That matters more than usual here because the two differ in ONE
# field: both carry `"overageStatus":"rejected"`, which is a standing property of this
# account and appears on all 443 healthy events as well. A hand-written "healthy" fixture
# would have omitted it, the negative control would have passed, and the detector would have
# shipped pausing the harness for ever at 7% utilization.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_CAPACITY_PAUSE="$SPIRA_RUN/capacity-pause"
# shellcheck disable=SC1090
. "$HERE/lib.sh"
# lib.sh resolves these at source time from whatever conf is on the box; the fixture wins.
SPIRA_RUN="$TMP/run"
SPIRA_CAPACITY_PAUSE="$SPIRA_RUN/capacity-pause"

RESETS=1788696000       # the reset epoch the real rejection carried

# ---- fixtures ------------------------------------------------------------------------
# One `rate_limit_event` line, verbatim in shape from the corpus. $1 is the status.
rl_event() {
    printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s},"seven_day":{"utilization":0.41,"resetsAt":1788807600}}},"uuid":"cfc8b3c9","session_id":"02155393"}\n' \
        "$1" "$RESETS" "${2:-1}" "$RESETS"
}
result_line() {   # result_line <is_error> <text>
    printf '{"type":"result","subtype":"success","is_error":%s,"result":"%s","num_turns":1,"session_id":"02155393"}\n' "$1" "$2"
}
mklog() { local f="$TMP/$1.log"; shift; : > "$f"; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done; printf '%s' "$f"; }

printf 'capacity: the detector\n'

# THE POSITIVE CONTROL. Without a case that is KNOWN to be a refusal and is SEEN to be
# detected, every "not a refusal" result below is indistinguishable from a detector that
# cannot detect anything at all.
REFUSED="$(mklog refused \
    '{"type":"system","subtype":"init","session_id":"02155393"}' \
    "$(rl_event rejected 1)" \
    '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 12pm (UTC)"}],"stop_reason":"stop_sequence"}}' \
    "$(result_line true "You've hit your session limit · resets 12pm (UTC)")")"
out="$(capacity_reset_at "$REFUSED")"; rc=$?
is  "a refused session is detected"                 "0" "$rc"
is  "and carries the epoch the window reopens"      "$RESETS" "$out"

# THE NEGATIVE CONTROL THAT MATTERS. Healthy, 7% utilization — and still carrying
# "overageStatus":"rejected", because overage is disabled on this account as a standing
# configuration. Keying on that field instead of `status` pauses the harness for ever.
HEALTHY="$(mklog healthy \
    "$(rl_event allowed 0.07)" \
    "$(rl_event allowed_warning 0.82)" \
    "$(result_line false "done")")"
capacity_reset_at "$HEALTHY" >/dev/null
is  "a healthy session is not a refusal, though overageStatus says rejected" "1" "$?"

# An ordinary failure. is_error is true and there is no rate_limit_event at all — this is
# the shape that MUST keep charging an attempt, or nothing ever poisons.
FAILED="$(mklog failed \
    "$(rl_event allowed 0.3)" \
    "$(result_line true "Error: the test suite failed")")"
capacity_reset_at "$FAILED" >/dev/null
is  "an ordinary failure is still an ordinary failure" "1" "$?"

# A session killed mid-write. The last line is half a JSON object, which json.loads rejects;
# the refusal earlier in the file must still be found.
TRUNC="$(mklog trunc "$(rl_event rejected 1)" '{"type":"assistant","message":{"content":[{"typ')"
capacity_reset_at "$TRUNC" >/dev/null
is  "a truncated trailing line does not hide the refusal" "0" "$?"

# The refusal without an epoch — the branch that should never run, and must not crash.
NOEPOCH="$(mklog noepoch "$(result_line true "Claude AI usage limit reached")")"
out="$(capacity_reset_at "$NOEPOCH")"; rc=$?
is  "a refusal with no resetsAt is still a refusal" "0" "$rc"
is  "and reports epoch 0 rather than guessing"      "0" "$out"

capacity_reset_at "$TMP/does-not-exist.log" >/dev/null
is  "a missing log is not a refusal" "1" "$?"
: > "$TMP/empty.log"; capacity_reset_at "$TMP/empty.log" >/dev/null
is  "an empty log is not a refusal"  "1" "$?"
printf 'not json\nneither is this\n' > "$TMP/junk.log"; capacity_reset_at "$TMP/junk.log" >/dev/null
is  "an unparseable log is not a refusal" "1" "$?"

printf 'capacity: the pause\n'
rm -f "$SPIRA_CAPACITY_PAUSE"
capacity_paused; is "no file means no pause" "1" "$?"

now="$(date +%s)"
capacity_pause_set "$(( now + 300 ))" "sp-fixture" >/dev/null
capacity_paused; is "a pause in the future holds" "0" "$?"
[ "${SPIRA_CAPACITY_LEFT:-0}" -gt 240 ] && ok "and reports the seconds remaining" \
    || bad "and reports the seconds remaining" "got [$SPIRA_CAPACITY_LEFT]"
want "the pause names what was returned" "sp-fixture" "$(capacity_pause_why)"

# EXTENDED, NEVER SHORTENED. A second aeon dying into the same outage reads its own,
# earlier, resetsAt; letting it win would reopen the window while the account is still shut
# and spend another bead's attempt proving it.
capacity_pause_set "$(( now + 60 ))" "sp-second" >/dev/null
is "an earlier reading does not shorten a live pause" "$(( now + 300 ))" "$(capacity_pause_until)"
capacity_pause_set "$(( now + 900 ))" "sp-third" >/dev/null
is "a later one extends it" "$(( now + 900 ))" "$(capacity_pause_until)"

# An epoch already in the past is a clock disagreement, not an instruction to do nothing.
# Fall back to the backoff rather than writing a pause that is over before it is read.
rm -f "$SPIRA_CAPACITY_PAUSE"
SPIRA_CAPACITY_BACKOFF=600 capacity_pause_set "$(( now - 5000 ))" "sp-stale" >/dev/null
capacity_paused; is "a resetsAt in the past falls back to the backoff" "0" "$?"

# EXPIRY REMOVES THE FILE. Anything reading the pause without this library — a panel, a
# human, a future script — must be able to trust the file's existence as the answer.
printf '%s x expired\n' "$(( now - 10 ))" > "$SPIRA_CAPACITY_PAUSE"
outp="$(capacity_paused; echo "rc=$?")"
is   "an expired pause does not hold"            "rc=1" "$(printf '%s' "$outp" | tail -1)"
want "and announces that the window reopened"    "reopened" "$outp"
[ ! -f "$SPIRA_CAPACITY_PAUSE" ] && ok "and deletes the file" || bad "and deletes the file" "still there"

# A pause file somebody corrupted must not read as "paused for ever" nor crash the sentinel.
printf 'garbage\n' > "$SPIRA_CAPACITY_PAUSE"
is "a corrupt pause file reads as epoch 0" "0" "$(capacity_pause_until)"
capacity_paused; is "and therefore does not hold" "1" "$?"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
