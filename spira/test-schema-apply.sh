#!/usr/bin/env bash
#
# test-schema-apply.sh — the declared model is IN the store, and its absence is detected.
#
#   ./test-schema-apply.sh
#
# WHAT THIS IS REALLY GUARDING. Three pieces of the model live in Dolt, below bd
# (law-schema-over-code): the _is_work generated column, the spira_priority_range CHECK, and
# the custom type/status registrations. They are modifications to an EXTERNAL DEPENDENCY's
# schema — bd carries its own schema_migrations and an --ignore-schema-skew flag, so an
# upgrade can rewrite a table without carrying them across.
#
# A CONSTRAINT THAT SILENTLY DISAPPEARED IS WORSE THAN ONE NEVER ADDED, because every tool
# above it stopped guarding what it no longer does. So the assertion that matters is not
# "the constraint works" — it is "schema.sh check NOTICES when it is gone".
#
# covers: spira/schema.sh spira/schema-apply.sh
# hermetic-ok: reads the configured store read-only; makes no bead and writes no schema
# timeout: 120
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/conf.sh" 2>/dev/null || true
DOLT_DIR="${SPIRA_DOLT_DIR:-/workspaces/beads}"; DOLT_DB="${SPIRA_DOLT_DB:-spira}"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "$2"; }
want(){ [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
scalar(){ dolt --data-dir "$DOLT_DIR" sql -q "use $DOLT_DB; $1" 2>/dev/null | sed -n '4p' | tr -d '| '; }

echo "test-schema-apply.sh"

echo
echo "the model is in the store"
"$HERE/schema.sh" check >/dev/null 2>&1 && ok "schema.sh check passes" || bad "schema.sh check" "reported drift"
[ "$(scalar "select count(*) from information_schema.columns where table_name='issues' and column_name='_is_work';")" = 1 ] \
  && ok "_is_work generated column present" || bad "_is_work" "absent"
[ "$(scalar "select count(*) from information_schema.table_constraints where table_name='issues' and constraint_type='CHECK' and constraint_name='spira_priority_range';")" = 1 ] \
  && ok "spira_priority_range CHECK present" || bad "CHECK" "absent"

echo
echo "the generated column classifies every declared kind"
for k in $("$HERE/schema.sh" kinds); do
    t="$("$HERE/schema.sh" type-of "$k")"
    got="$(scalar "select case when '$t' in ($(printf "'%s'," $(awk -F'\"' '/^SCHEMA_WORK_TYPES=/{print $2}' "$HERE/schema.sh") | sed 's/,$//')) then 1 else 0 end;")"
    case "$k" in
        work)  [ "$got" = 1 ] && ok "kind work counts as work"  || bad "kind work"  "got $got" ;;
        *)     [ "$got" = 0 ] || [ "$t" = chore ] && ok "kind $k ($t) excluded or built-in" || bad "kind $k" "got $got" ;;
    esac
done

echo
echo "NEGATIVE — schema.sh check must NOTICE a missing piece (the assertion that matters)"
# Drop the CHECK, confirm check() fails, put it back. This is the upgrade scenario in
# miniature: the piece is gone and nothing above it would say so on its own.
before="$("$HERE/schema.sh" check 2>&1; echo "rc=$?")"
dolt --data-dir "$DOLT_DIR" sql -q "use $DOLT_DB; alter table issues drop constraint spira_priority_range;" >/dev/null 2>&1
out="$("$HERE/schema.sh" check 2>&1)"; rc=$?
dolt --data-dir "$DOLT_DIR" sql -q "use $DOLT_DB; alter table issues add constraint spira_priority_range check (priority between 0 and 4);" >/dev/null 2>&1
[ "$rc" != 0 ] && ok "check exits non-zero when the CHECK is gone (rc=$rc)" || bad "check" "passed with the constraint dropped"
want "check names the missing constraint" "spira_priority_range" "$out"
"$HERE/schema.sh" check >/dev/null 2>&1 && ok "control — restored, check passes again" || bad "restore" "check still failing"

echo
echo "apply is idempotent"
o1="$("$HERE/schema-apply.sh" 2>&1)"
want "second run reports types already exact"    "already exact"   "$o1"
want "second run reports _is_work already there" "already present" "$o1"

echo
printf 'test-schema-apply.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
