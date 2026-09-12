#!/usr/bin/env bash
#
# deploy.sh — deployment controller: review a release unit and deploy it to production.
#
#   deploy.sh [--dry-run] <release-tag>
#
# PURPOSE
# -------
# deploy.sh is the ONLY component that may advance the production checkout.
# landing.sh lands work onto the development base branch and stops there.
# deploy.sh reviews a release unit and, if the reviewer clears it, promotes it
# to production via promote.sh. Exactly one publisher exists because exactly one
# component calls promote.sh in the automated pipeline.
#
# THE BOOTSTRAP CONSTRAINT (load-bearing)
# ----------------------------------------
# deploy.sh must not deploy itself. A controller that ships a broken controller
# cannot un-ship it — the thing that would have noticed is the thing that broke,
# and the failure is silent. If the release unit's aggregate diff touches this
# file (spira/deploy.sh), the unit is refused and a human must promote it.
# Small, boring, and rarely changed is what makes the bootstrap constraint hold.
#
# FLOW
#   1. Validate the release tag and resolve its managed repository.
#   2. Compute the unit's aggregate diff and check for changes to deploy.sh.
#      Refuse (exit 1) if found.
#   3. Invoke review.sh <tag> for the verdict.
#      - SHIP (exit 0): call promote.sh <tag> to advance the production checkout.
#      - BLOCK (exit 1): refuse; findings are already filed as beads by review.sh.
#      - FATAL (exit 2): refuse; the unit is treated as unreviewed.
#
# REVERSIBILITY
# -------------
# A deploy is reversed by running: deploy.sh <previous-tag>
# The previous tag is recorded in the unit's tag message (prev: field).
# promote.sh enforces the fast-forward rule, so reversal is a two-step: resolve
# the previous SHA and pass it directly to promote.sh.
#
# DRY RUN
# -------
# --dry-run reports what would happen without touching the production checkout.
# review.sh is still invoked (and still files beads for BLOCK findings) so the
# review record is accurate even in a dry run.
#
# EXIT   0  deployed (or DRY RUN: would deploy)
#        1  refused — BLOCK verdict, or unit contains changes to deploy.sh itself
#        2  fatal — reviewer failed, usage error, or tag not found
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi
TAG="${1:-}"
[ -n "$TAG" ] || { printf 'usage: deploy.sh [--dry-run] <release-tag>\n' >&2; exit 2; }

REVIEW_SH="$HERE/review.sh"
PROMOTE_SH="$HERE/promote.sh"
[ -x "$REVIEW_SH" ] || { printf 'deploy: review.sh not found at %s\n' "$REVIEW_SH" >&2; exit 2; }
[ -x "$PROMOTE_SH" ] || { printf 'deploy: promote.sh not found at %s\n' "$PROMOTE_SH" >&2; exit 2; }

# --- resolve the tag to its managed repository ---
repo=""; name=""
for n in $(spira_repos); do
    r="$(repo_root "$n" 2>/dev/null)" || continue
    if git -C "$r" rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
        repo="$r"; name="$n"; break
    fi
done
[ -n "$repo" ] || {
    printf 'deploy: tag %s not found in any managed repository\n' "$TAG" >&2
    exit 2
}

# Read the tag message to locate the previous release unit.
msg="$(git -C "$repo" tag -l --format='%(contents)' "$TAG" 2>/dev/null)"
[ -n "$msg" ] || {
    printf 'deploy: %s has no embedded message — is this a release tag?\n' "$TAG" >&2
    exit 2
}

prev_tag="$(printf '%s\n' "$msg" | grep '^prev: ' | head -1 | sed 's/^prev: //')"
tag_sha="$(git -C "$repo" rev-parse "${TAG}^{commit}" 2>/dev/null)" || {
    printf 'deploy: cannot resolve commit for %s\n' "$TAG" >&2; exit 2
}

# ---- THE BOOTSTRAP CONSTRAINT -----------------------------------------------
# HOME_SUB is the harness subdir name (e.g. "spira"). SELF_PATH is the path of
# this script within the repository as it appears in `git diff --name-only`.
# Checking by path survives rebases and renames of the tag itself.
HOME_SUB="$(basename "$HERE")"
SELF_PATH="${HOME_SUB}/deploy.sh"

_self_in_diff=0
if [ -n "${prev_tag:-}" ] && [ "$prev_tag" != "(none)" ] \
   && git -C "$repo" rev-parse --verify "refs/tags/$prev_tag" >/dev/null 2>&1; then
    prev_sha="$(git -C "$repo" rev-parse "${prev_tag}^{commit}" 2>/dev/null)"
    git -C "$repo" diff --name-only "${prev_sha}..${tag_sha}" 2>/dev/null \
        | grep -qF "$SELF_PATH" && _self_in_diff=1 || true
else
    # No prior unit: compare against the empty tree — the well-known constant SHA.
    _empty_tree="$(git hash-object -t tree /dev/null 2>/dev/null \
                   || printf '4b825dc642cb6eb9a060e54bf8d69288fbee4904')"
    git -C "$repo" diff --name-only "${_empty_tree}..${tag_sha}" 2>/dev/null \
        | grep -qF "$SELF_PATH" && _self_in_diff=1 || true
fi

if [ "$_self_in_diff" = 1 ]; then
    printf 'deploy: %s contains changes to %s\n' "$TAG" "$SELF_PATH" >&2
    printf 'deploy: the deployment controller must not deploy itself\n' >&2
    printf 'deploy: this unit requires a human to promote — run: promote.sh %s\n' "$TAG" >&2
    exit 1
fi

# ---- INVOKE THE REVIEWER ----------------------------------------------------
log "deploy: reviewing release unit $TAG"

REVIEW_RC=0
verdict_raw="$("$REVIEW_SH" "$TAG" 2>/dev/null)" || REVIEW_RC=$?
# review.sh logs to stdout (lib.sh log() is intentionally stdout for the sentinel).
# The verdict line is always last; extract it to avoid matching log lines in the case
# statement below.
verdict="$(printf '%s\n' "$verdict_raw" | tail -1)"

if [ "$REVIEW_RC" = 2 ]; then
    printf 'deploy: reviewer failed for %s (exit %d) — unit NOT deployed\n' "$TAG" "$REVIEW_RC" >&2
    exit 2
fi

# review.sh prints one line: "ship" or "block". Anything else is treated as block.
case "${verdict:-}" in ship) ;; *) verdict="block" ;; esac

log "deploy: $TAG verdict=$verdict"

if [ "$verdict" = "block" ]; then
    printf 'deploy: %s is BLOCKED by the reviewer\n' "$TAG" >&2
    printf 'deploy: resolve findings (label: %s) and re-run: review.sh %s\n' \
        "$SPIRA_REVIEW_LABEL" "$TAG" >&2
    printf 'deploy: then re-run: deploy.sh %s\n' "$TAG" >&2
    exit 1
fi

# ---- PROMOTE TO PRODUCTION --------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
    log "deploy: DRY RUN: $TAG is clean — would promote to production via promote.sh"
    printf '%s\n' "$verdict"
    exit 0
fi

log "deploy: $TAG is clean — promoting to production"
"$PROMOTE_SH" "$TAG"
log "deploy: $TAG deployed to production"
printf '%s\n' "$verdict"
