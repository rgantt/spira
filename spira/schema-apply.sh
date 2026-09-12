#!/usr/bin/env bash
#
# schema-apply.sh — put the declared model INTO the store, idempotently. The one place any
# of it is written.
#
#   schema-apply.sh            apply; safe to re-run
#   schema-apply.sh --dry-run  say what would change, change nothing
#
# WHY ONE HOME
# ------------
# Three of these live below bd, in Dolt, and that is deliberate (law-schema-over-code): an
# invariant the store enforces binds every writer, including `bd sql` and tools not yet
# written, while the same rule in a script binds only callers who go through it.
#
# But they are modifications to an EXTERNAL DEPENDENCY's schema. bd carries its own
# schema_migrations and an --ignore-schema-skew flag, so an upgrade can alter a column a
# constraint depends on, or a migration can rewrite a table without carrying our additions
# across. A CONSTRAINT THAT SILENTLY DISAPPEARED IS WORSE THAN ONE NEVER ADDED, because every
# tool above it stopped guarding what it no longer does.
#
# So: one re-appliable file, and `schema.sh check` asserts the result is still there. Never
# scatter `alter table` calls — a scattered one cannot be re-applied after an upgrade, and
# nothing will tell you it went.
#
# ORDER OF PREFERENCE, cheapest first: a generated column where the rule is derivable from
# other columns; a CHECK where SQL can state it; a trigger only as a last resort, because a
# trigger is code again — just code living in the database.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$HERE/conf.sh" 2>/dev/null || true
DB="${SPIRA_DB:-/workspaces/spira}"
DOLT_DIR="${SPIRA_DOLT_DIR:-/workspaces/beads}"
DOLT_DB="${SPIRA_DOLT_DB:-spira}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf 'schema-apply: %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then printf 'schema-apply: WOULD RUN: %s\n' "$*"; else eval "$@"; fi; }
sql()  { dolt --data-dir "$DOLT_DIR" sql -q "use $DOLT_DB; $1" 2>&1; }
sqlq() { sql "$1" | sed -n '4p' | tr -d '| '; }

# ---- 1. custom types -------------------------------------------------------------------
# EXHAUSTIVE, and that is what retires the Gas Town types. Registration is the line between a
# type and a typo: with a type unregistered, `bd create --type <it>` is refused outright
# (verified both directions). An existing record whose type was later unregistered survives.
want_types="$("$HERE/schema.sh" custom-types | paste -sd, -)"
have_types="$(bd -C "$DB" config get types.custom 2>/dev/null | tail -1)"
if [ "$want_types" = "$have_types" ]; then say "custom types already exact: $want_types"
else say "custom types: [$have_types] -> [$want_types]"
     run "bd -C '$DB' config set types.custom '$want_types' >/dev/null"
fi

# ---- 2. custom statuses ----------------------------------------------------------------
# awaiting_ci is deliberately NOT here — it is a gh:run gate, because a status still requires
# every reader to remember to exclude it while a gate makes the bead not ready.
want_st="$("$HERE/schema.sh" statuses | paste -sd, -)"
have_st="$(bd -C "$DB" config get status.custom 2>/dev/null | tail -1)"
if [ "$want_st" = "$have_st" ]; then say "custom statuses already exact: $want_st"
else say "custom statuses: [$have_st] -> [$want_st]"
     run "bd -C '$DB' config set status.custom '$want_st' >/dev/null"
fi

# ---- 3. the _is_work generated column ---------------------------------------------------
# THE KIND-EXCLUSION RULE LIVES HERE ONCE, instead of as a type list at every call site. The
# store computes it; a work query is `where _is_work = 1`, and a reader that has never heard
# of events still gets the right answer.
work_types="$(awk -F'"' '/^SCHEMA_WORK_TYPES=/{print $2}' "$HERE/schema.sh")"
expr_sql="case when issue_type in ($(printf "'%s'," $work_types | sed 's/,$//')) then 1 else 0 end"
if [ "$(sqlq "select count(*) from information_schema.columns where table_name='issues' and column_name='_is_work';")" = "1" ]; then
    say "_is_work already present"
else
    say "_is_work: adding generated column over [$work_types]"
    run "sql \"alter table issues add column _is_work tinyint as ($expr_sql) stored;\" >/dev/null"
fi

# ---- 4. the priority CHECK --------------------------------------------------------------
# bd validates priority at the application layer already; this is the same rule one layer
# down, where `bd sql` and any future writer also meet it. Verified to refuse a bad write and
# accept a good one.
if [ "$(sqlq "select count(*) from information_schema.table_constraints where table_name='issues' and constraint_type='CHECK' and constraint_name='spira_priority_range';")" = "1" ]; then
    say "spira_priority_range already present"
else
    say "spira_priority_range: adding CHECK (priority between 0 and 4)"
    run "sql \"alter table issues add constraint spira_priority_range check (priority between 0 and 4);\" >/dev/null"
fi

[ "$DRY" = 1 ] && { say "dry run — nothing changed"; exit 0; }
say "applied. verifying with schema.sh check"
"$HERE/schema.sh" check
