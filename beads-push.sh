#!/usr/bin/env bash
# beads-push.sh — push Spira's beads database to its configured Dolt remote.
#
# WHY THIS EXISTS. A one-shot setup script wired real, private GitHub remotes onto several
# beads databases and nothing ever pushed to them again — measured 2026-09-04, three of them
# had last received data on 2026-09-02 within 36 seconds of each other, which is the
# signature of a setup script and not of a backup. A configured remote that nothing pushes
# is worse than no remote, because it looks like a backup on inspection and answers "is this
# backed up?" with a yes it has not earned.
#
# WHY SPIRA ALONE. Spira is the only beads database anything still writes. The predecessor
# harness's stores are frozen, and pushing a store nothing writes is churn that looks like a
# live backup while carrying no new data; their final contents already reached their remotes.
#
# The JSONL export is the other half of a backup and covers different ground: it is diffable
# and readable without any tooling, but carries only the issues table and the memories.
# This job carries the Dolt store itself — branches, history, working set. Keep whatever
# repository either lands in PRIVATE; a beads database is never public.
#
# WHAT IT DOES NOT DO. It never creates a repository and never wires a remote. Opting a
# database in is a deliberate act, so a database with no remote is reported and skipped
# rather than treated as a failure — a clean clone has none, and a timer that fails every
# six hours on a box that was never opted in is a false alert.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/spira" && pwd -P)/conf.sh"
export BEADS_NO_AUTO_IMPORT=1
spira_require bd || exit 1

DB="$SPIRA_DB"
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ ! -d "$DB/.beads" ]; then
    echo "beads-push: $stamp — no beads database at $DB" >&2
    exit 1
fi

# --remote beads is the name make-beads-repo.sh wires alongside origin.
if ! grep -q '^sync.remote:' "$DB/.beads/config.yaml" 2>/dev/null; then
    echo "beads-push: $stamp — no Dolt remote configured; nothing to push"
    exit 0
fi

out=$(timeout 900 bd -C "$DB" dolt push --remote beads 2>&1)
if grep -q 'Push complete' <<<"$out"; then
    echo "beads-push: $stamp — spira OK"
    exit 0
fi

# Loud, and with the reason attached: a silent push failure is the exact shape of the
# problem this script was written to fix.
echo "beads-push: $stamp — spira FAILED — $(tail -2 <<<"$out" | tr '\n' ' ')" >&2
exit 1
