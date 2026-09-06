#!/usr/bin/env bash
#
# resolve.sh — close a bead I established or did myself, and do not page the operator about it.
#
#   resolve.sh <bead-id> "<reason>"
#   resolve.sh <bead-id> -            # reason on stdin
#
# WHY (the operator's call): *"for beads that are machine checkable... just go machine
# check them. i don't need to take action if you can. this is perfectly acceptable for
# non-destructive actions."* — law-check-it-yourself-before-asking.
#
# Closing is now routine for me, which created a second-order bug the moment it started:
# watch-answers.sh announced the harness's OWN close back to it as "THE OPERATOR ANSWERED". The
# comment path already checks authorship; the close path could not, because a beads close
# records no actor — there is no closed_by in the payload, and the Dolt committer is
# always the literal string "beads" whatever BEADS_ACTOR says. So the id is recorded here
# instead, and the watcher skips what it finds.
#
# Reasons carry their evidence. A close that says "done" is a claim with nothing behind it;
# quote the command and its output, so the bead is still readable as a decision months on.
set -uo pipefail

. "$(dirname "$0")/db.sh"
SELF="${SELF_CLOSED:-$(dirname "$0")/.runtime/self-closed}"

id="${1:-}"; reason="${2:-}"
if [ -z "$id" ] || [ -z "$reason" ]; then
  echo "usage: resolve.sh <bead-id> \"<reason with evidence>\"" >&2; exit 2
fi
[ "$reason" = "-" ] && reason=$(cat)
mkdir -p "$(dirname "$SELF")"

# THE database (db.sh). A close names one database because there is one; the search this
# replaces existed only to pick between copies of the same bead.
db=$(cockpit_db) || exit 1

# Record BEFORE closing: if the close succeeds and the write does not, the watcher pages
# the operator about my own work. The reverse — a recorded id that never closed — is harmless.
printf '%s\n' "$id" >> "$SELF"

# --force because rig beads are usually assigned to the mayor, and closing one as `claude`
# is refused otherwise. The assignee check is right for work; this is a verdict on an ask.
if BEADS_ACTOR=claude "$BD" -C "$db" close "$id" --force --reason "$reason" >/dev/null 2>&1; then
  echo "resolved $id (${db##*/})"
else
  echo "resolve.sh: failed to close $id in $db" >&2; exit 1
fi
