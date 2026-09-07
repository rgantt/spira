#!/usr/bin/env bash
#
# world.sh — stop and start Spira as a whole.
#
#   world.sh stop [--why "..."]   halt the loop: no summons, no landing, no live aeons
#   world.sh start                bring it back
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

# The loop, in the order that stops cleanly: summons first so nothing new is born, then the
# legs that act on what is already there.
TIMERS=(spira-sentinel.timer spira-ops.timer spira-gate-full.timer
        spira-archivist.timer spira-archive.timer spira-skew.timer)
STAMP="$SPIRA_RUN/world.halted"

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
        printf '%s %s\n' "$pid" "$(systemctl --user status "$pid" 2>/dev/null | head -1 | awk '{print $2}')"
    done
}

case "${1:-status}" in
stop)
    shift; why=""
    [ "${1:-}" = "--why" ] && { why="${2:-}"; shift 2; }
    hard=0; [ "${1:-}" = "--hard" ] && hard=1

    echo "spira: halting the loop"
    for t in "${TIMERS[@]}"; do
        systemctl --user stop "$t" 2>/dev/null && printf '  stopped %s\n' "$t"
    done
    [ "$hard" = 1 ] && for u in $(systemctl --user list-units 'spira-watch@*' --no-legend 2>/dev/null | awk '{print $1}'); do
        systemctl --user stop "$u" 2>/dev/null && printf '  stopped %s\n' "$u"
    done

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
    # A COUNT THAT DISAGREES WITH THE PROCESS TABLE IS THE BUG, NOT THE ANSWER. Anything
    # still running that no pidfile claims is reported rather than passed over in silence.
    stray="$(live_aeons | grep -c . || true)"
    [ "$n" = 0 ] && [ "$stray" = 0 ] && echo "  no live aeons"
    [ "$stray" != 0 ] && printf '  WARNING: %s aeon process(es) still running that no pidfile names — inspect /proc before killing\n' "$stray"

    mkdir -p "$SPIRA_RUN"
    { date -u '+%Y-%m-%dT%H:%M:%SZ'; printf 'why: %s\n' "${why:-unstated}"; } > "$STAMP"
    echo "spira: STOPPED. Dolt and the cockpit are untouched. Restart with: world.sh start"
    ;;

start)
    echo "spira: starting the loop"
    for t in "${TIMERS[@]}"; do
        systemctl --user start "$t" 2>/dev/null && printf '  started %s\n' "$t"
    done
    rm -f "$STAMP"
    echo "spira: RUNNING"
    ;;

status)
    if [ -f "$STAMP" ]; then printf 'spira: HALTED since %s\n' "$(head -1 "$STAMP")"; sed -n 2p "$STAMP"
    else echo "spira: not halted by world.sh"; fi
    for t in "${TIMERS[@]}"; do
        printf '  %-26s %s\n' "$t" "$(systemctl --user is-active "$t" 2>/dev/null)"
    done
    printf '  %-26s %s\n' "dolt-beads.service" "$(systemctl --user is-active dolt-beads.service 2>/dev/null)"
    printf '  %-26s %s\n' "dolt-beads-test.service" "$(systemctl --user is-active dolt-beads-test.service 2>/dev/null)"
    a="$(live_aeons | grep -c . || true)"; printf '  live aeons: %s\n' "$a"
    ;;
*)  echo "usage: world.sh {stop [--why \"...\"] [--hard] | start | status}" >&2; exit 64 ;;
esac
