#!/usr/bin/env bash
# beads-push.sh — push every beads database that has a configured Dolt remote.
#
# WHY THIS EXISTS. Three databases here had a real, private remote wired by a one-shot
# setup script — and nothing ever pushed to them again. All three last received data
# within thirty-six seconds of each other, which is the signature of a setup script and
# not of a backup. A configured remote that nothing pushes is worse than no remote,
# because it looks like a backup on inspection and answers "is this backed up?" with a yes.
#
# A JSONL export is the other half of a backup and covers different ground: it is diffable
# and readable without any tooling, but carries only the issues table and the memories.
# This job carries the Dolt store itself — branches, history, working set. Keep whatever
# repository either lands in PRIVATE; a beads database is never public.
#
# WHAT IT DOES NOT DO. It never creates a repository and never wires a remote. A database
# with no remote is skipped silently, because opting one in is a deliberate act.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/spira" && pwd -P)/conf.sh"
export BEADS_NO_AUTO_IMPORT=1
spira_require bd || exit 1

TOWN="$SPIRA_TOWN"
ok=0; fail=0; skip=0

# Spira first: it is the one this repo's own plan depends on. The predecessor town and its
# rigs are appended only when one is configured — a colleague has none, and a glob over an
# empty prefix would walk the filesystem root.
for dir in "$SPIRA_DB" ${TOWN:+"$TOWN" "$TOWN"/*/}; do
    dir="${dir%/}"
    [ -d "$dir/.beads" ] || continue
    # deacon/ resolves to the town database; pushing both would push the same store twice.
    [ "$(basename "$dir")" = "deacon" ] && continue
    grep -q '^sync.remote:' "$dir/.beads/config.yaml" 2>/dev/null || { skip=$((skip+1)); continue; }

    name="$(basename "$dir")"
    [ "$dir" = "$TOWN" ] && name="town"

    # --remote beads is the name make-beads-repo.sh wires alongside origin.
    out=$(timeout 900 bd -C "$dir" dolt push --remote beads 2>&1)
    if grep -q 'Push complete' <<<"$out"; then
        echo "beads-push: $name OK"
        ok=$((ok+1))
    else
        # Loud, and with the reason attached: a silent push failure is the exact
        # shape of the problem this script was written to fix.
        echo "beads-push: $name FAILED — $(tail -2 <<<"$out" | tr '\n' ' ')" >&2
        fail=$((fail+1))
    fi
done

echo "beads-push: $(date -u +%Y-%m-%dT%H:%M:%SZ) — $ok pushed, $fail failed, $skip without a remote"
[ "$fail" -eq 0 ]
