#!/usr/bin/env bash
#
# test-cockpit-sweep.sh — SP_SWEEP_AGE renders the applied-ledger freshness correctly.
#
#   ./test-cockpit-sweep.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# cockpit.sh now emits SP_SWEEP_AGE (seconds since the newest entry in applied.jsonl) into
# the snapshot. health.sh renders it on the OPS line beside never-fired and recurred.
#
# The metric exists to make a stopped sweep distinguishable from a quiet one. Without it,
# removing the routine sweep bead (sp-z93c) creates a blind spot: a sweep that has not run
# for six hours and a sweep that ran three minutes ago look identical.
#
# THREE ASSERTIONS:
#   1. A fresh ledger entry → SP_SWEEP_AGE is a small, non-? number.
#   2. A missing / empty ledger → SP_SWEEP_AGE=? (sweep never ran, distinct from 0).
#   3. A stale backdated entry → SP_SWEEP_AGE is large (proven by numerical comparison).
#
# THE POSITIVE CONTROL IS A REAL NEGATIVE. Every assertion that a probe returns `?` is
# preceded, in the same fixture, by the same probe returning a real number — so a probe
# that always returns `?` fails the positive half, and a probe that never returns `?`
# fails the negative half. Both halves are required (law-absence-needs-a-positive-control).
#
# A REAL `bd` ON A THROWAWAY DATABASE. The probe reads `bd memories --json` from the shelf
# (for the never-fired count), so the fixture must hold a real database; the ledger itself
# is a plain JSONL file controlled entirely by the test.
#
# covers: spira/cockpit.sh spira/sop.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-cockpit-sweep.sh"

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-cockpit-sweep
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up sop || { echo "test-cockpit-sweep: could not build fixture database"; exit 1; }

RUN="$TMP/run"; mkdir -p "$RUN"
LEDGER="$TMP/ledger/applied.jsonl"; mkdir -p "$(dirname "$LEDGER")"

# cockpit.sh sops — just the SOP section (which includes SP_SWEEP_AGE), not the full probe.
# The seam exists for this purpose: it is the same function probe() calls.
run_sops() {    # run_sops [env KEY=val ...] — extra env entries are prepended before bash
    env -i PATH="$PATH" HOME="$HOME" LC_ALL=C.UTF-8 \
        SPIRA_PATH="${SPIRA_PATH:-}" SPIRA_CONF="$TMP/no.conf" \
        SPIRA_HOME="$HERE" SPIRA_REPO="$TMP" SPIRA_RUN="$RUN" \
        SPIRA_DB="$SPIRA_DB" SPIRA_REPO_MAP="$TMP/no-map" \
        SPIRA_GOAL=sp-test SPIRA_FAYTHS=t \
        SPIRA_SOP_LEDGER="$LEDGER" \
        "$@" \
        bash "$HERE/cockpit.sh" sops 2>/dev/null
}

# Write a ledger entry directly — the cockpit probe reads the file, not a bead.
ledger_entry() {    # ledger_entry <sop-key> <epoch>
    local k="$1" ep="$2"
    local ts; ts="$(date -u -d "@$ep" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || ts="1970-01-01T00:00:00Z"
    printf '{"ts":"%s","epoch":%s,"sop":"%s","bead":"sp-fixture","check":"pass","held":"yes","actor":"test","shelf":"ok","note":"ok","why":""}\n' \
        "$ts" "$ep" "$k" >> "$LEDGER"
}

# ======================================================================================
echo
echo "missing ledger — SP_SWEEP_AGE=? (sweep never ran):"

# No ledger file exists yet; the probe must render ? rather than 0 — "never ran" must look
# different from "ran and found nothing" (law-arm-before-you-retire).
out="$(run_sops)"
want   "missing ledger: SP_SWEEP_AGE=?"    "SP_SWEEP_AGE=?" "$out"
nowant "missing ledger: not a number"      "SP_SWEEP_AGE=0" "$out"

# ======================================================================================
echo
echo "empty ledger — SP_SWEEP_AGE=? (file exists but no passes recorded):"

touch "$LEDGER"
out="$(run_sops)"
want   "empty ledger: SP_SWEEP_AGE=?"   "SP_SWEEP_AGE=?" "$out"
nowant "empty ledger: not a number"     "SP_SWEEP_AGE=0" "$out"

# ======================================================================================
echo
echo "fresh ledger entry — SP_SWEEP_AGE is a small positive number:"

now_ep="$(date +%s)"
ledger_entry "sop-spira-sweep" "$now_ep"

out="$(run_sops)"
nowant "fresh entry: SP_SWEEP_AGE is not ?"  "SP_SWEEP_AGE=?" "$out"
# The age is "now minus now" — must be a non-negative integer less than 60 seconds.
sweep_age="$(grep 'SP_SWEEP_AGE=' <<< "$out" | sed 's/SP_SWEEP_AGE=//')"
if [[ "$sweep_age" =~ ^[0-9]+$ ]] && [ "$sweep_age" -lt 60 ]; then
    ok "fresh entry: SP_SWEEP_AGE is a small number ($sweep_age)"
else
    bad "fresh entry: SP_SWEEP_AGE should be <60" "got [$sweep_age]"
fi

# ======================================================================================
echo
echo "backdated entry — SP_SWEEP_AGE is large (stale sweep):"

# Write an entry from two hours ago — the probe should report age ~7200s.
old_ep=$(( now_ep - 7200 ))
ledger_entry "sop-spira-sweep" "$old_ep"

# The NEWEST entry is still the recent one written above, so re-truncate and write only old.
> "$LEDGER"
ledger_entry "sop-spira-sweep" "$old_ep"

out="$(run_sops)"
nowant "backdated entry: SP_SWEEP_AGE is not ?" "SP_SWEEP_AGE=?" "$out"
sweep_age="$(grep 'SP_SWEEP_AGE=' <<< "$out" | sed 's/SP_SWEEP_AGE=//')"
if [[ "$sweep_age" =~ ^[0-9]+$ ]] && [ "$sweep_age" -ge 7000 ]; then
    ok "backdated entry: SP_SWEEP_AGE is large ($sweep_age ≥ 7000)"
else
    bad "backdated entry: SP_SWEEP_AGE should be ≥7000" "got [$sweep_age]"
fi

# POSITIVE CONTROL FOR STALE: re-add a fresh entry — the age should shrink back.
ledger_entry "sop-spira-sweep" "$now_ep"
out_fresh="$(run_sops)"
sweep_age_fresh="$(grep 'SP_SWEEP_AGE=' <<< "$out_fresh" | sed 's/SP_SWEEP_AGE=//')"
if [[ "$sweep_age_fresh" =~ ^[0-9]+$ ]] && [ "$sweep_age_fresh" -lt 60 ]; then
    ok "newest-wins: fresh entry after old one gives small age ($sweep_age_fresh)"
else
    bad "newest-wins: expected <60 after adding fresh entry" "got [$sweep_age_fresh]"
fi

# ======================================================================================
echo
echo "POSITIVE CONTROL: broken shelf renders SP_SWEEP_AGE=? not a number:"

# A nonexistent database makes bdjson memories return the empty string; the probe must
# render ? rather than 0 or a stale reading.
out="$(run_sops env SPIRA_DB="$TMP/no-such-db")"
want   "broken shelf: SP_SWEEP_AGE=?"    "SP_SWEEP_AGE=?" "$out"
nowant "broken shelf: not 0 or number"   "SP_SWEEP_AGE=0" "$out"

# THE POSITIVE CONTROL FOR THAT: the same ledger against the GOOD db still returns a number.
out_good="$(run_sops)"
nowant "good db: SP_SWEEP_AGE is not ?" "SP_SWEEP_AGE=?" "$out_good"

# ======================================================================================
echo
echo "POSITIVE CONTROL: unreadable ledger (directory in place of file) renders ? not 0:"

mkdir -p "$TMP/dir-not-file.jsonl"
out="$(run_sops env SPIRA_SOP_LEDGER="$TMP/dir-not-file.jsonl")"
want   "unreadable ledger: SP_SWEEP_AGE=?" "SP_SWEEP_AGE=?" "$out"
nowant "unreadable ledger: not a number"   "SP_SWEEP_AGE=0" "$out"

# THE POSITIVE CONTROL FOR THAT: same db with the GOOD ledger still returns a number.
out_good2="$(run_sops)"
nowant "good ledger: SP_SWEEP_AGE is not ?" "SP_SWEEP_AGE=?" "$out_good2"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
