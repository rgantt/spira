#!/usr/bin/env bash
#
# gate-check.sh — evaluate open gh:run gates and resolve those whose CI has passed.
#
#   gate-check.sh
#
# THE TWO STEPS, IN ORDER.
#
# 1. DISCOVER: for every pr-mode repository in the repo-map, call `bd gate discover`
#    from within that repository's directory. discover calls `gh run list` using the
#    repository's own remote, so it queries the right GitHub account and matches on the
#    correct branch and commit SHA — not on this harness's runs. A gate whose branch
#    does not exist in the repository is not matched.
#
#    A push- or hold-mode repository never opens a pull request, so no CI run exists to
#    discover for it. Calling discover there wastes a gh round-trip and risks matching a
#    coincidentally named branch in the harness repo.
#
# 2. CHECK: `bd gate check --type=gh:run` evaluates every open gh:run gate. For each
#    gate that has an await_id, it calls `gh run view <id> --repo <metadata.repo>` —
#    the --repo flag comes from the gate's own metadata, so a run from the wrong
#    repository cannot resolve a gate for the right one.
#
# CALLED FROM A TIMER, NOT THE SENTINEL. The sentinel's bespoke awaiting-ci sweep has
# been removed; this script is its replacement. It runs on spira-gate-check.timer at
# the same two-minute cadence, independently of a sentinel pass.

# covers: spira/gate-check.sh spira/sentinel.sh spira/aeon.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
spira_conf

bdq() { "${SPIRA_BD:-bd}" -C "$SPIRA_DB" "$@"; }

# STEP 1: DISCOVER — iterate pr-mode repositories and call discover from within each one.
#
# ONLY PR-MODE REPOS. push merges directly and hold leaves the branch for a human; in both
# cases the landing gate is the only gate and no CI run exists to discover. Running discover
# against those repos would query the wrong GitHub context.
while IFS= read -r name; do
    [ "$(repo_land "$name")" = pr ] || continue
    repo="$(repo_root "$name" 2>/dev/null)" || continue
    [ -d "$repo/.git" ] || continue
    # Call discover from within the repository so gh run list uses its remote.
    ( cd "$repo" && bdq gate discover ) 2>/dev/null || true
done < <(repo_names)

# STEP 2: CHECK — evaluate all open gh:run gates.
#
# bd gate check uses metadata.repo on each gate to call `gh run view <id> --repo <org/repo>`,
# so this call is correct regardless of the current directory.
bdq gate check --type=gh:run 2>&1 || true
