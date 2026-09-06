#!/usr/bin/env bash
# verdicts.sh — surface the operator's answers to escalations, so a verdict reaches the session.
#
# WHY THIS EXISTS. An escalation has two halves, the ask and the answer, and both need a
# mechanism. This is the answer's. The panel writes a verdict straight into the bead — a close
# reason for a decision, a comment for a reply — so there is no file for a session to tail, and
# an earlier design that promised one left the operator answering into a pane while nothing
# reached the agent. A verdict that reaches nobody is worse than an unanswered question: the
# decider believes they replied, and the next session asks again.
#
# A CURSOR, NOT A TAIL. The record is a row in the database, so this polls and prints only what
# is new since the last run, keeping the high-water mark beside the other runtime state. That
# makes it safe to run from a watcher: it is quiet when nothing has been answered, which is
# most of the time.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh" >/dev/null 2>&1
CURSOR="$SPIRA_RUN/.verdict-cursor"
INTERVAL="${VERDICT_INTERVAL:-30}"

emit() {                 # emit <since-iso> — prints verdicts, rewrites the cursor
    local since="$1"
    # The cursor is written by python to a named file rather than carried back through a
    # second stream: an earlier version routed it over stderr through a process substitution,
    # which raced the parent's read and left the mark unmoved, so every verdict was either
    # replayed forever or lost. One writer, one file.
    bdjson list --all --limit 0 --label "$SPIRA_ASK_LABEL" 2>/dev/null | python3 -c '
import json, sys
since, cursor_path, who = sys.argv[1], sys.argv[2], sys.argv[3]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
newest = since
rows = []
for i in (d if isinstance(d, list) else [d]):
    # A verdict is a CLOSE carrying a reason: for an ask, the reason IS the answer.
    if i.get("status") != "closed":
        continue
    at = i.get("closed_at") or i.get("updated_at") or ""
    if not at or at <= since:
        continue
    newest = max(newest, at)
    reason = (i.get("close_reason") or "").strip() or "(closed with no reason given)"
    rows.append((at, i.get("id", "?"), (i.get("title") or "")[:90], reason))
for at, ident, title, reason in sorted(rows):
    print(f"{who} ANSWERED {ident} — {title}")
    print(f"  verdict: {reason}")
open(cursor_path, "w").write(newest + "\n")
' "$since" "$CURSOR" "$SPIRA_OPERATOR"
}

[ -s "$CURSOR" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$CURSOR"
case "${1:-loop}" in
    once) emit "$(cat "$CURSOR")" ;;
    loop) while true; do
              emit "$(cat "$CURSOR")"
              sleep "$INTERVAL"
          done ;;
    *) echo "usage: verdicts.sh [once|loop]" >&2; exit 2 ;;
esac
