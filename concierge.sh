#!/usr/bin/env bash
#
# concierge.sh — the single Remote Control session the operator talks to from their phone.
#
#   concierge.sh start     launch it in tmux (idempotent)
#   concierge.sh attach    attach locally
#   concierge.sh status    is it up
#   concierge.sh stop      kill it
#
# WHY ONE SESSION AND NOT SEVERAL
# -------------------------------
# The pattern is Yegge's Seneschal: "The mobile Claude app lets you see your
# /remote-control sessions, and I designated the Seneschal as my single remote control
# session. I talk to the Seneschal on the phone, who in turn talks to everyone else."
#
# One concierge, not a repo-by-repo list, because the phone is a narrow surface and the
# useful thing to reach from it is the session holding cross-repo context — the wiki,
# CLAUDE.md and the statute book. It reaches Spira through beads; it does not become a
# second control plane.
#
# WHY tmux AND NOT systemd
# ------------------------
# Remote Control needs an interactive session with a TTY. Every aeon on this box already
# runs this way, and tmux means the operator can attach to the same session locally and see
# exactly what the phone sees.
#
# WHY IT RUNS FROM THE HOME CHECKOUT
# ----------------------------------
# The cwd decides which CLAUDE.md, which hooks and which project memory it loads. From
# there it gets the operator's own conventions, their session-start list, their guards,
# and the same statutes every aeon reads.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/spira" && pwd -P)/conf.sh"
SESSION="${CONCIERGE_SESSION:-concierge}"
SOCKET="${CONCIERGE_SOCKET:-concierge}"
BRAIN="$SPIRA_REPO"
spira_require claude tmux || exit 1

TM="tmux -L $SOCKET"

case "${1:-status}" in

start)
    if $TM has-session -t "$SESSION" 2>/dev/null; then
        echo "concierge: already running (tmux -L $SOCKET attach -t $SESSION)"
        exit 0
    fi
    command -v claude >/dev/null || { echo "concierge: claude not on PATH" >&2; exit 1; }
    # THE SERVER BELOW INHERITS THIS PROCESS'S ENVIRONMENT AND KEEPS IT FOR LIFE. Started from
    # inside another Claude session — which is exactly how it gets started — it would hand that
    # session's identity to the concierge, and a client that thinks it is a child session does
    # not write a transcript. Clear them before the fork; scrub an existing server for the case
    # where this socket is already up. See cockpit/tmux-env.sh.
    _tmuxenv="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/cockpit/tmux-env.sh"
    bash "$_tmuxenv" scrub -L "$SOCKET" 2>/dev/null
    unset $(bash "$_tmuxenv" names) 2>/dev/null || true
    $TM new-session -d -s "$SESSION" -c "$BRAIN" \
        "claude --remote-control '$SESSION' --dangerously-skip-permissions"
    sleep 3
    if $TM has-session -t "$SESSION" 2>/dev/null; then
        echo "concierge: started as Remote Control session '$SESSION'"
        echo "  attach locally:  tmux -L $SOCKET attach -t $SESSION"
        echo "  on the phone:    Claude app -> Remote Control -> $SESSION"
    else
        echo "concierge: failed to stay up — run it in the foreground to see why:" >&2
        echo "  cd $BRAIN && claude --remote-control $SESSION" >&2
        exit 1
    fi
    ;;

attach)  exec $TM attach -t "$SESSION" ;;

status)
    if $TM has-session -t "$SESSION" 2>/dev/null; then
        echo "concierge: running"
        $TM list-panes -t "$SESSION" -F '  pane #{pane_id} pid=#{pane_pid} #{pane_current_command}'
        echo "  last 15 lines:"
        $TM capture-pane -p -t "$SESSION" 2>/dev/null | grep -v '^$' | tail -15 | sed 's/^/    /'
    else
        echo "concierge: not running  (start with: $0 start)"
        exit 1
    fi
    ;;

stop)    $TM kill-session -t "$SESSION" 2>/dev/null && echo "concierge: stopped" ;;

*)       sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
