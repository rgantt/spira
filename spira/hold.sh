#!/usr/bin/env bash
#
# hold.sh — claim a bead for a non-aeon actor and keep it held.
#
#   hold.sh <bead-id>              claim and hold with this shell's pid
#   hold.sh <bead-id> --pid <P>    hold with pid P instead of $$
#   hold.sh <bead-id> --release    release a held bead (equivalent to release.sh)
#
# WHY THIS EXISTS. The reaper checks holder_alive, which looks for a pidfile named
# aeon-<fayth>-<id>.pid with a process whose argv contains aeon.sh. A non-aeon session
# (brain, concierge, a hand-run tool) passes neither test: no pidfile exists and no argv
# matches, so strand.sh reclaims the bead within seconds of the next pass. On 2026-09-07
# this cost sp-7pi eight attempts, none of which was a fact about the work.
#
# hold.sh writes hold-<id>.pid, which holder_alive checks by pid only (no argv test),
# and starts a background heartbeat that keeps the lease alive. release.sh (or --release)
# tears both down. A dead holder's pid vanishes from /proc and the bead is freed on the
# next sweep — the same liveness contract as an aeon, without requiring aeon.sh in argv.
#
# DO NOT USE THIS TO BYPASS THE LOOP. This is for work the operator ordered done by hand
# — a landing that the loop cannot perform, a fix applied at the keyboard. If the loop
# can do it, let the loop do it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

ID=""; HOLD_PID=$$; MODE=hold
while [ $# -gt 0 ]; do
    case "$1" in
        --pid)     HOLD_PID="${2:?--pid needs a pid}"; shift ;;
        --release) MODE=release ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        -*)        echo "hold.sh: unknown flag $1" >&2; exit 2 ;;
        *)         ID="$1" ;;
    esac
    shift
done
[ -n "$ID" ] || { echo "usage: hold.sh <bead-id> [--pid <P>] [--release]" >&2; exit 2; }

PIDFILE="$SPIRA_RUN/hold-$ID.pid"
HBFILE="${PIDFILE%.pid}.hb"

if [ "$MODE" = release ]; then
    exec "$HERE/release.sh" "$ID"
fi

# Refuse if an aeon already holds it — the hold is for NON-aeon work.
for apf in "$SPIRA_RUN"/aeon-*-"$ID".pid; do
    [ -e "$apf" ] || continue
    if aeon_alive "$apf"; then
        echo "hold.sh: $ID is held by a live aeon — slay it first or let it finish" >&2
        exit 1
    fi
done

# Refuse if already held by another hold.
if [ -f "$PIDFILE" ]; then
    existing="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "$existing" ] && [ -d "/proc/$existing" ]; then
        echo "hold.sh: $ID is already held (pid $existing)" >&2
        exit 1
    fi
    rm -f "$PIDFILE" "$HBFILE"
fi

# Claim the bead in the database.
bdq update "$ID" --claim >/dev/null 2>&1 \
    || { echo "hold.sh: could not claim $ID — is it open and unassigned?" >&2; exit 1; }

# Write the pidfile.
echo "$HOLD_PID" > "$PIDFILE"

# Start a background heartbeat so the lease does not expire under sentinel CHECK 2.
# Simpler than an aeon's: no stall detection, because the holder is a human at the
# keyboard. Beats every 120s (matching aeon.sh's default). Exits when the pidfile is
# removed (release.sh) or the holder pid dies.
#
# Redirected to /dev/null: the heartbeat inherits this script's file descriptors, and a
# $() substitution around the caller waits until EVERY writer on the pipe closes — so
# without this redirect, `out="$(hold.sh ...)"` blocks until the heartbeat exits.
(
    while sleep "${SPIRA_HOLD_HEARTBEAT:-120}"; do
        [ -f "$PIDFILE" ] || exit 0
        [ -d "/proc/$HOLD_PID" ] || exit 0
        bdq heartbeat "$ID" >/dev/null 2>&1 || exit 0
    done
) </dev/null >/dev/null 2>&1 &
echo $! > "$HBFILE"

printf 'held %s (pid %s, heartbeat %s)\n' "$ID" "$HOLD_PID" "$(cat "$HBFILE")"
