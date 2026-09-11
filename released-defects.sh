#!/usr/bin/env bash
# released-defects.sh — enumerate bugs that reached the base branch before their fix.
#
# Output: one line per released defect, formatted as:
#   <bead-id>: [status]
#
# A released defect is a bug in the spira scope that closed and has evidence of landing
# on the base branch (most commonly: a commit in the close reason).

set -euo pipefail

SPIRA_DB="${SPIRA_DB:?}"

# Query closed bugs in the spira scope
$SPIRA_BD -C "$SPIRA_DB" list --status closed --type bug --label spira --json 2>/dev/null | grep -v warning | \
  jq -r '.[] | "\(.id): \(if .close_reason then "released (fix: " + (.close_reason | split("\n")[0]) + "...)" else "released" end)"'

exit 0
