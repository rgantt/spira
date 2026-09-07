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
#
# covers: spira/capacity.sh spira/aeon.sh
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
# DELIBERATELY OFF ITS DEFAULT, which is `$SPIRA_RUN/capacity-withdrawn`. Asserting against
# the shipped default passes just as well if the path is written into the code, which is the
# one thing a settable key exists to prevent.
export SPIRA_CAPACITY_WITHDRAWN="$TMP/paid-back-marks"
# shellcheck disable=SC1090
. "$HERE/lib.sh"
# lib.sh resolves these at source time from whatever conf is on the box; the fixture wins.
SPIRA_RUN="$TMP/run"
SPIRA_CAPACITY_PAUSE="$SPIRA_RUN/capacity-pause"
SPIRA_CAPACITY_WITHDRAWN="$TMP/paid-back-marks"

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

# ---- one log per bead, one segment per attempt -----------------------------------------
# aeon.sh used to truncate the session log on every attempt, so a bead only ever had a trace
# of its LAST session; a capacity outage that killed 121 sessions in three to seven seconds
# left three traces behind. It appends now, which means every reader that asks "what is
# happening" must find the newest segment — a `result` record from attempt 1 read as attempt
# 3's would pause the harness against a window that reopened hours ago, and hand an attempt
# back to a bead that genuinely failed.
printf 'capacity: the trace keeps every attempt\n'

RESETS2=$(( RESETS + 7200 ))
rl2() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false},"uuid":"u","session_id":"s"}\n' "$1" "$RESETS2"; }
mark() { spira_trace_mark "$1" "aeon-fixture" >> "$1"; }

# A LEGACY LOG — no mark anywhere, because it was written before this change. It is one
# attempt and must be read whole; a segment finder that returned nothing here would make
# every log already on disk invisible.
LEGACY="$(mklog legacy "$(rl_event rejected 1)" "$(result_line true "You've hit your session limit")")"
is  "a log with no mark is its own segment" "$(wc -c < "$LEGACY")" "$(attempt_trace "$LEGACY" | wc -c)"
capacity_reset_at "$LEGACY" >/dev/null
is  "and is still read for a refusal" "0" "$?"

# THE CENTRAL CASE. Attempt 1 was refused; attempt 2 failed at its own work. Under the old
# code the second attempt erased the first and the question could not arise; appending makes
# it the default failure, so it is the one asserted first.
TWO="$TMP/two.log"; : > "$TWO"
mark "$TWO"; rl_event rejected 1 >> "$TWO"; result_line true "You've hit your session limit" >> "$TWO"
mark "$TWO"; rl_event allowed 0.3 >> "$TWO"; result_line true "Error: the test suite failed" >> "$TWO"
capacity_reset_at "$TWO" >/dev/null
is  "attempt 1's refusal is not attempt 2's" "1" "$?"
want "but attempt 1's trace is still there"  "hit your session limit" "$(cat "$TWO")"

# THE POSITIVE CONTROL FOR THE SAME MACHINERY: the refusal in the LAST segment is found, and
# the epoch reported is that segment's and not the earlier one's. Without this, the case above
# passes just as well on a reader that can no longer detect a refusal at all.
THREE="$TMP/three.log"; : > "$THREE"
mark "$THREE"; rl_event rejected 1 >> "$THREE"; result_line true "You've hit your session limit" >> "$THREE"
mark "$THREE"; result_line true "Error: the test suite failed" >> "$THREE"
mark "$THREE"; rl2 rejected >> "$THREE"; result_line true "You've hit your session limit" >> "$THREE"
out="$(capacity_reset_at "$THREE")"; rc=$?
is  "a refusal in the last segment is detected" "0" "$rc"
is  "and reports that segment's epoch"          "$RESETS2" "$out"

# THE MARK MAY STRADDLE A CHUNK BOUNDARY. attempt_trace reads backwards in 64KiB chunks
# because this runs on every heartbeat of every live aeon; a mark split across two reads is
# the one input that finds that seam, and it cannot be hit by a small fixture.
BIG="$TMP/big.log"; : > "$BIG"
mark "$BIG"
python3 -c 'import sys
sys.stdout.write("".join("{\"type\":\"pad\",\"n\":%d,\"x\":\"%s\"}\n" % (i, "p"*900) for i in range(300)))' >> "$BIG"
for _ in 1 2 3 4 5 6 7; do
    mark "$BIG"
    python3 -c 'import sys
sys.stdout.write("".join("{\"type\":\"pad\",\"n\":%d,\"x\":\"%s\"}\n" % (i, "q"*900) for i in range(80)))' >> "$BIG"
done
mark "$BIG"; rl2 rejected >> "$BIG"; result_line true "You've hit your session limit" >> "$BIG"
[ "$(wc -c < "$BIG")" -gt 500000 ] && ok "the straddle fixture is bigger than one chunk" \
    || bad "the straddle fixture is bigger than one chunk" "only $(wc -c < "$BIG") bytes"
is  "the last mark is found across chunk boundaries" "3" "$(attempt_trace "$BIG" | wc -l)"
is  "and the refusal in it is read" "$RESETS2" "$(capacity_reset_at "$BIG")"

# WHAT THE HEARTBEAT SEES. still_waiting asks trace_last what the session was last doing and
# grants a reprieve on the answer, so a fresh attempt that has written nothing yet must read
# as nothing — not as the previous session's `cargo test`, which would buy a wedged aeon six
# free extensions on evidence from a session that is already over.
tool_line() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$1"; }
TL="$TMP/tl.log"; : > "$TL"
mark "$TL"; tool_line "cargo test --all" >> "$TL"
is   "trace_last reads the only segment there is" "Bash cargo test --all" "$(trace_last "$TL")"
mark "$TL"; tool_line "grep -rn thing src" >> "$TL"
is   "trace_last reads the newest segment"        "Bash grep -rn thing src" "$(trace_last "$TL")"
mark "$TL"
is   "a segment with no events yet reads as nothing" "" "$(trace_last "$TL")"
still_waiting "$TL"; is "so the heartbeat does not grant it a reprieve" "1" "$?"

# THE MARK IS ITS OWN COUNTER. The ordinal comes from the marks in the file rather than from
# the bead's sp-attempt-N labels, because a refused session is charged no attempt at all and
# a successful one none either — so the labels answer "how many failures were blamed on this
# work", not "which session is this".
is   "the first mark is attempt 1" "1" "$(awk 'NR==1{print $4}' "$TL")"
is   "the third is attempt 3"      "3" "$(awk '/^=== spira attempt/{n=$4} END{print n}' "$TL")"
grep -q 'kept=0' <<< "$(head -1 "$TL")" && ok "the meter starts at nothing kept" \
    || bad "the meter starts at nothing kept" "$(head -1 "$TL")"
kept="$(awk '/^=== spira attempt/{split($NF,a,"="); k=a[2]} END{print k}' "$TL")"
[ "${kept:-0}" -gt 0 ] && ok "and records the bytes already retained, so growth is visible" \
    || bad "and records the bytes already retained" "kept=[$kept]"

# BOTH OF THE MARK'S READS FAIL ON A FIRST ATTEMPT — there is no file for `stat` and no mark
# for `grep -c` — and those are answers, not errors. Under a caller running `set -e` a bare
# assignment from either aborts the shell at the one line that opens the log, so a bead's
# whole attempt would be lost to the file not existing yet. Run in its own errexit shell,
# because this suite does not set it and so cannot observe the fault by calling the function.
out="$(bash -c 'set -euo pipefail; . "$1"/lib.sh >/dev/null 2>&1; spira_trace_mark "$2" aeon-x' \
       _ "$HERE" "$TMP/never-written.log" 2>&1)"
want "an errexit caller survives the first mark of a bead" "attempt 1" "$out"
want "and the meter reads nothing kept"                    "kept=0"    "$out"

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

printf 'capacity: the withdrawal ledger\n'

# WHY THERE IS A LEDGER AT ALL. The evidence for giving an attempt back is a file, and a file
# is still there tomorrow — so a cleanup with no memory of itself reads the same refusal as
# grounds for a second withdrawal, then a third, and attempt counts walk to zero. Nothing can
# poison after that, however genuinely it keeps failing, and nothing complains: a bead that is
# never poisoned looks exactly like a bead being retried. test-capacity-reclassify.sh holds
# that property end to end through `capacity.sh` against a real `bd`; these are the primitives
# it rests on, checked where no database is needed to check them.

# THE IDENTITY IS THE LOG'S CONTENT. The horizon is one attempt deep — aeon.sh truncates the
# log on every attempt — so "already paid back" is exactly "the same log I paid back before".
FP1="$(capacity_log_fingerprint "$REFUSED")"
[ -n "$FP1" ] && ok "a log has a fingerprint" || bad "a log has a fingerprint" "empty"
is "and the same content fingerprints the same" "$FP1" "$(capacity_log_fingerprint "$REFUSED")"

# THE POSITIVE CONTROL. Without a case where the fingerprint is KNOWN to move, "it did not
# move" is indistinguishable from a function that returns a constant — and a constant would
# block every future outage from ever being paid back, silently.
cp "$REFUSED" "$TMP/second.log"
printf '{"type":"result","subtype":"success","is_error":true,"result":"a second session"}\n' >> "$TMP/second.log"
[ "$(capacity_log_fingerprint "$TMP/second.log")" != "$FP1" ] \
    && ok "and a rewritten log fingerprints differently" \
    || bad "and a rewritten log fingerprints differently" "unchanged"

capacity_log_fingerprint "$TMP/does-not-exist.log" >/dev/null
is "a missing log has no fingerprint" "1" "$?"
: > "$TMP/nothing.log"; capacity_log_fingerprint "$TMP/nothing.log" >/dev/null
is "nor does an empty one"            "1" "$?"

is "an unmarked bead has nothing recorded against it" "" "$(capacity_withdrawn_fp sp-fixture)"
capacity_withdrawn_mark sp-fixture "$FP1" 3
is "a mark reads back the fingerprint it was given" "$FP1" "$(capacity_withdrawn_fp sp-fixture)"
[ -f "$TMP/paid-back-marks/sp-fixture" ] \
    && ok "written where SPIRA_CAPACITY_WITHDRAWN points, not beside the logs" \
    || bad "written where SPIRA_CAPACITY_WITHDRAWN points, not beside the logs" "not in $TMP/paid-back-marks"
[ ! -e "$SPIRA_RUN/capacity-withdrawn" ] \
    && ok "and nothing is written to the default path"  \
    || bad "and nothing is written to the default path" "the default was used as well"

# OVERWRITTEN, NEVER APPENDED. One line per bead is the whole question, and a second mark for
# the same bead must supersede the first rather than leave the old fingerprint to be read.
capacity_withdrawn_mark sp-fixture "$(capacity_log_fingerprint "$TMP/second.log")" 2
is "a later withdrawal replaces the mark" \
   "$(capacity_log_fingerprint "$TMP/second.log")" "$(capacity_withdrawn_fp sp-fixture)"
is "and the file stays one line"  "1" "$(wc -l < "$TMP/paid-back-marks/sp-fixture")"

capacity_withdrawn_mark sp-nofp "" 1
is "a mark with no fingerprint is refused rather than written blank" "1" "$?"
[ -e "$TMP/paid-back-marks/sp-nofp" ] \
    && bad "and leaves no file behind" "it wrote one" || ok "and leaves no file behind"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
