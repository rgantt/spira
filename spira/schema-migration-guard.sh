#!/usr/bin/env bash
#
# schema-migration-guard.sh — PreToolUse fence against DELETE FROM schema_migrations.
#
#   bash schema-migration-guard.sh    reads Claude Code's PreToolUse JSON on stdin
#
# Exit 2 BLOCKS the tool call and feeds stderr back to the model. Exit 0 allows.
#
# WHY THIS EXISTS
# ---------------
# "Schema mismatch" escalations were filed three times asking an operator to run
# DELETE FROM schema_migrations WHERE version > N against the production beads store.
# Every one was wrong: a dev build from main knows MORE migrations than a tagged release,
# so version strings do not order the way a naive diagnosis assumes. The third escalation
# was approved on the framing "All bd commands fail unless BD_IGNORE_SCHEMA_SKEW=1" —
# a guess about the binary, marked as a guess, load-bearing for an irreversible action.
#
# The DELETE would remove migration rows from a Dolt database. Once committed through
# DOLT_COMMIT this is not reversible without restoring from backup.
#
# HOW MATCHING WORKS. The SQL appears as an argument to `bd sql` or `dolt sql`, not in
# a code position. Stripping double-quoted spans (as brain-guard.sh does for other checks)
# would make the SQL invisible after reduction. Instead this guard:
#   1. Strips heredoc bodies (data in heredocs is not an invocation)
#   2. Strips single-quoted spans (documentation, not invocations)
#   3. Does NOT strip double-quoted spans
#   4. Fires only when `bd` or `dolt` appears with `sql` as a subcommand in the SAME
#      pipeline segment as the SQL pattern — so `echo "DELETE FROM schema_migrations"`
#      does not fire (no bd/dolt + sql before it in the segment).
#
# A fence is a polite refusal — the override is named and honoured.
#
# WIRING: designed to be called as a Claude Code PreToolUse hook:
#   { "matcher": "Bash", "hooks": [{ "type": "command",
#     "command": "bash /path/to/spira/schema-migration-guard.sh" }] }
# Source harness.sh first when the path must be derived from SPIRA_HOME:
#   "command": "bash -c '. .claude/harness.sh 2>/dev/null; bash \"$SPIRA_HOME/schema-migration-guard.sh\"'"
set -uo pipefail

PAYLOAD="$(cat)"

# Extract the bash command from the PreToolUse JSON, then check for the dangerous SQL.
# A non-Bash tool or unparseable JSON exits 0 without firing.
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
# Content passed by heredoc to bd/dolt sql is also dangerous, but not stripping
# heredocs would cause false positives on documentation that quotes the SQL.
# The common attack vector is -q "..." which is not a heredoc.
def drop_heredocs(s):
    for m in list(re.finditer(r"<<-?\s*[\x27\"]?(\w+)[\x27\"]?", s)):
        tag = m.group(1)
        end = re.search(r"^\s*" + re.escape(tag) + r"\s*$", s[m.end():], re.M)
        if end:
            s = s[:m.end()] + s[m.end() + end.end():]
    return s

c = drop_heredocs(c)

# Strip single-quoted spans. Documentation like echo '"'"'DELETE FROM schema_migrations'"'"'
# must not fire the guard.
c = re.sub(r"\x27[^\x27]*\x27", " ", c)

# Double-quoted spans are NOT stripped. The SQL travels inside a double-quoted argument
# to -q or as the direct argument to dolt sql; stripping quotes removes the pattern.

# Split on pipeline and sequence operators to get independent command segments.
# Each segment is evaluated for the (bd/dolt sql + DELETE FROM schema_migrations) pair.
segs = re.split(r"\|\||\&\&|[;|\n]", c)

for seg in segs:
    # Does this segment invoke bd or dolt with sql as a subcommand?
    # Allow env vars (KEY=VAL) before the command and path prefixes on the binary.
    if not re.search(
        r"(?:^|\s)(?:\w+=\S+\s+)*(?:[-\w./]*/)?(?:bd|dolt)\b[^\n]*\bsql\b",
        seg
    ):
        continue
    # Does the SQL argument contain DELETE FROM schema_migrations?
    if re.search(r"\bDELETE\s+FROM\s+schema_migrations\b", seg, re.IGNORECASE):
        print("HIT")
        break
' 2>/dev/null)"

[ "$hit" = "HIT" ] || exit 0

# OVERRIDE, named in the refusal and honoured here. A test fixture that must modify
# schema_migrations on a throwaway database can set this to proceed.
[ "${SPIRA_ALLOW_SCHEMA_MIGRATION_DELETE:-0}" = "1" ] && exit 0
if printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = (d.get("tool_input") or {}).get("command", "")
sys.exit(0 if "SPIRA_ALLOW_SCHEMA_MIGRATION_DELETE=1" in c else 1)
' 2>/dev/null; then exit 0; fi

printf '\nBLOCKED by schema-migration-guard (DELETE FROM schema_migrations).\n\n' >&2
printf 'This SQL was the "documented recovery" for a false schema-mismatch diagnosis.\n' >&2
printf 'It was escalated three times, approved on the third, and was about to run\n' >&2
printf 'against a production store. Every diagnosis was wrong. Measure first:\n\n' >&2
printf '  bd migrate schema\n\n' >&2
printf 'If it prints "Schema already at vN", the database is healthy. No action needed.\n' >&2
printf 'If it reports a real mismatch, rebuild bd to match the cursor (spira/bd-pin.sh).\n' >&2
printf 'Deleting migration rows is never the correct fix.\n\n' >&2
printf 'OVERRIDE for a genuinely managed test fixture (not the production store):\n' >&2
printf '  SPIRA_ALLOW_SCHEMA_MIGRATION_DELETE=1\n' >&2
exit 2
