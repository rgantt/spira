#!/usr/bin/env bash
#
# bd-update-closed-guard.sh — PreToolUse fence against `bd update --status closed`
#   in aeon sessions.
#
#   bash bd-update-closed-guard.sh    reads Claude Code's PreToolUse JSON on stdin
#
# Exit 2 BLOCKS the tool call and feeds stderr back to the model. Exit 0 allows.
#
# WHY THIS EXISTS
# ---------------
# `bd update --status closed` leaves close_reason = NULL and writes no closed
# event. `bd close` always stores a reason ("Closed" at minimum), fires the
# closed event, and records the actor. 44 of 122 closed suite-filed beads have
# close_reason = NULL, all closed by aeon model sessions using `bd update
# --status closed` rather than the sanctioned `bd close --reason-file -`.
#
# A NULL close_reason breaks every downstream check that reads the reason
# (the panel, the ledger, the closed-event stream) and makes it impossible
# to reconstruct why a bead was closed. The chamber persona brief has always
# said `bd close --reason-file -`; this guard enforces it at the tool layer.
#
# THE CALLER IS THE AEON'S MODEL OUTPUT — not a harness shell script. Every
# harness script that closes a bead uses `bd close`. The only production use
# of `bd update --status closed` is in test fixtures (`test-loom.sh`), and
# those run outside a live aeon session, so SPIRA_AEON is not set there.
#
# WHY AEON SESSIONS ONLY
# ----------------------
# The offender is the model generating `bd update --status closed` as a Bash
# tool call during an aeon session. Binding this guard to the brain session
# (in .claude/guards/brain-guard.sh) would bind the most disciplined caller
# and miss the offender (law-guard-binds-the-caller). Test fixtures need
# `bd update --status closed` to seed pre-closed beads; those never run
# with SPIRA_AEON set, so they pass through unblocked.
#
# HOW MATCHING WORKS:
#   1. Strips heredoc bodies (data passed by heredoc is not an invocation)
#   2. Strips single-quoted spans (documentation must not fire the guard)
#   3. Does NOT strip double-quoted spans (the bead id may appear in quotes)
#   4. Matches `bd` (with optional path/env prefix) + `update` subcommand in
#      the same pipeline segment as `--status closed` or `--status=closed`
#
# A fence is a polite refusal — the override is named and honoured.
#
# WIRING: designed to be called as a Claude Code PreToolUse hook. Register via
# the operator's settings file alongside bd-remember-guard.sh:
#   { "matcher": "Bash", "hooks": [{ "type": "command",
#     "command": "bash /path/to/spira/bd-update-closed-guard.sh" }] }
# Source harness.sh first when the path must be derived from SPIRA_HOME:
#   "command": "bash -c '. .claude/harness.sh 2>/dev/null; bash \"$SPIRA_HOME/bd-update-closed-guard.sh\"'"
set -uo pipefail

# AEON SESSIONS ONLY. The caller who wrote NULL close_reason had SPIRA_AEON set;
# maintenance sessions and test fixtures do not. Exiting 0 here avoids binding
# the wrong caller (law-guard-binds-the-caller).
[ -n "${SPIRA_AEON:-}" ] || exit 0

PAYLOAD="$(cat)"

hit="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys, re

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

# Only Bash tool calls carry executable commands. Other tools exit clean.
if d.get("tool_name") != "Bash":
    sys.exit(0)

c = (d.get("tool_input") or {}).get("command", "")
if not c:
    sys.exit(0)

# Strip heredoc bodies: <<EOF / <<-"EOF" ... terminator on its own line.
def drop_heredocs(s):
    for m in list(re.finditer(r"<<-?\s*[\x27\"]?(\w+)[\x27\"]?", s)):
        tag = m.group(1)
        end = re.search(r"^\s*" + re.escape(tag) + r"\s*$", s[m.end():], re.M)
        if end:
            s = s[:m.end()] + s[m.end() + end.end():]
    return s

c = drop_heredocs(c)

# Strip single-quoted spans. Documentation like echo '"'"'bd update --status closed'"'"'
# must not fire the guard.
c = re.sub(r"\x27[^\x27]*\x27", " ", c)

# Double-quoted spans are NOT stripped. A bead id may appear inside a
# double-quoted argument; stripping quotes would hide the invocation.

# Split on pipeline and sequence operators to get independent command segments.
segs = re.split(r"\|\||\&\&|[;|\n]", c)

for seg in segs:
    # Does this segment invoke bd with update as a subcommand?
    # Allow env vars (KEY=VAL) before the command and path prefixes on the binary.
    if not re.search(
        r"(?:^|\s)(?:\w+=\S+\s+)*(?:[-\w./]*/)?bd\b[^\n]*\bupdate\b",
        seg
    ):
        continue
    # Does the update call set status to closed?
    # Match both --status closed and --status=closed forms.
    # Note: \b does not work before -- (hyphens are not word chars), so use (?<!\w).
    if re.search(r"(?<!\w)--status[=\s]+closed\b", seg):
        print("HIT")
        break
' 2>/dev/null)"

[ "$hit" = "HIT" ] || exit 0

# OVERRIDE, named here and honoured. A session that genuinely needs `bd update
# --status closed` — a fixture that seeds a pre-closed bead for a guard test —
# may set BD_UPDATE_CLOSED_OVERRIDE=1 to proceed.
[ "${BD_UPDATE_CLOSED_OVERRIDE:-0}" = "1" ] && exit 0
if printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = (d.get("tool_input") or {}).get("command", "")
sys.exit(0 if "BD_UPDATE_CLOSED_OVERRIDE=1" in c else 1)
' 2>/dev/null; then exit 0; fi

printf '\nBLOCKED by bd-update-closed-guard (bd update --status closed bypasses close_reason).\n\n' >&2
printf '`bd update --status closed` leaves close_reason = NULL and writes no closed event.\n' >&2
printf '44 of 122 closed suite-filed beads have close_reason = NULL from this path.\n\n' >&2
printf 'Use the sanctioned closer instead:\n\n' >&2
printf '  bd -C "$SPIRA_DB" close <bead-id> --reason-file - <<'"'"'REASON'"'"'\n' >&2
printf '  <explain what you found and why the bead is done>\n' >&2
printf '  REASON\n' >&2
printf '\n`bd close` always stores a reason, fires the closed event, and records the actor.\n' >&2
printf '\nOVERRIDE for a test fixture that must seed a pre-closed bead on purpose:\n' >&2
printf '  BD_UPDATE_CLOSED_OVERRIDE=1\n' >&2
exit 2
