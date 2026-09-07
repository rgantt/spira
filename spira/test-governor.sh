#!/usr/bin/env bash
#
# test-governor.sh — the budget is a moving average of measured intervals, and it is headroom.
#
# The governor's own history showed budgets of 0, 1 and 2 within minutes at a constant aeon
# count, because each was one two-second sample. These fixtures drive governor-budget.py, the
# arithmetic governor.sh calls with what it read from /proc, and hold three properties:
#
#   * the reading is the interval average from cumulative counters, not the sample;
#   * one loud or quiet interval moves the average a step, never a cliff;
#   * the answer is how many MORE aeons fit, and the running ones are not subtracted twice.
#
#   ./test-governor.sh
#
# covers: spira/governor.sh spira/governor-budget.py
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GOV="$HERE/governor-budget.py"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }

# gov [K=V ...] -> the output lines; field <name> <output> -> one value
gov()   { env -i PATH="$PATH" CORES=4 "$@" python3 "$GOV"; }
field() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

echo "the reading:"
# Counters: 1000 ticks elapsed, 600 of them idle, so the interval was 60% idle — while the
# two-second sample happened to land on a burst and read 5%.
out="$(gov STAT_TOTAL=11000 STAT_IDLE=5600 PREV_STAT_TOTAL=10000 PREV_STAT_IDLE=5000 \
           PREV_AT=1000 NOW=1120 SAMPLE_IDLE=5)"
is "the interval average is the reading, not the sample" 60 "$(field IDLE "$out")"
is "and it says so"                                       interval "$(field IDLE_SOURCE "$out")"

out="$(gov STAT_TOTAL=11000 STAT_IDLE=5600 SAMPLE_IDLE=41)"
is "no previous counters: the sample stands in"          41 "$(field IDLE "$out")"
is "and that is named too"                               sample "$(field IDLE_SOURCE "$out")"

out="$(gov STAT_TOTAL=500 STAT_IDLE=100 PREV_STAT_TOTAL=10000 PREV_STAT_IDLE=5000 \
           PREV_AT=1000 NOW=1120 SAMPLE_IDLE=41)"
is "counters that went backwards (a reboot) fall back to the sample" sample "$(field IDLE_SOURCE "$out")"

out="$(gov STAT_TOTAL=11000 STAT_IDLE=5600 PREV_STAT_TOTAL=10000 PREV_STAT_IDLE=5000 \
           PREV_AT=1000 NOW=9000 SAMPLE_IDLE=41)"
is "a gap past MAX_INTERVAL is another era: sample"      sample "$(field IDLE_SOURCE "$out")"

echo
echo "the average:"
out="$(gov SAMPLE_IDLE=60)"
is "the first reading seeds the average"                 60.0 "$(field IDLE_AVG "$out")"
out="$(gov SAMPLE_IDLE=0 PREV_AVG=60 ALPHA=0.25)"
is "one dead-busy interval moves it a quarter of the way" 45.0 "$(field IDLE_AVG "$out")"
out="$(gov SAMPLE_IDLE=100 PREV_AVG=20 ALPHA=0.25)"
is "one idle interval likewise"                          40.0 "$(field IDLE_AVG "$out")"

# THE CASE FROM THE HISTORY: a steady ~40% average with readings swinging 21..73 must not
# swing the headroom with them. Four cores, 25 per aeon, floor 25: 40% is 0 more, and one
# reading moves the average a quarter of the swing; the old formula on the same readings
# said 0, 1 and 2. (An average that sits ON a band edge will still step over it on one
# reading — that is the average being honest, not a flap, and a real interval reading is
# real information in a way a two-second sample never was.)
for s in 21 73 29 68; do
    out="$(gov SAMPLE_IDLE=$s PREV_AVG=40 RUNNING=3)"
    is "reading $s% against a 40% average: 0 more, not $(( s>=25 ? (s-25)/25 : 0 ))" 0 "$(field HEADROOM "$out")"
done

echo
echo "headroom, not a total:"
out="$(gov SAMPLE_IDLE=75 PREV_AVG=75 RUNNING=3)"
is "75% idle on 4 cores, floor 25: two more fit"         2 "$(field HEADROOM "$out")"
is "and the total counts the three already running"     5 "$(field BUDGET "$out")"
is "the reason is plain ok"                              ok "$(field REASON "$out")"
out="$(gov SAMPLE_IDLE=45 PREV_AVG=45 RUNNING=3)"
is "45%: none more, three stay"                          3 "$(field BUDGET "$out")"
want "and the reason names the arithmetic"               "no headroom" "$(field REASON "$out")"
out="$(gov SAMPLE_IDLE=45 PREV_AVG=45 RUNNING=0)"
is "the same box with nothing running: still none more"  0 "$(field HEADROOM "$out")"
out="$(gov SAMPLE_IDLE=50 PREV_AVG=50 RUNNING=0 CORES=8)"
is "eight cores: an aeon costs 12 points, so two fit in 25 spare" 2 "$(field HEADROOM "$out")"
is "and the per-aeon cost is reported"                   12 "$(field PER_AEON "$out")"
out="$(gov SAMPLE_IDLE=90 PREV_AVG=90 RUNNING=1 PER_AEON=30)"
is "PER_AEON overrides the per-core default"             2 "$(field HEADROOM "$out")"

echo
echo "every breach says why and withholds everything:"
out="$(gov SAMPLE_IDLE=20 PREV_AVG=20 RUNNING=3)"
is "under the floor: budget 0"                           0 "$(field BUDGET "$out")"
want "and it names the floor"                            "floor 25%" "$(field REASON "$out")"
out="$(gov SAMPLE_IDLE=90 PREV_AVG=90 RUNNING=1 MEM_MB=900)"
is "memory: headroom 0"                                  0 "$(field HEADROOM "$out")"
want "memory: named"                                     "900MB" "$(field REASON "$out")"
out="$(gov SAMPLE_IDLE=90 PREV_AVG=90 DISK_ROOT=95)"
want "root disk: named"                                  "/ at 95%" "$(field REASON "$out")"
out="$(gov SAMPLE_IDLE=90 PREV_AVG=90 DISK_WS=93 WS_PATH=/ws)"
want "workspace disk: named with its path"               "/ws at 93%" "$(field REASON "$out")"
out="$(gov SAMPLE_IDLE=90 PREV_AVG=90 CI_BUSY=1)"
want "a busy CI runner: named"                           "CI runner" "$(field REASON "$out")"
out="$(gov)"
is "no reading at all: one aeon, no more"                1 "$(field HEADROOM "$out")"
want "and the probe is named blind"                      "unreadable" "$(field REASON "$out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
