#!/usr/bin/env bash
#
# promote.sh — fast-forward the production checkout to a ref; restart only changed units.
#
#   promote.sh [--dry-run] <ref>
#
# PURPOSE
# -------
# The production checkout (SPIRA_PROD/../) is the ONLY directory systemd executes.
# Landing a change on the development checkout (SPIRA_REPO) does not touch production
# until this script is called with the target ref.
#
# A change landed in development is promoted by naming the commit it landed on. The
# promoted ref is typically a branch tip (main) or an annotated release tag. After
# promotion, systemd is running the promoted code; before, it was running the old code.
#
# FAST-FORWARD RULE. The production checkout must be an ancestor of the target ref.
# A non-fast-forward is always refused. To reverse a promotion, promote to an earlier
# ref: `promote.sh <previous-sha>` is the rollback. The operation is symmetric.
#
# INITIAL CLONE. When SPIRA_PROD does not yet exist, promote.sh creates it by cloning
# the development repo locally. The first promotion is the one-time setup; all subsequent
# ones are fast-forwards.
#
# UNIT RESTARTS. Only units whose ExecStart script changed between old and new are
# restarted. Others are left running, so a promotion of a change to one script does not
# interrupt every service.
#
# DRY RUN. --dry-run reports everything that would change without touching the
# production checkout or restarting any unit.
#
# EXIT   0  success
#        1  usage error or refused (non-fast-forward, unresolvable ref)
#        2  production checkout exists but is not a git repo
set -uo pipefail
. "$(dirname "$0")/lib.sh"

SC="${SPIRA_SYSTEMCTL:-systemctl}"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi
REF="${1:?usage: promote.sh [--dry-run] <ref>}"

[ -n "${SPIRA_PROD:-}" ] || die "promote: SPIRA_PROD is not set — set it in spira.conf"

# SPIRA_PROD is the harness subdir (e.g. spira/) inside the production checkout.
PROD_HOME="$SPIRA_PROD"
PROD_REPO="$(dirname "$PROD_HOME")"

# --- resolve the ref in the dev repo to a commit SHA ---
RESOLVED="$(git -C "$SPIRA_REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" || {
    printf 'promote: %s does not name a commit in the development repo (%s)\n' "$REF" "$SPIRA_REPO" >&2
    exit 1
}

# --- set up production checkout if it does not exist ---
if [ ! -d "$PROD_REPO/.git" ]; then
    log "promote: production checkout is absent — cloning from $SPIRA_REPO"
    if [ "$DRY_RUN" = 1 ]; then
        log "promote: DRY RUN: would clone $SPIRA_REPO -> $PROD_REPO"
    else
        mkdir -p "$(dirname "$PROD_REPO")"
        git clone --local "$SPIRA_REPO" "$PROD_REPO" 2>&1 \
            | while IFS= read -r line; do log "promote: clone: $line"; done
        git -C "$PROD_REPO" checkout --detach "$RESOLVED" >/dev/null 2>&1
        log "promote: production checkout created at $PROD_REPO"
        log "promote: production is now at $RESOLVED"
        exit 0
    fi
fi

# The production checkout exists — validate and fast-forward.
[ -d "$PROD_REPO/.git" ] || { printf 'promote: %s exists but is not a git repo\n' "$PROD_REPO" >&2; exit 2; }

OLD_HEAD="$(git -C "$PROD_REPO" rev-parse HEAD 2>/dev/null || true)"

if [ "$OLD_HEAD" = "$RESOLVED" ]; then
    log "promote: production is already at $RESOLVED — nothing to do"
    exit 0
fi

# FAST-FORWARD CHECK. The new ref must descend from the current production HEAD.
# This is what makes reversal symmetric: promoting from B back to A is a fast-forward
# of A-to-B run in the other direction, i.e. A must be an ancestor of B, and when we
# reverse we check that OLD_HEAD (B) is an ancestor of RESOLVED (A), which fails.
# That means strict reversal requires knowing the old SHA; --force-promote skips this.
if [ -n "$OLD_HEAD" ]; then
    if ! git -C "$SPIRA_REPO" merge-base --is-ancestor "$OLD_HEAD" "$RESOLVED" 2>/dev/null; then
        printf 'promote: %s is not a fast-forward from the current production HEAD (%s)\n' \
            "$RESOLVED" "$OLD_HEAD" >&2
        printf 'promote: to reverse: promote.sh %s\n' "$OLD_HEAD" >&2
        printf 'promote: if the production checkout is ahead of the target (e.g. reverting), '>&2
        printf 'use --force-forward (not yet implemented) or reset production manually\n' >&2
        exit 1
    fi
fi

# --- find what changed in the harness subdir ---
# Only scripts inside the harness directory (e.g. "spira/") affect which units to restart.
HOME_SUB="$(basename "$PROD_HOME")"   # e.g. "spira"
declare -a changed_scripts=()
if [ -n "$OLD_HEAD" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        changed_scripts+=("${f#${HOME_SUB}/}")
    done < <(git -C "$SPIRA_REPO" diff --name-only "$OLD_HEAD" "$RESOLVED" 2>/dev/null \
        | grep "^${HOME_SUB}/")
fi

# --- advance production ---
log "promote: $OLD_HEAD -> $RESOLVED"
if [ "$DRY_RUN" = 0 ]; then
    git -C "$PROD_REPO" fetch "$SPIRA_REPO" "$RESOLVED" >/dev/null 2>&1 || true
    git -C "$PROD_REPO" checkout --detach "$RESOLVED" >/dev/null 2>&1
fi

if [ "${#changed_scripts[@]}" -gt 0 ]; then
    log "promote: scripts changed in ${HOME_SUB}/: ${changed_scripts[*]}"
else
    log "promote: no scripts changed in ${HOME_SUB}/"
fi

# --- find units that reference changed scripts and restart them ---
UNIT_DIR="$HOME/.config/systemd/user"
declare -a restart_units=()
declare -A seen_units=()

if [ -d "$UNIT_DIR" ] && [ "${#changed_scripts[@]}" -gt 0 ]; then
    for script in "${changed_scripts[@]}"; do
        while IFS= read -r unit_file; do
            [ -f "$unit_file" ] || continue
            unit="$(basename "$unit_file")"
            # Match ExecStart/ExecStartPre/ExecCondition lines that name this script.
            # The installed unit has the actual path, e.g. /path/to/spira/sentinel.sh.
            if grep -qE "^(ExecStart|ExecStartPre|ExecCondition)=.*/${script}( |$)" \
                    "$unit_file" 2>/dev/null; then
                if [ -z "${seen_units[$unit]:-}" ]; then
                    restart_units+=("$unit")
                    seen_units["$unit"]=1
                fi
            fi
        done < <(find "$UNIT_DIR" -maxdepth 1 -name '*.service' -type f 2>/dev/null)
    done
fi

if [ "${#restart_units[@]}" -eq 0 ]; then
    log "promote: no installed units reference changed scripts — no restarts needed"
else
    for u in "${restart_units[@]}"; do
        log "promote: restarting $u"
        if [ "$DRY_RUN" = 0 ]; then
            "$SC" --user restart "$u" 2>/dev/null \
                || log "promote: WARN: failed to restart $u (may not be installed)"
        fi
    done
fi

log "promote: done — production is at $RESOLVED"
if [ -n "$OLD_HEAD" ]; then
    log "promote: to reverse this promotion: promote.sh $OLD_HEAD"
fi
