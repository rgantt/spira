#!/usr/bin/env bash
#
# reply.sh — answer the operator in the bead's own thread.
#
#   reply.sh <bead-id> "<text>"
#   reply.sh <bead-id> -          # read the text from stdin
#
# WHY (the operator's call):
#   "if i add a comment to a bead in the beads pane, i don't want you to respond here then
#    open another bead. that makes no fucking sense. you're just creating more work and
#    spreading out the context. the conversation in the beads pane is already threaded."
#
# Two failures this prevents, both committed in one session:
#   - answering in the chat transcript, where they are not reading, and
#   - answering by filing a NEW bead, which forks the conversation instead of continuing
#     it. The same question then existed three times over, which is why the operator had
#     "answered this multiple times already".
#
# The model is theirs: either we are commenting until we find a path forward, or they have decided
# and I execute. A new bead is neither.
#
# It also fixes authorship. This session and the pane both wrote as `overseer`, so a reply
# of mine was indistinguishable from one of theirs -- the answer watcher announced my own
# comment back to it as an operator reply, and the pane could not show whose turn it was.
# The agent's are `claude`; the pane writes the operator's as $SPIRA_OPERATOR_ACTOR.
set -uo pipefail

. "$(dirname "$0")/db.sh"
ME="claude"

id="${1:-}"; text="${2:-}"
if [ -z "$id" ] || [ -z "$text" ]; then
  echo "usage: reply.sh <bead-id> \"<text>\"   (or - to read stdin)" >&2
  exit 2
fi
[ "$text" = "-" ] && text=$(cat)

# THE database (db.sh). There is one, so an id needs no lookup and a reply cannot land in
# the wrong copy of a thread -- which is what the search it replaces was for.
db=$(cockpit_db) || exit 1

BEADS_ACTOR="$ME" "$BD" -C "$db" comments add "$id" "$text" >/dev/null 2>&1 || {
  echo "reply.sh: failed to comment on $id in $db" >&2
  exit 1
}
echo "replied on $id (${db##*/})"
