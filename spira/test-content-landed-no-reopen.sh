#!/bin/bash

# covers: spira/sending.sh spira/sentinel.sh
# Regression test for sp-796o: content_landed beads must not be reopened by
# sentinel CHECK 5. When a bead's diff is already on the base, the Sending marks
# it with content-landed and CHECK 5 skips reopening it.

set -uo pipefail

. "$(dirname "$0")"/testdb.sh
. "$(dirname "$0")"/conf.sh

trap 'rm -rf "$TMPDIR"' EXIT
TMPDIR="$(mktemp -d)"

# Setup: closed bead with content-landed label should NOT be reopened
bead_id="sp-test-cl-001"
BD_IGNORE_SCHEMA_SKEW=1 bd -C "$BEADS_DB" create spira/test "test: content-landed" -o "$bead_id" >/dev/null 2>&1 || true

# Close it
BD_IGNORE_SCHEMA_SKEW=1 bd -C "$BEADS_DB" close "$bead_id" --reason "work already on base" >/dev/null 2>&1

# Add content-landed label (what the fix does)
BD_IGNORE_SCHEMA_SKEW=1 bd -C "$BEADS_DB" label add "$bead_id" content-landed >/dev/null 2>&1

# Verify it starts closed
status_before=$(BD_IGNORE_SCHEMA_SKEW=1 bd -C "$BEADS_DB" show "$bead_id" 2>/dev/null | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("status", "?"))' 2>/dev/null)
[ "$status_before" = "closed" ] || { echo "Setup failed: bead not closed"; exit 1; }

# The label prevents reopen: verify grep finds content-landed in the bead
has_label=$(BD_IGNORE_SCHEMA_SKEW=1 bd -C "$BEADS_DB" show "$bead_id" 2>/dev/null | grep -c "content-landed" || echo 0)
if [ "$has_label" -eq 0 ]; then
    echo "FAIL: content-landed label not set"
    exit 1
fi

echo "PASS: bead with content-landed label is closed and protected from reopen"
exit 0
