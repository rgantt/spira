#!/usr/bin/env bash
#
# world.sh — stop and start Spira as a whole.
#
#   world.sh stop [--why "..."]   halt the loop: no summons, no landing, no live aeons
#   world.sh start                bring it back
#   world.sh drain [--timeout N]  no NEW aeons; loop and landing keep running until the pool empties
#   world.sh resume               lift a drain
#   world.sh status               what is up, what is down, what is running
#
# WHY THIS EXISTS. Stopping Spira meant remembering six unit names and then hunting aeon
# processes by hand, so in practice nobody stopped it — they stopped ONE timer and left the
# rest running, or killed a runner and left its model session headless. A control that is a
# checklist is a control nobody uses in the moment they need it (2026-09-07: the loop spent
# two days re-summoning aeons onto a bead that could not finish, and halting it took a
# session of archaeology).
#
# WHAT IT DOES NOT TOUCH, deliberately:
#   dolt-beads*.service   the databases. Stopping the world must never risk the data, and a
#                         stopped server makes every diagnostic you are about to run fail.
#   cockpit*, concierge   the panes the operator is reading. Halting the loop must not also
#                         blind the person halting it.
# `stop --hard` adds the watchers; nothing here ever stops Dolt.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"

# systemctl behind a seam so test suites can stub it without reaching the box.
# The same seam sentinel.sh carries, named the same way so one variable stubs both.
SC="${SPIRA_SYSTEMCTL:-systemctl}"

# The loop, in the order that stops cleanly: summons first so nothing new is born, then the
# legs that act on what is already there.
#
# TIMER NAMES ARE INSTANCE-QUALIFIED after install.sh's per-instance migration (sp-trn1).
# Each base is tried in instance-qualified form first (spira-<base>-<instance>.timer); if
# neither is-enabled nor is-active confirms it exists, the plain name is used as a fallback.
# This makes world.sh correct before a migration and after. c0e2f8c applied the same shape
# to cockpit.sh and health.sh when the rename broke them identically (sp-4biz, 2026-09-08).
TIMER_BASES=(spira-sentinel spira-ops spira-watchtower spira-archivist spira-archive spira-skew)
TIMERS=()
for _b in "${TIMER_BASES[@]}"; do
    _inst="${_b}${SPIRA_INSTANCE:+-$SPIRA_INSTANCE}.timer"
    if "$SC" --user is-enabled "$_inst" >/dev/null 2>&1 ||
       "$SC" --user is-active  "$_inst" >/dev/null 2>&1; then
        TIMERS+=("$_inst")
    else
        TIMERS+=("${_b}.timer")
    fi
done
unset _b _inst
STAMP="$SPIRA_RUN/world.halted"
DRAIN_STAMP="$SPIRA_RUN/world.draining"

# live_aeons -> "<pid> <unit>" per running aeon, resolved from /proc argv.
# NEVER pgrep -f: the pattern is a substring of this script's own command line.
live_aeons() {
    local p c pid
    for p in /proc/[0-9]*; do
        # -r first: a pid can exit between the glob and the read, and the shell reports the
        # redirection failure before `tr`'s own 2>/dev/null can suppress it.
        [ -r "$p/cmdline" ] || continue
        c="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" || continue
        case "$c" in *"$SPIRA_HOME/aeon.sh"*) ;; *) continue ;; esac
        pid="${p#/proc/}"
        printf '%s %s\n' "$pid" "$("$SC" --user status "$pid" 2>/dev/null | head -1 | awk '{print $2}')"
    done
}

# work_services -> one service unit name per line, for the active spira-*.service units that
# execute work. Enumerated from what systemd reports rather than from a hand-written list, so
# a new work unit cannot silently escape a halt.
#
# EXCLUDED DELIBERATELY:
#   spira-cockpit.service   the pane the operator is reading
#   spira-watch@*.service   handled separately by --hard
# Dolt is never named spira-*; the exclusions above are the only ones needed.
work_services() {
    "$SC" --user list-units 'spira-*.service' --state=active --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -Ev '^spira-cockpit\.service$|^spira-watch@'
}

# live_workers -> one pid per line for any process running gate.sh or landing.sh from this
# home. These are the processes that survive a stop of spira-landing.service if it was killed
# before they finished — the evidence that the halt was incomplete.
# NEVER pgrep -f: the pattern is a substring of this script's own command line.
live_workers() {
    local p c
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        c="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" || continue
        case "$c" in
            *"$SPIRA_HOME/gate.sh"*|*"$SPIRA_HOME/landing.sh"*)
                printf '%s\n' "${p#/proc/}" ;;
        esac
    done
}

case "${1:-status}" in
stop)
    shift; why=""
    [ "${1:-}" = "--why" ] && { why="${2:-}"; shift 2; }
    hard=0; [ "${1:-}" = "--hard" ] && hard=1

    echo "spira: halting the loop"
    for t in "${TIMERS[@]}"; do
        "$SC" --user stop "$t" 2>/dev/null && printf '  stopped %s\n' "$t"
    done
    # WATCHER UNITS ARE INSTANCE-QUALIFIED after the per-instance migration. The template
    # form (spira-watch@<name>.service) was renamed to spira-watch-<name>-<instance>.service;
    # list-units 'spira-watch@*' finds nothing after that rename. Both forms are queried so
    # --hard works during a migration and after (sp-4biz, 2026-09-08).
    if [ "$hard" = 1 ]; then
        for u in $(
            {
                "$SC" --user list-units 'spira-watch@*' --no-legend 2>/dev/null
                "$SC" --user list-units \
                      "spira-watch-*${SPIRA_INSTANCE:+-$SPIRA_INSTANCE}.service" \
                      --state=active --no-legend 2>/dev/null
            } | awk '{print $1}'
        ); do
            "$SC" --user stop "$u" 2>/dev/null && printf '  stopped %s\n' "$u"
        done
    fi

    # WORK SERVICES execute work the timers do not — spira-landing is the critical one, because
    # it runs the same gate.sh passes an aeon does and survives a timer stop. Discovered from
    # what systemd reports rather than from a hand-written list (work_services above), so a new
    # unit cannot silently escape.
    svc_failed=0
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        if "$SC" --user stop "$svc" 2>/dev/null; then
            printf '  stopped %s\n' "$svc"
        else
            printf '  WARNING: could not stop %s — still running\n' "$svc" >&2
            svc_failed=1
        fi
    done < <(work_services)

    # AEONS ARE STOPPED THROUGH slay.sh, not killed. It writes the marker that makes the
    # aeon's own exit path release its bead with NO ATTEMPT CHARGED — a bare kill leaves the
    # bead held until the lease expires and charges the attempt anyway, which is how a halt
    # for an unrelated reason walks a bead toward poison.
    n=0
    # FROM THE PIDFILE, NOT THE ENVIRONMENT. BEAD_ID is a shell variable in aeon.sh and was
    # never exported, so reading /proc/<pid>/environ for it returns empty for every live aeon
    # — and a loop that only counts what it found then reported "no live aeons" while four
    # were running. The pidfile is named aeon-<fayth>-<bead>.pid and is the harness's own
    # record of the pairing.
    for pf in "$SPIRA_RUN"/aeon-*.pid; do
        [ -e "$pf" ] || continue
        pid="$(cat "$pf" 2>/dev/null)"
        [ -n "$pid" ] && [ -d "/proc/$pid" ] || { rm -f "$pf"; continue; }
        bead="$(basename "$pf" .pid)"; bead="${bead#aeon-}"; bead="${bead#*-}"
        if [ -n "$bead" ]; then
            printf '  slaying %s (pid %s)\n' "$bead" "$pid"
            "$SPIRA_HOME/slay.sh" "$bead" --keep-work --why "${why:-the world was stopped}" >/dev/null 2>&1 \
                || printf '    slay.sh could not stop %s — left running, say so rather than pretend\n' "$bead"
            n=$((n+1))
        fi
    done
    # RE-READ PIDFILES now — after the timers are stopped — to resolve each surviving process
    # to a bead. An aeon spawned between the timer stop and the first scan may have written
    # its pidfile by this point; it is not an orphan, it is a late starter the first pass
    # missed. A warning that fires on a routine race is one nobody reads on the day it is real.
    stray=0
    while IFS=' ' read -r apid aunit; do
        bead_for_pid=""
        for pf in "$SPIRA_RUN"/aeon-*.pid; do
            [ -e "$pf" ] || continue
            pp="$(cat "$pf" 2>/dev/null)" || continue
            if [ "$pp" = "$apid" ]; then
                bb="$(basename "$pf" .pid)"; bb="${bb#aeon-}"; bb="${bb#*-}"
                bead_for_pid="$bb"
                break
            fi
        done
        if [ -n "$bead_for_pid" ]; then
            printf '  WARNING: %s (pid %s) — named by a pidfile but slay did not stop it; run: slay.sh %s\n' \
                "$bead_for_pid" "$apid" "$bead_for_pid"
        else
            printf '  WARNING: pid %s (%s) — no pidfile names it; could not resolve to a bead — inspect /proc/%s/cmdline before killing\n' \
                "$apid" "${aunit:--}" "$apid"
        fi
        stray=$((stray+1))
    done < <(live_aeons)
    [ "$n" = 0 ] && [ "$stray" = 0 ] && echo "  no live aeons"

    mkdir -p "$SPIRA_RUN"
    { date -u '+%Y-%m-%dT%H:%M:%SZ'; printf 'why: %s\n' "${why:-unstated}"; } > "$STAMP"

    # A HALT THAT CANNOT STOP SOMETHING SAYS SO AND EXITS NON-ZERO. Printing STOPPED while a
    # worker is still running was the bug that made this bead necessary: the operator halted,
    # saw the success message, and three gate.sh processes on spira-landing.service went on
    # saturating the tree lock the halt was meant to clear.
    if [ "$svc_failed" = 1 ]; then
        printf 'spira: stop INCOMPLETE — work service(s) could not be stopped (see warnings above)\n' >&2
        exit 1
    fi
    echo "spira: STOPPED. Dolt and the cockpit are untouched. Restart with: world.sh start"
    ;;

start)
    echo "spira: starting the loop"
    for t in "${TIMERS[@]}"; do
        "$SC" --user start "$t" 2>/dev/null && printf '  started %s\n' "$t"
    done
    rm -f "$STAMP"
    echo "spira: RUNNING"
    ;;

# DRAIN IS NOT A SOFTER STOP — IT IS A DIFFERENT SHAPE. `stop` halts the timers, the work
# services and the live aeons, because it exists to make everything quiet. `drain` closes the
# door and lets the room empty: no NEW aeon is summoned, while the loop, landing and reaping
# all keep running so an aeon already working can finish and LAND what it built.
#
# NOTHING IS STOPPED, so there is no channel to forget to restart (law-arm-before-you-retire).
# The gate is a stamp file that summon_fayth() checks in lib.sh — one place, covering every
# caller. The first attempt at this stopped spira-sentinel.timer instead, which also stopped
# landing, because landing is a leg of the sentinel pass rather than a timer of its own:
# three finished branches sat unlanded for sixteen minutes (2026-09-08).
drain)
    shift; dtimeout=1800
    [ "${1:-}" = "--timeout" ] && { dtimeout="${2:-1800}"; shift 2; }

    { date '+%Y-%m-%d %H:%M:%S %Z'
      printf 'summons gated in summon_fayth; loop and landing still running. Lift with: %s resume\n' "$0"
    } > "$DRAIN_STAMP"
    echo "spira: draining — no new aeons; loop, landing and reaping continue"

    waited=0
    while :; do
        n="$(live_aeons | grep -c . || true)"
        [ "$n" -eq 0 ] && break
        if [ "$waited" -ge "$dtimeout" ]; then
            printf 'spira: NOT DRAINED — %s aeon(s) still live after %ss\n' "$n" "$dtimeout" >&2
            printf 'spira: summons REMAIN GATED. Lift with: %s resume\n' "$0" >&2
            exit 1
        fi
        [ $(( waited % 60 )) -eq 0 ] && [ "$waited" -gt 0 ] && \
            printf '  %s aeon(s) still working (%ss elapsed)\n' "$n" "$waited"
        sleep 10; waited=$(( waited + 10 ))
    done

    echo "spira: DRAINED — no aeon running, summons gated"
    printf 'spira: resume with: %s resume\n' "$0"
    ;;

resume)
    if [ -f "$DRAIN_STAMP" ]; then
        rm -f "$DRAIN_STAMP"; echo "spira: summons resumed"
    else
        echo "spira: was not draining — nothing to resume"
    fi
    ;;

status)
    # A GATED SUMMON MUST NEVER BE INVISIBLE: a pool held at zero on purpose and a queue with
    # nothing in it look identical from every other surface.
    [ -f "$DRAIN_STAMP" ] && { printf 'spira: DRAINING since %s — summons gated\n' "$(head -1 "$DRAIN_STAMP")"; sed -n 2p "$DRAIN_STAMP"; }
    if [ -f "$STAMP" ]; then printf 'spira: HALTED since %s\n' "$(head -1 "$STAMP")"; sed -n 2p "$STAMP"
    else echo "spira: not halted by world.sh"; fi
    for t in "${TIMERS[@]}"; do
        printf '  %-26s %s\n' "$t" "$("$SC" --user is-active "$t" 2>/dev/null)"
    done
    printf '  %-26s %s\n' "dolt-beads.service" "$("$SC" --user is-active dolt-beads.service 2>/dev/null)"
    printf '  %-26s %s\n' "dolt-beads-test.service" "$("$SC" --user is-active dolt-beads-test.service 2>/dev/null)"

    # WORK SERVICES: spira-landing is always checked because it is a transient unit — it only
    # exists while it is running and does not appear in list-unit-files, so `is-active` is the
    # only reliable probe. Any other active spira-*.service (excluding cockpit and watch@) is
    # also reported, so a new work unit cannot hide here while appearing as HALTED above.
    printf '  %-26s %s\n' "spira-landing.service" "$("$SC" --user is-active spira-landing.service 2>/dev/null || echo inactive)"
    while IFS= read -r svc; do
        case "$svc" in spira-landing.service|spira-cockpit.service) continue ;; esac
        printf '  %-26s %s\n' "$svc" "$("$SC" --user is-active "$svc" 2>/dev/null)"
    done < <("$SC" --user list-units 'spira-*.service' --state=active --no-legend 2>/dev/null | awk '{print $1}' | grep -Ev '^spira-watch@')

    # /proc SCAN: gate.sh and landing.sh processes survive a service stop if the service was
    # killed before they finished. Status reports the count so a running worker cannot hide
    # behind a HALTED header and 0 live aeons.
    wcount="$(live_workers | grep -c . || true)"
    printf '  %-26s %s\n' "live workers (/proc)" "$wcount"

    a="$(live_aeons | grep -c . || true)"; printf '  live aeons: %s\n' "$a"
    ;;
*)  echo "usage: world.sh {stop [--why \"...\"] [--hard] | drain [--timeout SECS] | resume | start | status}" >&2; exit 64 ;;
esac
