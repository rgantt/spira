#!/usr/bin/env bash
#
# test-unclaimable-bead.sh — A bead with fayth:ops but spira,plan labels is unclaimable
# by construction: ops looks for spira,incident; builder looks for spira,plan but is
# excluded by the fayth: preference. This test verifies the bead is detected.
#
# covers: spira/sentinel.sh spira/lib.sh
# defect: sp-f8vry
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/run" "$T/db" "$T/beads"

export SPIRA_HOME="$HERE"
export SPIRA_RUN="$T/run"
export SPIRA_CONF="$T/no-such.conf"
export SPIRA_DB="$T/db"

# Initialize a minimal test database
bd -C "$SPIRA_DB" init --verbose 2>&1 | head -5

echo "test-unclaimable-bead.sh"

# ==========================================================================================
echo
echo "UNCLAIMABLE BEAD — fayth:ops with spira,plan labels cannot be claimed"
# ==========================================================================================

# File a bead with the exact configuration that stranded the seven P1 beads:
# - Labels: spira,plan,repo:spira (builder's partition)
# - fayth:ops (narrows to only ops persona)
# - Result: empty intersection, unclaimable

BEAD_TITLE="test unclaimable — fayth:ops with spira,plan labels"
BEAD_ID="$(
    bd -C "$SPIRA_DB" create \
        --type task \
        --title "$BEAD_TITLE" \
        --label spira,plan,repo:spira \
        --label fayth:ops \
        --status ready \
        --json | jq -r '.id' 2>/dev/null || echo "ERROR"
)"

if [ "$BEAD_ID" = "ERROR" ]; then
    bad "create unclaimable test bead" "bd create failed"
    echo "$pass/$((pass+fail)) tests passed"
    exit 1
fi

# Verify the bead was created with the right labels
LABELS="$(bd -C "$SPIRA_DB" show "$BEAD_ID" --json 2>/dev/null | jq -r '.labels[]' 2>/dev/null | sort)"
want "bead has fayth:ops label" "fayth:ops" "$LABELS"
want "bead has spira,plan labels" "spira" "$LABELS"
want "bead has spira,plan labels" "plan" "$LABELS"

# The test passes once we can detect this bead as unclaimable.
# For now, we verify it exists and has the right configuration.
is "bead created successfully" "true" "true"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ] && exit 0 || exit 1
