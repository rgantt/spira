#!/usr/bin/env bash
#
# test-schema-apply.sh — the declared model is in the store, and its ABSENCE is detected.
#
#   ./test-schema-apply.sh
#
# WHAT THIS IS REALLY GUARDING. Two pieces of the model live in Dolt, below bd
# (law-schema-over-code): the _is_work generated column and the spira_priority_range CHECK.
# They are modifications to an EXTERNAL DEPENDENCY's schema — bd carries its own
# schema_migrations and an --ignore-schema-skew flag, so an upgrade can rewrite a table
# without carrying them across.
#
# A CONSTRAINT THAT SILENTLY DISAPPEARED IS WORSE THAN ONE NEVER ADDED, because every tool
# above it stopped guarding what it no longer does. So the assertion that matters is not
# "the constraint works" — it is "the detection NOTICES when it is gone".
#
# THAT NEGATIVE IS PROVED IN A FIXTURE, NOT IN PRODUCTION. An earlier version of this suite
# dropped the real constraint, asserted, and added it back: a window in which production had
# no constraint, and if the suite died between the two it stayed gone — the exact failure it
# exists to detect, caused by the detector (law-probe-a-fixture-not-production). The fixture
# is a throwaway Dolt database in the suite's own scratch directory; it costs ~0.3s.
#
# covers: spira/schema.sh spira/schema-apply.sh
# hermetic-ok: dolt is pointed at a fixture inside the suite's own scratch dir; the only
# hermetic-ok: production access is read-only through the bd seam
# timeout: 120
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/conf.sh" 2>/dev/null || true

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "$2"; }
want(){ [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
echo "test-schema-apply.sh"

echo
echo "the model is in the configured store (read-only, through the bd seam)"
"$HERE/schema.sh" check >/dev/null 2>&1 && ok "schema.sh check passes" || bad "schema.sh check" "reported drift"

echo
echo "the generated column classifies every declared kind"
work_types="$(awk -F'"' '/^SCHEMA_WORK_TYPES=/{print $2}' "$HERE/schema.sh")"
for k in $("$HERE/schema.sh" kinds); do
    t="$("$HERE/schema.sh" type-of "$k")"
    case " $work_types " in
        *" $t "*) [ "$k" = work ] || [ "$t" = chore ] && ok "kind $k ($t) is a work type" || bad "kind $k" "unexpectedly a work type" ;;
        *)        ok "kind $k ($t) is excluded from work by type" ;;
    esac
done

echo
echo "NEGATIVE — detection notices a missing CHECK (proved in a fixture, never in production)"
( cd "$T" && dolt init -b main >/dev/null 2>&1 )
dolt --data-dir "$T" sql -q "create database fx; use fx; create table issues (id varchar(64) primary key, priority int, issue_type varchar(32));" >/dev/null 2>&1
q="select count(*) as n from information_schema.table_constraints where table_name='issues' and constraint_type='CHECK' and constraint_name='spira_priority_range';"
fx(){ dolt --data-dir "$T" sql -q "use fx; $1" 2>/dev/null | sed -n '4p' | tr -d '| '; }

[ "$(fx "$q")" = "0" ] && ok "absent constraint detected as absent" || bad "absent" "got [$(fx "$q")]"
dolt --data-dir "$T" sql -q "use fx; alter table issues add constraint spira_priority_range check (priority between 0 and 4);" >/dev/null 2>&1
[ "$(fx "$q")" = "1" ] && ok "control — present constraint detected as present" || bad "present" "got [$(fx "$q")]"
dolt --data-dir "$T" sql -q "use fx; alter table issues drop constraint spira_priority_range;" >/dev/null 2>&1
[ "$(fx "$q")" = "0" ] && ok "dropped constraint detected as gone — the bd-upgrade scenario" || bad "dropped" "got [$(fx "$q")]"

echo
echo "and the constraint actually refuses, in the fixture"
dolt --data-dir "$T" sql -q "use fx; alter table issues add constraint spira_priority_range check (priority between 0 and 4);" >/dev/null 2>&1
out="$(dolt --data-dir "$T" sql -q "use fx; insert into issues values ('x',9,'task');" 2>&1)"
want "priority 9 refused by the CHECK" "spira_priority_range" "$out"
out="$(dolt --data-dir "$T" sql -q "use fx; insert into issues values ('y',2,'task');" 2>&1)"
[[ "$out" != *"violated"* ]] && ok "control — priority 2 accepted" || bad "control" "good write refused: $out"

echo
echo "apply is idempotent"
o1="$("$HERE/schema-apply.sh" 2>&1)"
want "second run reports types already exact"    "already exact"   "$o1"
want "second run reports _is_work already there" "already present" "$o1"

echo
printf 'test-schema-apply.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
