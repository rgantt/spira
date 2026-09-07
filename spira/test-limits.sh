#!/usr/bin/env bash
#
# test-limits.sh — the two rate-limit windows: the samples, the projection, and what is shown
# when there is nothing to project from.
#
#   ./test-limits.sh
#
# WHAT THIS SUITE IS GUARDING. These two numbers are the ones that end a working day, so the
# expensive failure is not a missing segment but a reassuring one: a window rendered at 0%
# because the client sent none, or "resets in 3d" computed across a reset boundary, is good
# news nobody measured. Every case that asserts something is ABSENT therefore first proves the
# same code path renders it when it is present (law-absence-needs-a-positive-control), and the
# `-`/`?`/0 distinction is asserted directly rather than assumed.
#
# THE CLOCK IS INJECTED. A projection is a statement about a moment, so a suite that used the
# real clock would be asserting against whenever it happened to run — and the reset-boundary
# case needs samples minutes apart without waiting minutes. `SPIRA_NOW` is read from the
# environment and is deliberately not a config key, so nothing an operator writes in spira.conf
# can freeze the clock of a live installation.
#
# AND IT RUNS UNDER `env -i`. A suite that inherits the operator's spira.conf writes samples
# into their real runtime directory and asserts against their real account
# (law-gates-run-in-a-clean-environment).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
CTX="$HERE/ctx-meter.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1${2:+: $2}"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found [$3] in [$2]" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/home" "$T/run" "$T/projects/-a-project"

# The fixture's knobs, all pinned away from the shipped defaults: asserting against a default
# passes just as well with the value written back into the code, which is what the key exists
# to stop. NONE points the config reader at a path that does not exist, which is how it is told
# to read no file at all.
NONE="$T/no-such.conf"
CW=900; CH=1800; CL=2700
SAMPLES="$T/run/limits.samples"

# EPOCH is a fixed instant the whole suite reasons from, so every expectation is arithmetic on
# it rather than on whenever the suite ran.
EPOCH=1750000000

# meter <mode> <at-epoch> [arg] — the meter under a minimal environment and a frozen clock.
# stdin is the hook blob for `line` mode and is ignored by `env`.
meter() {
    local mode="$1" at="$2"; shift 2
    env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" \
        SPIRA_RUN="$T/run" SPIRA_TOKEN_PROJECTS="$T/projects" \
        SPIRA_CTX_WARN="$CW" SPIRA_CTX_HIGH="$CH" SPIRA_CTX_LIMIT="$CL" \
        SPIRA_NOW="$at" \
        bash "$CTX" "$mode" "$@" 2>/dev/null
}
val() { sed -n "s/^$1=//p"; }

# blob <five-pct> <five-reset> <seven-pct> <seven-reset> — a status-line payload carrying the
# windows named. A window is omitted entirely when its percentage is given as `-`, which is how
# the client reports one that has not appeared yet or has already reset.
#
# THE SHAPE IS THE ONE CAPTURED FROM A REAL CLIENT, not one invented here: rate_limits.
# {five_hour,seven_day}.{used_percentage,resets_at}, integers, alongside context_window.
blob() {
    python3 - "$@" <<'PY'
import json, sys
p5, r5, p7, r7 = sys.argv[1:5]
rl = {}
if p5 != "-": rl["five_hour"]  = {"used_percentage": int(p5), "resets_at": int(r5)}
if p7 != "-": rl["seven_day"] = {"used_percentage": int(p7), "resets_at": int(r7)}
out = {
    "session_id": "s-1",
    "transcript_path": sys.argv[5],
    "cwd": "/tmp",
    "context_window": {"total_input_tokens": 1200, "current_usage": {"input_tokens": 1200},
                       "used_percentage": 1, "context_window_size": 1000000},
}
if rl: out["rate_limits"] = rl
print(json.dumps(out))
PY
}

# One transcript so the ctx half of the line has something to say; this suite asserts nothing
# about it beyond that the limits segment is appended and not substituted for it.
TP="$T/projects/-a-project/s-1.jsonl"
printf '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":10}}}\n' > "$TP"

# feed <at> <p5> <r5> <p7> <r7> -> the rendered line
feed() { blob "$2" "$3" "$4" "$5" "$TP" | meter line "$1"; }

strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# ==========================================================================================
echo
echo "the projection — a climbing window, and when it is full"
# ==========================================================================================
# Three samples five minutes apart, 60 -> 62 -> 64%. That is 0.4 points a minute, and from 64%
# there are 36 points left, so the window is full in 90 minutes. The reset is a day away, so it
# cannot be what the line reports.
rm -f "$SAMPLES"
feed "$EPOCH"            60 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))"  62 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 600))" 64 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) | strip)"

has "the 5-hour window is rendered with its percentage" "$L" "5h 64%"
has "and the measured rate that justifies the warning" "$L" "↑24.0%/h"
# ±5 minutes of 1h30m, asserted as the set of renderings that satisfies it rather than by
# re-deriving the arithmetic here — a test that recomputes the formula passes when the formula
# is wrong in both places.
case "$L" in
    *"full in ~1h2"[5-9]m*|*"full in ~1h3"[0-5]m*) ok "full in ~1h30m, within five minutes" ;;
    *) bad "full in ~1h30m, within five minutes" "$L" ;;
esac
has "the ctx segment it is appended to is untouched" "$L" "ctx 1k"

# THE POSITIVE CONTROL FOR EVERY ABSENCE BELOW. The line above proves this code path renders a
# percentage, a rate and a projection when the client supplies the windows; a later case
# asserting that one of them is missing is therefore about the input and not about a segment
# that never renders at all.
has "positive control: the segment renders at all" "$L" "7d 41%"

# ==========================================================================================
echo
echo "the reset — a window that empties before it fills"
# ==========================================================================================
# The same climb, but the window resets in eighty minutes, which is sooner than the ninety it
# would take to fill. The limit will not bite, so the line says so and does not warn.
rm -f "$SAMPLES"
R=$((EPOCH + 600 + 4800))
feed "$EPOCH"            60 "$R" 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))"  62 "$R" 41 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 600))" 64 "$R" 41 $((EPOCH + 600000)) | strip)"
has "resets in, not full in"              "$L" "5h 64% resets in 1h20m"
hasnt "and no warning is raised"          "$L" "full in"
hasnt "nor the rate, which is not actionable when the window empties first" "$L" "%/h"

# ==========================================================================================
echo
echo "no rate — a flat window projects nothing at all"
# ==========================================================================================
rm -f "$SAMPLES"
feed "$EPOCH"           60 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))" 60 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 600))" 60 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) | strip)"
has   "the percentage is still shown"     "$L" "5h 60%"
hasnt "no fill projection"                "$L" "full in"
hasnt "no reset projection either"        "$L" "resets in"
hasnt "and never an infinity"             "$L" "∞"

# A single sample cannot have a slope, and that must render as nothing rather than as 0m.
rm -f "$SAMPLES"
L="$(feed "$EPOCH" 60 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) | strip)"
has   "one sample still shows the percentage" "$L" "5h 60%"
hasnt "one sample projects nothing"           "$L" "full in"
hasnt "and does not project zero minutes"     "$L" "~0m"

# ==========================================================================================
echo
echo "a reset mid-history is a boundary, not a fall in usage"
# ==========================================================================================
# 88% then 90%, then the window turns over to 3% and climbs to 5%. Averaged across the drop the
# slope is hugely negative and nothing would be projected at exactly the moment a fresh window
# starts filling; measured from the drop it is 0.4 points a minute again, so 95 points take
# almost four hours.
rm -f "$SAMPLES"
feed "$EPOCH"            88 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))"  90 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 600))"   3 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 900))"   5 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 1200))" 7 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) | strip)"
has "the new window projects from after the reset" "$L" "↑24.0%/h"
has "and the fill is measured from its own level"  "$L" "full in ~3h52m"

# ==========================================================================================
echo
echo "a full window — nothing left to project, so say when it empties"
# ==========================================================================================
rm -f "$SAMPLES"
R=$((EPOCH + 2820))
feed "$EPOCH"           98 "$R" 41 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 300))" 100 "$R" 41 $((EPOCH + 600000)) | strip)"
has   "the reset is shown even though there is no fill left to project" "$L" "5h 100% resets in 42m"
hasnt "and it is not reported as filling"                               "$L" "full in"
E="$(meter env "$((EPOCH + 300))")"
is "a full window is zero seconds from full, which is a measurement" \
   "0" "$(val SP_LIMIT_5H_ETA <<<"$E")"

# ==========================================================================================
echo
echo "an absent window renders nothing, never 0%"
# ==========================================================================================
rm -f "$SAMPLES"
L="$(feed "$EPOCH" - - - - | strip)"
hasnt "no 5-hour segment when the client sent none" "$L" "5h"
hasnt "no 7-day segment either"                     "$L" "7d"
hasnt "and above all not a reassuring zero"         "$L" "0%"
has   "the ctx segment is still rendered"           "$L" "ctx 1k"
is    "and no sample file is written"               "absent" \
      "$([ -e "$SAMPLES" ] && echo present || echo absent)"

# One window present and one absent — they are independently absent, and the present one must
# still render.
rm -f "$SAMPLES"
L="$(feed "$EPOCH" 55 $((EPOCH + 86400)) - - | strip)"
has   "the window that was sent renders"  "$L" "5h 55%"
hasnt "the one that was not does not"     "$L" "7d"

# ==========================================================================================
echo
echo "the samples file — pruned to half an hour, and written whole"
# ==========================================================================================
# Two hundred lines a minute apart, so all but the last thirty are older than the window. They
# are given distinct percentages, because a run of identical readings is collapsed on purpose
# and would make this case pass for the wrong reason.
rm -f "$SAMPLES"
python3 - "$SAMPLES" "$EPOCH" <<'PY'
import sys
path, epoch = sys.argv[1], int(sys.argv[2])
with open(path, "w") as fh:
    for i in range(200):
        fh.write("%d %d %d %d %d\n" % (epoch - (200 - i) * 60, i % 100, epoch + 86400,
                                       i % 100, epoch + 600000))
PY
is "planted" "200" "$(wc -l < "$SAMPLES")"
feed "$EPOCH" 64 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
N="$(wc -l < "$SAMPLES")"
# The thirty within the half hour, plus the one just written.
is "pruned to the trailing thirty minutes" "31" "$N"
OLDEST="$(head -1 "$SAMPLES" | cut -d' ' -f1)"
[ "$((EPOCH - OLDEST))" -le 1800 ] \
    && ok "nothing older than the window survives" \
    || bad "nothing older than the window survives" "oldest is $((EPOCH - OLDEST))s old"

# A run of identical readings is kept as its two endpoints, so a flat account does not grow the
# file without bound and does not read as stale either.
rm -f "$SAMPLES"
for i in 0 60 120 180 240; do
    feed "$((EPOCH + i))" 64 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
done
is "a run of identical samples collapses to its endpoints" "2" "$(wc -l < "$SAMPLES")"
is "and the last endpoint is the newest reading" "$((EPOCH + 240))" \
   "$(tail -1 "$SAMPLES" | cut -d' ' -f1)"

# ==========================================================================================
echo
echo "env — what the collector reads, with no hook of its own"
# ==========================================================================================
rm -f "$SAMPLES"
feed "$EPOCH"           60 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))" 62 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 600))" 64 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
E="$(meter env "$((EPOCH + 660))")"
is "the 5-hour percentage is the newest sample's" "64" "$(val SP_LIMIT_5H_PCT <<<"$E")"
is "the 7-day percentage too"                     "41" "$(val SP_LIMIT_7D_PCT <<<"$E")"
is "the age is measured from that sample"         "60" "$(val SP_LIMIT_AGE   <<<"$E")"
# 36 points at 0.4 a minute is 90 minutes, published in seconds.
ETA="$(val SP_LIMIT_5H_ETA <<<"$E")"
[ "$ETA" -ge 5100 ] 2>/dev/null && [ "$ETA" -le 5700 ] 2>/dev/null \
    && ok "the projection is published in seconds" \
    || bad "the projection is published in seconds" "got [$ETA]"
is "a flat window publishes no projection, not zero" "-" "$(val SP_LIMIT_7D_ETA <<<"$E")"

# NO SAMPLE IS `-`, NOT 0. The positive control is the block above: the same keys carried real
# numbers a moment ago, so this is about the file being empty and not about keys that never
# render.
rm -f "$SAMPLES"
E="$(meter env "$EPOCH")"
is "no sample yet reads -"          "-" "$(val SP_LIMIT_5H_PCT <<<"$E")"
is "and its projection reads - too" "-" "$(val SP_LIMIT_5H_ETA <<<"$E")"
is "and the age reads -"            "-" "$(val SP_LIMIT_AGE    <<<"$E")"

# A BROKEN READ IS `?`, WHICH IS A DIFFERENT FACT FROM `-`. A pane that renders a corrupt file
# as "nothing recorded" has turned a fault into calm.
printf 'this is not a sample\n' > "$SAMPLES"
E="$(meter env "$EPOCH")"
is "a corrupt sample file reads ?"      "?" "$(val SP_LIMIT_5H_PCT <<<"$E")"
is "its projection reads ?"             "?" "$(val SP_LIMIT_5H_ETA <<<"$E")"
is "the 7-day window reads ? as well"   "?" "$(val SP_LIMIT_7D_PCT <<<"$E")"
is "and the age reads ?"                "?" "$(val SP_LIMIT_AGE    <<<"$E")"

# A line-mode run repairs it from the hook, which is authoritative — otherwise one bad write
# leaves the collector answering `?` forever with nothing able to clear it.
feed "$EPOCH" 64 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
is "and a live hook repairs it" "64" "$(val SP_LIMIT_5H_PCT <<<"$(meter env "$EPOCH")")"

# `env` MUST NOT READ STDIN. It runs from a collector where stdin is whatever the parent left
# open, and a read on an inherited terminal blocks forever — which presents as a collector that
# simply stopped writing its snapshot.
E="$(blob 99 $((EPOCH + 86400)) 99 $((EPOCH + 600000)) "$TP" | meter env "$EPOCH")"
is "env ignores a blob on stdin and answers from the samples" \
   "64" "$(val SP_LIMIT_5H_PCT <<<"$E")"

# ==========================================================================================
echo
echo "the colours — each window banded by its own value"
# ==========================================================================================
# ASSERTED AGAINST THE ESCAPES, NOT A STRIPPED LINE. Colour is the whole of the signal here: a
# window at 95% and one at 5% read identically once the escapes are gone, so a suite that only
# ever strips them cannot tell a banded line from an unbanded one. Every case below therefore
# uses the raw line, and the green case is the positive control for the two that follow — it
# proves the band moves with the value rather than being one constant colour.
ESC=$'\033'
rm -f "$SAMPLES"
L="$(feed "$EPOCH" 36 $((EPOCH + 86400)) 13 $((EPOCH + 600000)))"
has "under the warn band the window is green" "$L" "${ESC}[32m5h 36%"
rm -f "$SAMPLES"
L="$(feed "$EPOCH" 75 $((EPOCH + 86400)) 13 $((EPOCH + 600000)))"
has "at three quarters it is yellow"          "$L" "${ESC}[33m5h 75%"
rm -f "$SAMPLES"
L="$(feed "$EPOCH" 95 $((EPOCH + 86400)) 13 $((EPOCH + 600000)))"
has "past the high band it is red"            "$L" "${ESC}[31m5h 95%"
has "and the other window keeps its own band" "$L" "${ESC}[32m7d 13%"

# THE WARNING INHERITS RED ONLY WHEN IT IS SOON. An hour is the threshold because that is when
# it changes what to do next; a fill four hours away is information, not an alarm, and rendering
# both the same spends the colour that makes the urgent one legible.
rm -f "$SAMPLES"
feed "$EPOCH"           10 $((EPOCH + 86400)) 13 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 300))" 30 $((EPOCH + 86400)) 13 $((EPOCH + 600000)))"
has "a fill within the hour is red" "$L" "${ESC}[31mfull in ~"
rm -f "$SAMPLES"
feed "$EPOCH"           60 $((EPOCH + 86400)) 13 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))" 62 $((EPOCH + 86400)) 13 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 600))" 64 $((EPOCH + 86400)) 13 $((EPOCH + 600000)))"
has "a fill further off is not"     "$L" "${ESC}[2mfull in ~1h3"

# ==========================================================================================
echo
echo "the EMA weights each interval by its own length"
# ==========================================================================================
# WHY THIS IS NOT THE SAME TEST AS "A CLIMBING WINDOW". Every other projection case here uses
# evenly spaced samples, and on those a fixed weight and a time-weighted one agree — so all of
# them pass with the time constant thrown away. The hook fires every five seconds while a turn
# is running and not at all between turns, so uneven intervals are the normal case, not the
# edge one, and a fixed weight lets the last few seconds of a session pin the average.
#
# Twenty points over five minutes is 4.0 a minute; one point over the next single minute is
# 1.0. With α = 1 − exp(−Δt/τ) and τ=15, that one short minute is worth α=0.064, so it barely
# moves the average: 4.0 − 0.064×3.0 = 3.81 a minute, or 228.4%/h. A fixed α=0.5 would land on
# 2.5 a minute, or 150.0%/h — so the rendered rate names which one is in force.
rm -f "$SAMPLES"
feed "$EPOCH"           10 $((EPOCH + 86400)) 13 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))" 30 $((EPOCH + 86400)) 13 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 360))" 31 $((EPOCH + 86400)) 13 $((EPOCH + 600000)) | strip)"
has   "a brief interval barely moves the average" "$L" "↑228.4%/h"
hasnt "it is not weighted as an equal to the long one" "$L" "↑150.0%/h"

# ==========================================================================================
echo
echo "a malformed window is an absent one, not a zero"
# ==========================================================================================
# rate_limits ITSELF PRESENT, ITS WINDOWS UNREADABLE. The absence case earlier omits the key
# entirely, which the shape check refuses before either window is looked at; this is the other
# door into the same rendering, and it is the one a client reaches by changing a field's type.
# A percentage that is a string, out of range, or a bool must not become a number here.
rawblob() {
    python3 - "$1" "$TP" <<'PY2'
import json, sys
print(json.dumps({"session_id": "s-1", "transcript_path": sys.argv[2], "cwd": "/tmp",
                  "context_window": {"total_input_tokens": 1200, "used_percentage": 1,
                                     "context_window_size": 1000000},
                  "rate_limits": json.loads(sys.argv[1])}))
PY2
}
# The positive control: the same helper, with the windows well formed, does render.
rm -f "$SAMPLES"
L="$(rawblob '{"five_hour":{"used_percentage":44,"resets_at":9999999999},
               "seven_day":{"used_percentage":12,"resets_at":9999999999}}' \
     | meter line "$EPOCH" | strip)"
has "positive control: a well-formed pair renders" "$L" "5h 44%"

for BAD in '{"five_hour":{"used_percentage":"lots","resets_at":9999999999},"seven_day":{}}' \
           '{"five_hour":{"used_percentage":140,"resets_at":9999999999},"seven_day":null}' \
           '{"five_hour":{"used_percentage":true,"resets_at":9999999999},"seven_day":[]}' \
           '{}'; do
    rm -f "$SAMPLES"
    L="$(rawblob "$BAD" | meter line "$EPOCH" | strip)"
    hasnt "no segment for $BAD" "$L" "5h"
    hasnt "and no reassuring zero for it" "$L" "0%"
done
is "and nothing unreadable was ever recorded as a sample" "absent" \
   "$([ -e "$SAMPLES" ] && echo present || echo absent)"

# ==========================================================================================
echo
echo "the line stays readable"
# ==========================================================================================
rm -f "$SAMPLES"
feed "$EPOCH"           60 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
feed "$((EPOCH + 300))" 62 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) >/dev/null
L="$(feed "$((EPOCH + 600))" 64 $((EPOCH + 86400)) 41 $((EPOCH + 600000)) | strip)"
W="$(printf '%s' "$L" | wc -m)"
[ "$W" -le 110 ] && ok "under 110 columns ($W)" || bad "under 110 columns" "$W"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
