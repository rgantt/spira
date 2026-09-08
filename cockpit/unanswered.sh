#!/usr/bin/env bash
#
# unanswered.sh — threads where the operator spoke last and nobody answered.
#
#   unanswered.sh            list them, newest silence first
#   unanswered.sh --count    just the number, for the dashboard
#
# WHY (the operator, verbatim: "i've left comments on both of the remaining FYI items in the
# attention pane but still haven't seen your responses. i need positive acknowledgement in
# the pane.")
#
# Two of their comments sat unanswered for three hours and five hours. The watcher had been
# skipping insights outright, so nothing even told me they existed — but the deeper problem
# is that "did anyone answer them" was not a MEASURED state. It depended on me noticing,
# which is the same class of failure as a check that only reports success.
#
# The rule this encodes: a thread whose newest comment is their is an OPEN OBLIGATION,
# whatever the bead's status says. An insight is closed by design and can still owe them a
# reply.
set -uo pipefail
# Every path comes from the harness's one configuration surface. It is two directories
# away because the cockpit ships beside the harness, not inside it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../spira" && pwd -P)/conf.sh"
export BEADS_NO_AUTO_IMPORT=1
COUNT_ONLY=0; [ "${1:-}" = "--count" ] && COUNT_ONLY=1
. "$(dirname "$0")/db.sh"

# Whose voice counts as "answered": the actor the OPERATOR's own comments are recorded under,
# which is a config key because it is one installation's account name. Everything else in the
# thread is mine, and a default of somebody's first name would make every other installation
# read its own replies as an answer.
HUMAN="${COCKPIT_HUMAN:-$SPIRA_OPERATOR_ACTOR}"
export HUMAN

rows=""
db=$(cockpit_db) || exit 1
ids=$(bd -C "$db" list --all --limit 0 --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import os, sys, json
ASK = os.environ.get("SPIRA_ASK_LABEL", "needs-operator")
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
for i in (d if isinstance(d, list) else [d]):
    # Only things that reach the pane at all, and only things with a conversation.
    labs = i.get("labels") or []
    if not ({"insight", ASK, "overseer"} & set(labs)):
        continue
    if (i.get("comment_count") or 0) < 1:
        continue
    print(i["id"])
' 2>/dev/null) || ids=""
for id in $ids; do
    line=$(bd -C "$db" comments "$id" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import sys, json, datetime, os
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
rows = d if isinstance(d, list) else d.get("comments", [])
if not rows: raise SystemExit
human = os.environ.get("HUMAN", "operator")

# WHOSE TURN IT IS, from an order this program establishes rather than inherits.
# Sorted, not taken positionally: bd comments returns oldest-first today, but a display
# whose meaning flips with an ORDER BY nobody here controls should not rest on that.
# Conditionally — an unstamped comment sorts before every stamped one, so an incomplete
# thread keeps the arrival order rather than being reshuffled around a blank.
if all(len(c.get("created_at") or "") >= 16 for c in rows):
    rows.sort(key=lambda c: c["created_at"])
    # created_at is second-resolution: two comments in the same second are a tie nothing
    # orders. The tie resolves toward "he is owed a reply" — a thread wrongly listed costs
    # a glance; a thread wrongly dropped is the silence this file exists to end.
    newest = rows[-1]["created_at"]
    tail = [c for c in rows if c["created_at"] == newest]
else:
    tail = rows[-1:]

his = [c for c in tail if (c.get("author") or "") == human]
if not his: raise SystemExit
last = his[-1]
ts = (last.get("created_at") or "")
try:
    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    mins = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60)
except Exception:
    mins = -1
print("%d\t%s\t%s" % (mins, ts[:16], (last.get("text") or "").strip().replace("\n", " ")[:70]))
' 2>/dev/null) || continue
    [ -n "$line" ] && rows="$rows$id	$line"$'\n'
done

n=$(printf '%s' "$rows" | grep -c . || true)
if [ "$COUNT_ONLY" = 1 ]; then printf '%s\n' "${n:-0}"; exit 0; fi
if [ "${n:-0}" -eq 0 ]; then echo "no threads are waiting on a reply"; exit 0; fi
printf '%s waiting on a reply, longest first:\n' "$n"
printf '%s' "$rows" | sort -t$'\t' -k2 -rn | while IFS=$'\t' read -r id mins ts text; do
    printf '  %-10s %5sm  %s\n' "$id" "$mins" "$text"
done
