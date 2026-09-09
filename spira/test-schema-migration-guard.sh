#!/usr/bin/env bash
#
# test-schema-migration-guard.sh — schema-migration-guard.sh refuses DELETE FROM
#   schema_migrations in any bash command, regardless of quoting context, and honours
#   its named override.
#
# POSITIVE CONTROL FIRST (law-absence-needs-a-positive-control): the guard MUST fire on
# the exact SQL from the retired SOP before any negative control runs, so silence from
# the negative controls is evidence the guard works — not that it never could.
#
# The exact command driven here is the SQL that the retired sop-beads-schema-recovery
# instructed an operator to run (spira-harness fef33bd):
#
#   DELETE FROM schema_migrations WHERE version > 53
#
# That SOP referenced an external recovery guide. Subsequent escalation beads translated
# it into the exact bd / dolt invocation that would have destroyed 8 migration rows in the
# production store. This suite plants that invocation first.
#
# defect: sp-1khst
# covers: spira/schema-migration-guard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "wanted [$2] in [$3]"; esac; }

echo "test-schema-migration-guard.sh"

GUARD="$HERE/schema-migration-guard.sh"
[ -f "$GUARD" ] || { printf 'SKIP schema-migration-guard.sh not found at %s\n' "$GUARD"; exit 77; }

# run_guard <command> [env=val ...] -> combined stdout+stderr from the guard, exit status
# Builds the PreToolUse JSON on stdout, pipes it to the guard which runs in an environment
# with any extra KEY=VAL args applied. The JSON producer runs with default env; only the
# guard receives the override variables.
run_guard() {
    local cmd="$1"; shift
    local rc out
    out=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$cmd" | env -i PATH="$PATH" HOME="$HOME" "$@" bash "$GUARD" 2>&1); rc=$?
    printf '%s' "$out"
    return "$rc"
}

# ==========================================================================
echo
echo "POSITIVE CONTROL — exact SOP command: bd sql"
# ==========================================================================
# The retired sop-beads-schema-recovery directed operators to run this SQL.
# The guard must refuse it; an empty result here would be indistinguishable
# from the guard pointing at a wrong path or never parsing the command at all.

out=$(run_guard 'bd -C /test/db sql -q "DELETE FROM schema_migrations WHERE version > 53"' || true)
want "bd sql DELETE refused"            "BLOCKED by schema-migration-guard" "$out"
want "bd sql DELETE names override"     "SPIRA_ALLOW_SCHEMA_MIGRATION_DELETE" "$out"
want "bd sql DELETE suggests measure"   "bd migrate schema" "$out"

# ==========================================================================
echo
echo "POSITIVE CONTROL — exact SOP command: dolt sql"
# ==========================================================================
out=$(run_guard 'dolt -C /test/db sql "DELETE FROM schema_migrations WHERE version > 53"' || true)
want "dolt sql DELETE refused"          "BLOCKED by schema-migration-guard" "$out"
want "dolt sql DELETE names override"   "SPIRA_ALLOW_SCHEMA_MIGRATION_DELETE" "$out"

# ==========================================================================
echo
echo "POSITIVE CONTROL — case variations"
# ==========================================================================
out=$(run_guard 'bd -C /test/db sql -q "delete from schema_migrations where version > 53"' || true)
want "lowercase delete refused"         "BLOCKED by schema-migration-guard" "$out"

out=$(run_guard 'dolt sql "DELETE  FROM  schema_migrations"' || true)
want "extra whitespace refused"         "BLOCKED by schema-migration-guard" "$out"

# ==========================================================================
echo
echo "override is honoured"
# ==========================================================================
out=$(run_guard 'bd -C /test/db sql -q "DELETE FROM schema_migrations WHERE version > 53"' \
                SPIRA_ALLOW_SCHEMA_MIGRATION_DELETE=1 2>&1) || true
want "env override allowed: no BLOCKED" "" "$out"
# The guard exited 0 — check that no refusal message appeared.
case "$out" in *"BLOCKED"*) bad "env override: BLOCKED appeared" "should have passed" ;; esac

out=$(run_guard 'SPIRA_ALLOW_SCHEMA_MIGRATION_DELETE=1 bd -C /test/db sql -q "DELETE FROM schema_migrations"' \
                2>&1) || true
case "$out" in *"BLOCKED"*) bad "inline override: BLOCKED appeared" "should have passed" ;; esac
ok "inline override allowed"

# ==========================================================================
echo
echo "innocent SQL is not refused"
# ==========================================================================
out=$(run_guard 'bd -C /test/db sql -q "SELECT * FROM schema_migrations"' 2>&1) || true
case "$out" in *"BLOCKED"*) bad "SELECT not refused: BLOCKED appeared" "" ;; *)
    ok "SELECT schema_migrations: not refused" ;; esac

out=$(run_guard 'dolt sql "DELETE FROM beads WHERE id = 1"' 2>&1) || true
case "$out" in *"BLOCKED"*) bad "DELETE other table: BLOCKED appeared" "" ;; *)
    ok "DELETE other table: not refused" ;; esac

out=$(run_guard 'bd migrate schema' 2>&1) || true
case "$out" in *"BLOCKED"*) bad "bd migrate schema: BLOCKED appeared" "" ;; *)
    ok "bd migrate schema: not refused" ;; esac

# ==========================================================================
echo
echo "prose in quoted spans is not refused"
# ==========================================================================

# Single quotes: the exact SQL in documentation must not fire the guard.
out=$(run_guard "echo 'never run DELETE FROM schema_migrations in production'" 2>&1) || true
case "$out" in *"BLOCKED"*) bad "single-quoted prose: BLOCKED appeared" "" ;; *)
    ok "single-quoted prose: not refused" ;; esac

# Heredoc body: the rule writing its own documentation must not block itself.
out=$(run_guard 'cat > recovery.md <<'"'"'EOF'"'"'
Do NOT run: DELETE FROM schema_migrations WHERE version > 53
The above SQL was the wrong recovery. Use bd migrate schema instead.
EOF' 2>&1) || true
case "$out" in *"BLOCKED"*) bad "heredoc prose: BLOCKED appeared" "" ;; *)
    ok "heredoc prose: not refused" ;; esac

# ==========================================================================
echo
echo "non-Bash tools pass through"
# ==========================================================================
out=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Read", "tool_input": {"file_path": "schema_migrations.txt"}}))
' | bash "$GUARD" 2>&1) || true
case "$out" in *"BLOCKED"*) bad "non-Bash tool: BLOCKED appeared" "" ;; *)
    ok "non-Bash tool: not refused" ;; esac

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
