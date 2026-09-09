#!/usr/bin/env bash
#
# test-cockpit-repo-labels.sh — SP_REPO_UNMAPPED and SP_REPO_ABSENT count non-closed beads
# whose repo: label is absent from the map or missing entirely.
#
#   ./test-cockpit-repo-labels.sh
#
# THE FAILURE THIS SUITE EXISTS FOR (sp-sqlk). Hand-filed beads occasionally carry
# `repo:spira-harness` (the PATH) instead of `repo:spira` (the label). Each costs an aeon
# start and a bogus needs-ryan. A shim on bd binds every session for a check that costs one
# graph read; watchtower reads the graph on a timer already. The vital signs added here are
# the right rung.
#
# BOTH CATEGORIES ARE COUNTED SEPARATELY. An unmapped label (`repo:bogus`) and no label at
# all fail closed identically — both park the aeon at unmapped-repo — but the counts are
# kept separate so the sweep can say whether the root cause is a mis-set label or a missing
# one.
#
# EVERY CASE IS A PAIR (law-absence-needs-a-positive-control). The negative control (empty
# database, correctly-labelled bead) proves the check can read a true zero. The positive
# control (unmapped / absent bead) proves it reads the real count rather than always
# returning zero.
#
# REPO-MAP UNREADABLE IS `?`, NOT 0. An unreadable map and a map with all beads correctly
# mapped are indistinguishable from the outside; the only honest answer is `?`.
#
# defect: sp-sqlk
# covers: spira/cockpit.sh spira/watchtower.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/testdb.sh"
testdb_require test-cockpit-repo-labels
TMP="$(mktemp -d)"
testdb_up repo-labels || { echo "test-cockpit-repo-labels: could not build a fixture database"; exit 1; }
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# A minimal repo-map with one valid entry. Pin to a non-default name ('validrepo') so the
# test cannot silently pass if the code has a literal like 'brain' baked in.
MAP="$TMP/repo-map"
printf 'validrepo | /opt/valid | push | origin/main | | \n' > "$MAP"

RUN="$TMP/run"; mkdir -p "$RUN"
run_repo_labels() {    # run_repo_labels [KEY=val ...]  — extra args override env vars
    # SPIRA_REPO_MAP is always pinned to the test fixture first. Extra KEY=val args (passed
    # via "$@") appear after it in env's arg list, so they override it when needed — this is
    # how the unreadable-map test passes SPIRA_REPO_MAP=/nonexistent without colliding with
    # whatever SPIRA_REPO_MAP might be inherited from the caller's environment.
    env -i PATH="$PATH" HOME="$HOME" LC_ALL=C.UTF-8 \
        SPIRA_PATH="${SPIRA_PATH:-}" \
        SPIRA_CONF="$TMP/no.conf" SPIRA_HOME="$HERE" SPIRA_REPO="$TMP" \
        SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" \
        SPIRA_REPO_MAP="$MAP" SPIRA_GOAL=sp-goal SPIRA_FAYTHS=t \
        SPIRA_ASK_LABEL=needs-ryan \
        "$@" \
        bash "$HERE/cockpit.sh" repo_labels 2>/dev/null
}

echo "test-cockpit-repo-labels.sh"

# ======================================================================================
echo
echo "NEGATIVE CONTROL: empty database — both counts should be 0, not ?:"
# ======================================================================================
# A probe that returns ? on an empty database is broken, not cautious. An empty list is a
# real measurement; `?` means the probe failed (law-absence-needs-a-positive-control).
testdb_reset
out="$(run_repo_labels)"
is "SP_REPO_UNMAPPED is 0 on empty database (not ?)" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_UNMAPPED=//p' | head -1)"
is "SP_REPO_ABSENT is 0 on empty database (not ?)" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_ABSENT=//p' | head -1)"

# ======================================================================================
echo
echo "NEGATIVE CONTROL: a correctly-labelled bead is counted in neither:"
# ======================================================================================
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-good","title":"correctly labelled bead","status":"open","issue_type":"task","labels":["validrepo","repo:validrepo"],"updated_at":"2026-09-09T00:00:00Z"}
JSONL
out="$(run_repo_labels)"
is "a correctly-labelled bead: SP_REPO_UNMAPPED=0" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_UNMAPPED=//p' | head -1)"
is "a correctly-labelled bead: SP_REPO_ABSENT=0" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_ABSENT=//p' | head -1)"

# ======================================================================================
echo
echo "POSITIVE CONTROL: a bead with a bogus repo: label appears in SP_REPO_UNMAPPED:"
# ======================================================================================
# This is the root cause: `repo:spira-harness` instead of `repo:spira`. The valid set has
# `validrepo` only; `bogusrepo` is absent.
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-bogus","title":"bead with unmapped repo label","status":"open","issue_type":"task","labels":["repo:bogusrepo"],"updated_at":"2026-09-09T00:00:00Z"}
JSONL
out="$(run_repo_labels)"
is "an unmapped repo: label: SP_REPO_UNMAPPED=1" "1" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_UNMAPPED=//p' | head -1)"
is "an unmapped repo: label: SP_REPO_ABSENT=0 (has a label, just wrong)" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_ABSENT=//p' | head -1)"

# ======================================================================================
echo
echo "POSITIVE CONTROL: a bead with no repo: label appears in SP_REPO_ABSENT:"
# ======================================================================================
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-norepo","title":"bead with no repo label","status":"open","issue_type":"task","labels":["spira","plan"],"updated_at":"2026-09-09T00:00:00Z"}
JSONL
out="$(run_repo_labels)"
is "no repo: label: SP_REPO_ABSENT=1" "1" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_ABSENT=//p' | head -1)"
is "no repo: label: SP_REPO_UNMAPPED=0" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_UNMAPPED=//p' | head -1)"

# ======================================================================================
echo
echo "CLOSED beads are excluded from both counts:"
# ======================================================================================
# bdjson list --limit 0 (no --all) returns only non-closed beads; closed ones are invisible
# to this check by the query's own filter.
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-cl-bogus","title":"closed unmapped bead","status":"closed","issue_type":"task","labels":["repo:bogusrepo"],"updated_at":"2026-09-09T00:00:00Z"}
{"id":"sp-cl-norepo","title":"closed bead with no repo label","status":"closed","issue_type":"task","labels":["spira"],"updated_at":"2026-09-09T00:00:00Z"}
JSONL
out="$(run_repo_labels)"
is "closed bead with bogus label is not counted: SP_REPO_UNMAPPED=0" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_UNMAPPED=//p' | head -1)"
is "closed bead with no label is not counted: SP_REPO_ABSENT=0" "0" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_ABSENT=//p' | head -1)"

# ======================================================================================
echo
echo "MIXED database: correct, unmapped, and absent beads are counted separately:"
# ======================================================================================
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-m-good1","title":"correctly labelled","status":"open","issue_type":"task","labels":["repo:validrepo"],"updated_at":"2026-09-09T00:00:00Z"}
{"id":"sp-m-good2","title":"correctly labelled 2","status":"in_progress","issue_type":"task","labels":["repo:validrepo"],"updated_at":"2026-09-09T00:00:00Z"}
{"id":"sp-m-bad1","title":"unmapped repo label","status":"open","issue_type":"task","labels":["repo:spira-harness"],"updated_at":"2026-09-09T00:00:00Z"}
{"id":"sp-m-bad2","title":"another unmapped repo label","status":"open","issue_type":"task","labels":["repo:unknown"],"updated_at":"2026-09-09T00:00:00Z"}
{"id":"sp-m-none1","title":"no repo label","status":"open","issue_type":"task","labels":["spira","plan"],"updated_at":"2026-09-09T00:00:00Z"}
{"id":"sp-m-none2","title":"no repo label either","status":"blocked","issue_type":"task","labels":[],"updated_at":"2026-09-09T00:00:00Z"}
{"id":"sp-m-closed","title":"closed no repo","status":"closed","issue_type":"task","labels":[],"updated_at":"2026-09-09T00:00:00Z"}
JSONL
out="$(run_repo_labels)"
is "mixed: SP_REPO_UNMAPPED=2 (two unmapped, not the two correct ones)" "2" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_UNMAPPED=//p' | head -1)"
is "mixed: SP_REPO_ABSENT=2 (two with no label, not the closed one)" "2" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_ABSENT=//p' | head -1)"

# ======================================================================================
echo
echo "UNREADABLE repo-map renders ? for both counts, not 0:"
# ======================================================================================
# An unreadable map is not the same as a clean one — the ? is what prevents the reassuring
# reading from displacing the suspicion that would prompt a look
# (law-absence-needs-a-positive-control).
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-rmap","title":"open bead","status":"open","issue_type":"task","labels":["repo:bogusrepo"],"updated_at":"2026-09-09T00:00:00Z"}
JSONL
out="$(run_repo_labels SPIRA_REPO_MAP=/nonexistent/no-such-map)"
is "unreadable map: SP_REPO_UNMAPPED=?" "?" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_UNMAPPED=//p' | head -1)"
is "unreadable map: SP_REPO_ABSENT=?" "?" \
   "$(printf '%s\n' "$out" | sed -n 's/^SP_REPO_ABSENT=//p' | head -1)"

# THE POSITIVE CONTROL: the same beads, now with a readable map, return non-? counts.
out="$(run_repo_labels)"
nowant "readable map: SP_REPO_UNMAPPED is not ?" "SP_REPO_UNMAPPED=?" "$out"
nowant "readable map: SP_REPO_ABSENT is not ?"   "SP_REPO_ABSENT=?"   "$out"

echo
printf 'test-cockpit-repo-labels: %d ok, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
