#!/usr/bin/env bash
#
# governor.sh — how much of this machine Spira may use, and what it got for it.
#
#   governor.sh            write the budget, print one line
#   governor.sh --report   the human view: headroom, throughput, what is throttling
#
# WHY A SEPARATE ENTITY (the operator's call)
# -------------------------------------------
# "another entity keeping track of throughput to make sure we're within the resource
# constraints of this machine."
#
# The box this runs on may not be a build farm. It may also be running production services,
# two GitHub Actions runners, the whole of Gas Town, and the operator's own session. An aeon is an
# Opus session plus a cargo build plus a test suite, and nothing in the harness previously
# asked whether the machine could afford one — FAYTH_MAX_CONCURRENT is a COUNT, which is a
# proxy for load and not a measure of it.
#
# The budget is a deterministic function of what /proc says right now. That is the cheap
# tier: no inference, no history, a handful of file reads. It never GROWS a fayth's own
# cap; it only withholds, so a fayth's concurrency stays the ceiling and this is the floor.
#
# IT MUST FAIL CLOSED-ISH, NOT OPEN. An unreadable probe yields the fayth's configured cap
# rather than infinity, and says so — but a probe that reads FINE and reports pressure
# must actually throttle. A governor that cannot be seen throttling has never been tested.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

BUDGET="$SPIRA_RUN/budget.env"
HIST="$SPIRA_RUN/governor.tsv"
# MEASURE FIRST, ENFORCE LATER (the operator, verbatim: "put the governor in 'measure' mode
# rather than 'enforce' mode until we know what load actually looks like with Spira and no
# Gastown"). Two metrics disagreed violently on the same instant — load average said 0
# aeons, measured CPU idle said 2 at 65% idle — and a throttle built on a number nobody
# trusts yet is a throttle that will be wrong in a direction nobody notices. In `measure`
# the budget is computed, recorded and logged, and clamps nothing. Flip to `enforce` when
# the history says what the ceiling should be, which is knowable only once Gas Town is
# gone and Spira is the load.
MODE="${SPIRA_GOVERNOR_MODE:-measure}"
# Fractions of one core's worth of load per aeon. An aeon is mostly waiting on the API,
# but its gate runs nine suites and its build runs cargo, so it is not free.
LOAD_PER_AEON="${SPIRA_LOAD_PER_AEON:-1.5}"
# Above this fraction of cores in 1-minute load, summon nothing at all.
LOAD_CEILING="${SPIRA_LOAD_CEILING:-0.85}"
MIN_FREE_MB="${SPIRA_MIN_FREE_MB:-1500}"
MIN_DISK_PCT="${SPIRA_MIN_DISK_PCT:-10}"

cores=$(nproc 2>/dev/null || echo 1)
load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")

# MEASURE THE PROPERTY, NOT A PROXY. Load average counts uninterruptible I/O waiters, so a
# dolt-heavy box can show load 12 while CPU sits idle — and the question here is only ever
# "is there CPU to spare". Sample /proc/stat instead and keep load as a reported number.
# (Checked: load 12.17 with 16% idle and zero D-state tasks, so the two agreed
# that time — but they agree by luck, and the next reading is what this has to be right about.)
cpu_idle=$(
  read -r _ a b c i _ < /proc/stat; t1=$((a+b+c+i)); i1=$i
  sleep 2
  read -r _ a b c i _ < /proc/stat; t2=$((a+b+c+i)); i2=$i
  [ "$((t2-t1))" -gt 0 ] && echo $(( (i2-i1)*100 / (t2-t1) )) || echo "?"
) 2>/dev/null || cpu_idle="?"
# Percent of total CPU that must stay free. An aeon is mostly waiting on the API, but its
# gate runs ten suites and its build runs cargo, so it is not free either.
IDLE_FLOOR="${SPIRA_IDLE_FLOOR:-25}"
memfree=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
diskroot=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9' || echo "?")
diskws=$(df --output=pcent "$SPIRA_WORKSPACES" 2>/dev/null | tail -1 | tr -dc '0-9' || echo "?")

# The CI runners are the other heavy tenant and they serve a human waiting on a PR.
# Yield to them: an aeon can wait, a red build cannot.
# ACTIVE IS NOT BUSY, AND NEITHER IS "HAS A CHILD". The first version asked whether the
# runner's MainPID had any child — but an IDLE runner always has a run-helper.sh child, so
# this read busy forever, pinned the budget at 0, and would have starved the harness while
# every probe looked healthy. A governor that always says no is as broken as one that
# always says yes. Runner.Worker is the process that exists only while a job is running;
# argv from /proc decides, because pgrep may nominate.
ci_busy=0
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    case "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" in
        *Runner.Worker*) ci_busy=1; break ;;
    esac
done

reason=ok
budget=99
if [ "$load1" = "?" ] || [ "$memfree" = "?" ]; then
    budget=1; reason="probe-unreadable"
else
    # CPU idle is the gate. One aeon per IDLE_FLOOR points of idle above the floor.
    if [ "$cpu_idle" = "?" ]; then
        budget=1; reason="cpu probe unreadable"
    else
        budget=$(( (cpu_idle - IDLE_FLOOR) / IDLE_FLOOR + 1 ))
        [ "$budget" -lt 0 ] && budget=0
        [ "$cpu_idle" -lt "$IDLE_FLOOR" ] && { budget=0; reason="cpu ${cpu_idle}% idle, floor ${IDLE_FLOOR}%"; }
    fi
    [ "${memfree:-0}" -lt "$MIN_FREE_MB" ] && { budget=0; reason="only ${memfree}MB available"; }
    [ "${diskroot:-0}" -gt $((100-MIN_DISK_PCT)) ] && { budget=0; reason="/ at ${diskroot}%"; }
    [ "${diskws:-0}"   -gt $((100-MIN_DISK_PCT)) ] && { budget=0; reason="$SPIRA_WORKSPACES at ${diskws}%"; }
    [ "$ci_busy" = 1 ] && [ "$budget" -gt 0 ] && { budget=0; reason="a CI runner is busy"; }
fi

# ---- throughput: what the spend bought -----------------------------------------------
# ACROSS EVERY REPOSITORY. This is the "what did the spend buy" side of the budget, and an
# aeon's commits land wherever its bead named — counting one repository would read a busy
# harness as an idle one and hand it capacity it was already using.
landed_24h=0; landed_1h=0
for _r in $(spira_repos); do
    _p="$(repo_root "$_r")" || continue
    [ -e "$_p/.git" ] || continue
    landed_24h=$(( landed_24h + $(git -C "$_p" log --since=24.hours --format='%an' 2>/dev/null | grep -c '^aeon-' || true) ))
    landed_1h=$((  landed_1h  + $(git -C "$_p" log --since=1.hour  --format='%an' 2>/dev/null | grep -c '^aeon-' || true) ))
done
aeon_min=$(systemctl --user list-units 'spira-aeon-*' --all --no-legend 2>/dev/null | wc -l)

cat > "$BUDGET" <<EOF
SP_BUDGET='$budget'
SP_GOVERNOR_MODE='$MODE'
SP_BUDGET_REASON='$reason'
SP_CORES='$cores'
SP_LOAD1='$load1'
SP_CPU_IDLE='$cpu_idle'
SP_MEM_AVAIL_MB='$memfree'
SP_DISK_ROOT_PCT='$diskroot'
SP_DISK_WS_PCT='$diskws'
SP_CI_BUSY='$ci_busy'
SP_LANDED_1H='$landed_1h'
SP_LANDED_24H='$landed_24h'
SP_AEON_UNITS='$aeon_min'
SP_BUDGET_AT='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
EOF

# One row per pass. This is the evidence that decides the eventual ceiling; without it
# "what does load look like" is a memory of a few glances at a terminal.
[ -s "$HIST" ] || printf 'ts\tmode\tbudget\treason\tcpu_idle\tload1\tcores\tmem_mb\tci\tlanded_1h\n' > "$HIST"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$budget" "$reason" "$cpu_idle" "$load1" \
    "$cores" "$memfree" "$ci_busy" "$landed_1h" >> "$HIST"

if [ "${1:-}" = "--report" ]; then
    printf 'governor [%s]: budget %s aeon(s) — %s\n' "$MODE" "$budget" "$reason"
    printf '  cpu %s%% idle (floor %s%%) · load %s of %s cores · %sMB free · / %s%% · %s %s%% · CI busy: %s\n' \
        "$cpu_idle" "$IDLE_FLOOR" "$load1" "$cores" "$memfree" "$diskroot" "$diskws" "$ci_busy"
    printf '  landed by aeons: %s in the last hour, %s in 24h\n' "$landed_1h" "$landed_24h"
else
    printf 'governor: budget=%s (%s) load=%s/%s mem=%sMB landed24h=%s\n' \
        "$budget" "$reason" "$load1" "$cores" "$memfree" "$landed_24h"
fi
