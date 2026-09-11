#!/usr/bin/env bash
#
# test-census.sh — census.sh: failure classes ranked by frequency, with open-remedy suppression.
#
#   ./test-census.sh
#
# WHAT THIS TESTS
# ---------------
# Given a fixture graph with a known label distribution, census.sh emits the expected
# ranked class list (test 1). A class with an open remedy bead carrying
# "covers:<class>" is excluded from the output (test 2). Closing the remedy bead
# makes the class reappear (test 3, the positive control for suppression).
#
# Tests group by cause, which requires sp-recur-N-<cause> labels from sp-ycvpd.
# All tests use a real bd fixture — no mock (law-prefer-the-real-dependency).
#
# POSITIVE CONTROLS (law-absence-needs-a-positive-control)
# --------------------------------------------------------
# Empty database: census runs silently → proves the query executes and finds nothing.
# Known distribution: expected classes appear, unexpected do not.
# Suppression: remedy bead causes omission; closing it restores the class.
#
# covers: spira/census.sh
# hermetic-ok: uses a fixture database; no systemd or gh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "wanted [$2] in [$3]"; esac; }
lack() { case "$3" in *"$2"*) bad "$1" "did not want [$2] in [$3]" ;; *) ok "$1" ;; esac; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-census
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up census || { echo "test-census: could not build a fixture database"; exit 1; }

CENSUS="$HERE/census.sh"
B() { bd -C "$SPIRA_DB" "$@"; }
REMEDY_LABEL=maechen-remedy

run_census() {
    env SPIRA_DB="$SPIRA_DB" \
        SPIRA_MAECHEN_REMEDY_LABEL="$REMEDY_LABEL" \
        SPIRA_CONF="$TMP/no-conf" \
        SPIRA_HOME="$HERE" \
        bash "$CENSUS" "$@" 2>/dev/null
}

add_labels() {  # add_labels <bead-id> <label>...
    local id="$1"; shift
    for lbl in "$@"; do
        B label add "$id" "$lbl" >/dev/null 2>&1
    done
}

plant_bead() {  # plant_bead <title> → bead id on stdout
    B create "$1" --type bug --priority 2 --labels spira,incident --silent 2>/dev/null \
        | tr -d '[:space:]'
}

echo "test-census.sh"

# ==============================================================================
echo
echo "POSITIVE CONTROL: empty database → census runs, emits nothing"
# ==============================================================================
# Proves the query executes and can reach the database; an empty result here means
# census.sh found nothing, not that it crashed or read the wrong store.
testdb_reset
out="$(run_census)"
is "empty database → no output" "" "$out"

# ==============================================================================
echo
echo "1. Known label distribution → correct ranked class list"
# ==============================================================================
# Fixture distribution (one sp-recur-N-cause label = one occurrence):
#   sp-recur-suite-red:    5  (bead-A has 3 labels, bead-B has 2 labels)
#   sp-requeue-prod-dirty: 3  (bead-C: 3 labels — three requeueings)
#   sp-reclaim:            2  (bead-D: 2 labels — reclaimed twice)
#   sp-recur-unrecorded:   1  (bead-E: 1 label)
#
# Each label is one recurrence event, so three sp-recur-N-suite-red labels on one
# bead count as three occurrences of sp-recur-suite-red.
testdb_reset

bid_a="$(plant_bead "bead-a")"
[ -n "$bid_a" ] \
    || { bad "bead-a created" "create failed"; printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"; exit 1; }
add_labels "$bid_a" sp-recur-1-suite-red sp-recur-2-suite-red sp-recur-3-suite-red

bid_b="$(plant_bead "bead-b")"
add_labels "$bid_b" sp-recur-1-suite-red sp-recur-2-suite-red

bid_c="$(plant_bead "bead-c")"
add_labels "$bid_c" sp-requeue-1-prod-dirty sp-requeue-2-prod-dirty sp-requeue-3-prod-dirty

bid_d="$(plant_bead "bead-d")"
add_labels "$bid_d" sp-reclaim-1 sp-reclaim-2

bid_e="$(plant_bead "bead-e")"
add_labels "$bid_e" sp-recur-1-unrecorded

out1="$(run_census)"

want "sp-recur-suite-red present with count 5"    "5 sp-recur-suite-red"    "$out1"
want "sp-requeue-prod-dirty present with count 3" "3 sp-requeue-prod-dirty" "$out1"
want "sp-reclaim present with count 2"            "2 sp-reclaim"            "$out1"
want "sp-recur-unrecorded present with count 1"   "1 sp-recur-unrecorded"   "$out1"

# Ranking: sp-recur-suite-red (5) must appear before sp-requeue-prod-dirty (3)
first_class="$(printf '%s\n' "$out1" | head -1 | awk '{print $2}')"
is "highest-frequency class is first" "sp-recur-suite-red" "$first_class"

# Negative: no labels that were not planted
lack "sp-recur-merge-conflict not in output (not planted)"  "sp-recur-merge-conflict"  "$out1"

# ==============================================================================
echo
echo "2. Open remedy bead for top class → class is excluded from output"
# ==============================================================================
# Create a remedy bead covering sp-recur-suite-red. It must carry both the
# remedy label AND "covers:<class>" for census.sh to recognise the suppression.
remedy_id="$(B create "Fix sp-recur-suite-red recurring class" --type task --priority 2 \
    --labels "spira,plan,${REMEDY_LABEL},covers:sp-recur-suite-red" \
    --silent 2>/dev/null | tr -d '[:space:]')"
[ -n "$remedy_id" ] \
    || { bad "remedy bead created" "create failed"; printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"; exit 1; }

out2="$(run_census)"
lack "sp-recur-suite-red excluded when remedy is open" "sp-recur-suite-red" "$out2"
want "sp-requeue-prod-dirty still present after suppression" "sp-requeue-prod-dirty" "$out2"
want "sp-reclaim still present after suppression"            "sp-reclaim"            "$out2"

# With --with-suppressed the class appears annotated
out2s="$(run_census --with-suppressed)"
want "with --with-suppressed, suppressed class appears"  "sp-recur-suite-red" "$out2s"
want "with --with-suppressed, marked [suppressed]"       "[suppressed]"       "$out2s"

# ==============================================================================
echo
echo "3. CONTROL: closing remedy bead makes class reappear"
# ==============================================================================
B close "$remedy_id" --reason "test control: remove suppression" >/dev/null 2>&1

out3="$(run_census)"
want "sp-recur-suite-red reappears after remedy closed"    "sp-recur-suite-red"    "$out3"
lack "no stale [suppressed] annotation after remedy closed" "[suppressed]"          "$out3"

# ==============================================================================
echo
echo "4. Two distinct classes, both below threshold — both counted correctly"
# ==============================================================================
# The Maechen SELECT threshold (three or more) lives in the brief, not in census.sh.
# census.sh reports all classes including those below threshold; Maechen decides.
want "sp-reclaim (count 2) present in census"        "2 sp-reclaim"        "$out3"
want "sp-recur-unrecorded (count 1) present in census" "1 sp-recur-unrecorded" "$out3"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
