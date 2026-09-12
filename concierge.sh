#!/usr/bin/env bash
#
# concierge.sh — the single Remote Control session the operator talks to from their phone.
#
#   concierge.sh start     launch it in tmux (idempotent)
#   concierge.sh attach    attach locally
#   concierge.sh brief     render the system prompt and print its path; change nothing
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
# there it gets the operator's own conventions, their session-start list and their guards.
#
# WHY IT IS COMPOSED FROM A FAYTH
# -------------------------------
# It was not, and that was the defect. An aeon is summoned with a brief, a statute book and a
# model resolved from a file somebody maintains; this session got a working directory and the
# `claude` binary. The operator, 2026-09-12: "when we spin up aeons, they come with a system
# prompt and a set of overlays. you don't. i think that's the defect here."
#
# It was not a difference of degree. `render_memories` — the function that renders the `law-`
# memories in full — is called from `aeon.sh` and from nowhere else, so brain's CLAUDE.md,
# which says the harness "injects a `# Memories in force` section into every agent session at
# summon", described aeons only. The statute that the harness checkout is production had been
# in force for weeks and had never been delivered to the session that kept violating it.
#
# So `chamber/concierge.fayth` and `chamber/concierge.md` now define this session exactly as
# `builder.fayth` defines a Guardian, and what follows renders them. The one property that
# makes the concierge different is declared in the fayth rather than arranged: FAYTH_SUMMON is
# `operator`, and `spira_task_fayths` / `spira_lane_fayths` both refuse to hand it to the
# sentinel. Nothing but a human starts this.
set -uo pipefail

# lib.sh AND NOT conf.sh ALONE. conf.sh resolves configuration; the helpers this file needs —
# `fayth_get` to read the persona and `render_memories` to render the statute book — live in
# lib.sh, which sources conf.sh itself. Sourcing only conf.sh left both as "command not
# found", and the refusal below caught it on the first run, which is what the refusal is for.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/spira" && pwd -P)/lib.sh"
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SESSION="${CONCIERGE_SESSION:-concierge}"
SOCKET="${CONCIERGE_SOCKET:-concierge}"
BRAIN="$SPIRA_REPO"
FAYTH="${CONCIERGE_FAYTH:-concierge}"
spira_require claude tmux || exit 1

TM="tmux -L $SOCKET"

# compose_brief -> path of the rendered system prompt, or non-zero with a reason on stderr.
#
# The same two-part shape aeon.sh uses: the persona's markdown with `{{...}}` placeholders
# substituted, then the statute book appended whole.
#
# IT WRITES A FILE AND PASSES `--append-system-prompt-file`, never the text as an argument.
# The statute book is tens of kilobytes and the session is started through `tmux new-session`,
# which takes its command as a STRING — the prompt would have to survive two rounds of shell
# quoting, and a statute containing a quote or a backtick would either break the launch or,
# far worse, be silently truncated into a brief that reads as complete.
#
# A MISSING BRIEF IS A REFUSAL, NOT A DEGRADED START. A concierge launched without its brief
# is the exact session this file exists to stop shipping: it looks identical to a working one
# from outside, and the way anybody finds out is the next violated statute.
compose_brief() {
    local md="$SPIRA_HOME/chamber/$FAYTH.md" out statutes n
    [ -f "$md" ] || { echo "concierge: no brief at $md" >&2; return 1; }

    # `law-` unless the fayth says otherwise — the same key builder and ops declare, read the
    # same way, so the concierge cannot end up reading a different book from the one its
    # persona file asks for.
    # THE CORE SET COMES FROM THE PERSONA, not from the box. An operator session and a builder
    # need different statutes in full text; the rest arrive as an index either way. See
    # FAYTH_STATUTE_CORE in the fayth for which ones and why.
    statutes="$(render_memories \
        "$(fayth_get "$FAYTH" FAYTH_MEMORY_PREFIXES law-)" "" \
        "$(fayth_get "$FAYTH" FAYTH_STATUTE_CORE "")")" || statutes=""
    if [ -z "$statutes" ]; then
        echo "concierge: the statute book rendered empty — refusing to start without it" >&2
        echo "  check: $HARNESS/rule.sh list" >&2
        return 1
    fi
    n="$(grep -c '^## ' <<<"$statutes" 2>/dev/null || printf 0)"

    out="$SPIRA_RUN/concierge-brief.md"
    mkdir -p "$SPIRA_RUN" 2>/dev/null
    {
        sed -e "s|{{CWD}}|$BRAIN|g" \
            -e "s|{{SPIRA_HOME}}|$SPIRA_HOME|g" \
            -e "s|{{COCKPIT}}|$SPIRA_COCKPIT|g" \
            -e "s|{{ASK}}|$SPIRA_NOTIFY|g" \
            -e "s|{{RULE}}|$HARNESS/rule.sh|g" \
            -e "s|{{DB}}|$SPIRA_DB|g" \
            -e "s|{{STATUTE_COUNT}}|$n|g" \
            -e "s|{{DEADLINE}}||g" \
            "$md"
        printf '\n# Memories in force\n\n%s\n' "$statutes"
    } > "$out" || return 1

    # THE PLACEHOLDER CHECK IS THE POINT OF DOING THIS IN A FUNCTION. An unsubstituted
    # `{{ASK}}` is not a cosmetic flaw — it is a command line the session will try to run,
    # and the failure arrives hours later as "the concierge does not escalate anything".
    if grep -q '{{[A-Z_]*}}' "$out"; then
        echo "concierge: brief still holds unsubstituted placeholders — refusing to start:" >&2
        grep -o '{{[A-Z_]*}}' "$out" | sort -u | sed 's/^/  /' >&2
        return 1
    fi
    printf '%s' "$out"
}

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
    BRIEF="$(compose_brief)" || exit 1
    MODEL="$(fayth_get "$FAYTH" FAYTH_MODEL "")"
    echo "concierge: brief $(wc -c < "$BRIEF") bytes${MODEL:+, model $MODEL}"

    # NO --allowedTools. For an interactive session under bypassed permissions that flag can
    # only SUBTRACT, and the persona's remit is unbounded — see concierge.fayth, where the
    # absence is the declaration. Every other persona names its tools because aeon.sh passes
    # them as an allow list that keeps a worker inside its job.
    $TM new-session -d -s "$SESSION" -c "$BRAIN" \
        "claude --remote-control '$SESSION' --dangerously-skip-permissions \
                ${MODEL:+--model '$MODEL'} --append-system-prompt-file '$BRIEF'"
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

# RENDER IT AND PRINT THE PATH, CHANGING NOTHING. The brief is the part of this session that
# is easy to get wrong and impossible to see from outside once it has started, so it has a
# seam of its own: `brief` is what the suite drives and what the operator reads before
# deciding the persona says what he meant.
brief)   b="$(compose_brief)" || exit 1; echo "$b"; ;;

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
