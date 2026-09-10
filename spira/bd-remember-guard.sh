#!/usr/bin/env bash
#
# bd-remember-guard.sh — PreToolUse fence against `bd remember sop-*` and `bd remember law-*`
#   in aeon sessions.
#
#   bash bd-remember-guard.sh    reads Claude Code's PreToolUse JSON on stdin
#
# Exit 2 BLOCKS the tool call and feeds stderr back to the model. Exit 0 allows.
#
# WHY THIS EXISTS
# ---------------
# `bd remember` bypasses every validator `sop.sh write` and `rule.sh enact` enforce:
# required fields, a word cap, an inventory scan that refuses operator-specific paths.
# An agent that reaches for the storage primitive instead of the writer can put anything
# on the shelf — including an empty body (the literal `-` when stdin is empty), which
# is what produced six SOPs whose only content was a dash. Those six held the landing
# gate red until they were recovered and rewritten.
#
# The same hole exists for law- keys: `bd remember law-foo` stores an unchecked string
# in the statute book rather than going through `rule.sh enact`.
#
# WHY AEON SESSIONS ONLY
# ----------------------
# The brain session did not write these bad keys — aeons did. Binding this guard to
# the brain session (e.g. in .claude/guards/brain-guard.sh) would bind the most
# disciplined caller and miss the offender entirely (law-guard-binds-the-caller). The
# guard checks SPIRA_AEON and allows the call through in non-aeon sessions, so a
# maintenance session at the keyboard is not blocked.
#
# HOW MATCHING WORKS. A `bd ... remember <key>` is detected by:
#   1. Stripping heredoc bodies (data, not invocations)
#   2. Stripping single-quoted spans (documentation)
#   3. NOT stripping double-quoted spans (the key itself may be double-quoted)
#   4. Matching bd (with optional path/env prefix) followed by remember, then a
#      key beginning with sop- or law- — anchored on the key's first token so
#      sop-foo and law-foo are caught but not sopath or lawyer.
#
# A fence is a polite refusal — the override is named and honoured.
#
# WIRING: designed to be called as a Claude Code PreToolUse hook. Register via the
# operator's settings file, alongside schema-migration-guard.sh:
#   { "matcher": "Bash", "hooks": [{ "type": "command",
#     "command": "bash /path/to/spira/bd-remember-guard.sh" }] }
# Source harness.sh first when the path must be derived from SPIRA_HOME:
#   "command": "bash -c '. .claude/harness.sh 2>/dev/null; bash \"$SPIRA_HOME/bd-remember-guard.sh\"'"
set -uo pipefail

# AEON SESSIONS ONLY. The caller who wrote bad keys had SPIRA_AEON set; maintenance
# sessions at the keyboard do not. Exiting 0 here costs nothing and avoids binding
# the wrong caller.
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
# A body passed by heredoc to bd remember is data; we want to inspect the
# invocation line, not the value being stored.
def drop_heredocs(s):
    for m in list(re.finditer(r"<<-?\s*[\x27\"]?(\w+)[\x27\"]?", s)):
        tag = m.group(1)
        end = re.search(r"^\s*" + re.escape(tag) + r"\s*$", s[m.end():], re.M)
        if end:
            s = s[:m.end()] + s[m.end() + end.end():]
    return s

c = drop_heredocs(c)

# Strip single-quoted spans. Documentation like echo '"'"'bd remember sop-x'"'"'
# must not fire the guard.
c = re.sub(r"\x27[^\x27]*\x27", " ", c)

# Double-quoted spans are NOT stripped. The key may appear inside a double-quoted
# argument, and stripping it would hide the pattern.

# Split on pipeline and sequence operators to get independent command segments.
segs = re.split(r"\|\||\&\&|[;|\n]", c)

for seg in segs:
    # Does this segment invoke bd with remember as a subcommand?
    # Allow env vars (KEY=VAL) before the command and path prefixes on the binary.
    if not re.search(
        r"(?:^|\s)(?:\w+=\S+\s+)*(?:[-\w./]*/)?bd\b[^\n]*\bremember\b",
        seg
    ):
        continue
    # Does the key start with sop- or law-?
    # The key can be:
    #   positional:  bd [opts] remember sop-foo ...
    #   via --key:   bd [opts] remember --key sop-foo ...
    # Anchor on a word boundary before sop- / law- to avoid matching soppath or lawyer.
    if re.search(
        r"\bremember\b(?:\s+(?:-\S+\s+)*)?(?:\s+--key\s+)?\s*\b(?:sop|law)-",
        seg
    ):
        print("HIT")
        break
' 2>/dev/null)"

[ "$hit" = "HIT" ] || exit 0

# OVERRIDE, named here and honoured. A session that genuinely needs to write a raw
# key — a fixture seeding a malformed SOP for a lint test — may set this to proceed.
[ "${BD_REMEMBER_MANAGED_KEY_OVERRIDE:-0}" = "1" ] && exit 0
if printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = (d.get("tool_input") or {}).get("command", "")
sys.exit(0 if "BD_REMEMBER_MANAGED_KEY_OVERRIDE=1" in c else 1)
' 2>/dev/null; then exit 0; fi

printf '\nBLOCKED by bd-remember-guard (bd remember on a managed key prefix).\n\n' >&2
printf '`bd remember sop-*` bypasses the write validator and can store a malformed\n' >&2
printf 'runbook or a dash. Six empty SOPs held the landing gate red this way.\n\n' >&2
printf 'Use the sanctioned writers instead:\n\n' >&2
printf '  sop-* keys:  sop.sh write <slug> [-|<file>]\n' >&2
printf '  law-* keys:  rule.sh enact <slug> "<statute text>"\n' >&2
printf '\nBoth validate before storing and synthesise the wiki page.\n' >&2
printf '\nOVERRIDE for a test fixture that must seed a malformed key on purpose:\n' >&2
printf '  BD_REMEMBER_MANAGED_KEY_OVERRIDE=1\n' >&2
exit 2
