#!/usr/bin/env bash
# verdicts.sh — surface what the operator said, so an answer reaches the session.
#
#   verdicts.sh once     one pass; prints nothing when nothing is new
#   verdicts.sh loop     the same, on an interval — the Monitor form
#
# WHY THIS EXISTS. An escalation queue has two halves, the ask and the answer, and for a
# long time only the ask had a mechanism. The operator answered in the attention pane,
# correctly, and nothing reached the agent — they had to say so themselves. Twice: once for
# a close carrying a verdict, and again for a COMMENT on an FYI, which no leg could see at
# all because an FYI is created closed and carries no escalation label.
#
# Both legs live in answers.py, which cockpit/answered-since.sh also runs. One implementation
# rather than two: the previous arrangement had a close-watcher here and a different one in
# the cockpit, and the FYI blindness had to be found separately in each.
#
# This file's job is only to decide WHICH DATABASE and hold the cursors.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib.sh"
INTERVAL="${VERDICT_INTERVAL:-30}"

# Two marks, because a close and a comment are ordered by different clocks: a comment does
# NOT bump the bead's updated_at, so a cursor over closes cannot express how far the comment
# leg has read. One file for one question.
VERDICT_CURSOR="${VERDICT_CURSOR:-$SPIRA_RUN/.verdict-cursor}"
COMMENT_CURSOR="${COMMENT_CURSOR:-$SPIRA_RUN/.comment-cursor}"

emit() {
    # `bd --json` can print warnings on stdout before the payload; json_only strips them.
    # --all because an FYI is created CLOSED and `bd list` hides closed issues, which on its
    # own would make this blind to the exact case it was written for.
    bdjson list --all --limit 0 \
        | python3 "$HERE/answers.py" \
            "bd=${SPIRA_BD:-bd}" "db=$SPIRA_DB" \
            "ask_label=$SPIRA_ASK_LABEL" "operator_actor=$SPIRA_OPERATOR_ACTOR" \
            "operator=$SPIRA_OPERATOR" \
            "verdict_cursor=$VERDICT_CURSOR" "comment_cursor=$COMMENT_CURSOR" \
            format=monitor
}

case "${1:-loop}" in
    once) emit ;;
    loop) while true; do emit; sleep "$INTERVAL"; done ;;
    *) echo "usage: verdicts.sh [once|loop]" >&2; exit 2 ;;
esac
