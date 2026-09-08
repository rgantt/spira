#!/usr/bin/env bash
#
# test-repo-label.sh — bdq create refuses a repo: label absent from the repo map.
#
#   ./test-repo-label.sh
#
# THE DEFECT THIS PREVENTS. A bead filed with repo:spira-harness is never claimed:
# the summon-time fence catches it, but only after wasting a summon (4 burned for
# sp-nlhy, 2026-09-08). The refusal belongs at file time, before bd is called.
#
# POSITIVE CONTROL FIRST (law-absence-needs-a-positive-control). The bad-label case
# is tested before the clean-map case, confirming the check fires on a known offender.
#
# defect: sp-f9vu
# covers: spira/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant(){ [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-repo-label.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# A minimal repo map with two known entries.
MAP="$TMP/repo-map"
printf 'spira    | /srv/spira     | push | origin/main |  |\n' > "$MAP"
printf 'widget   | /srv/widget    | pr   | origin/main |  |\n' >> "$MAP"

# A stub bd that records its arguments and exits 0, so "valid label" calls reach it.
STUB_BD="$TMP/bd"
printf '#!/usr/bin/env bash\nprintf "bd-called\\n"; exit 0\n' > "$STUB_BD"
chmod +x "$STUB_BD"

# Source lib.sh with a fixture environment so it does not read the real database.
run_check() {   # run_check <label-string> -> "ok" or "refused:<stderr>"
    env -i PATH="$PATH" HOME="$TMP" \
        SPIRA_HOME="$HERE" SPIRA_REPO="$TMP/norepo" SPIRA_DB="$TMP/nodb" \
        SPIRA_REPO_MAP="$MAP" SPIRA_BD="$STUB_BD" \
        bash -c '. "$1/lib.sh"; _bdq_check_repo_label create title --labels "$2"' \
            -- "$HERE" "$1" 2>&1
}

run_bdq_create() {  # run_bdq_create <labels> -> combined stdout+stderr, exits as bdq does
    env -i PATH="$PATH" HOME="$TMP" \
        SPIRA_HOME="$HERE" SPIRA_REPO="$TMP/norepo" SPIRA_DB="$TMP/nodb" \
        SPIRA_REPO_MAP="$MAP" SPIRA_BD="$STUB_BD" BD_TIMEOUT=10 \
        bash -c '. "$1/lib.sh"; bdq create title --labels "$2"' \
            -- "$HERE" "$1" 2>&1
}

# ==========================================================================
echo
echo "POSITIVE CONTROL: bad label is refused:"
# ==========================================================================

out="$(run_check "spira,plan,repo:spira-harness" || true)"
want "bad label: error mentions the offending name" "spira-harness"  "$out"
want "bad label: error names a valid key"           "spira"          "$out"

out2="$(run_bdq_create "spira,plan,repo:spira-harness" || true)"
want "bdq create: refused for bad label"            "spira-harness"  "$out2"
nowant "bdq create: bd not called for bad label"    "bd-called"      "$out2"

# ==========================================================================
echo
echo "valid label passes through to bd:"
# ==========================================================================

out3="$(run_bdq_create "spira,plan,repo:spira" 2>&1)" || true
nowant "good label: no refusal error"  "is not in the repo map"  "$out3"
want   "good label: bd was called"     "bd-called"               "$out3"

# ==========================================================================
echo
echo "no repo: label passes through:"
# ==========================================================================

out4="$(run_bdq_create "spira,plan" 2>&1)" || true
nowant "no repo: no refusal"  "is not in the repo map"  "$out4"
want   "no repo: bd was called"  "bd-called"            "$out4"

# ==========================================================================
echo
echo "error message names ALL valid keys:"
# ==========================================================================

out5="$(run_check "repo:unknown" || true)"
want "all keys: spira present"  "spira"   "$out5"
want "all keys: widget present" "widget"  "$out5"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
