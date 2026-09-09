#!/usr/bin/env bash
#
# pre-commit-guard.sh — refuse staged paths that were dirty before this aeon started.
#
# Installed into a per-worktree hooks dir by aeon.sh. Reads a snapshot written before the
# aeon's session began from the same git dir (git rev-parse --git-dir). An empty or absent
# snapshot means the worktree was clean at start and the hook is a no-op.
#
# THE DEFECT THIS PREVENTS. `git add -A` in a shared checkout commits whatever happens to
# be dirty — archivist drafts, operator edits, any uncommitted change from any other
# process. That manufactures false landing evidence: a commit names the bead but carries
# nothing the aeon wrote. The hook is the mechanism; it turns "git add -A is a bad idea"
# from an advisory into something git enforces.
#
# OVERRIDE. A fence is a polite refusal, not a wall. Set SPIRA_ALLOW_DIRTY_STAGE=1 in the
# environment before `git commit` to bypass this check when an aeon legitimately needs to
# stage a file it did not itself create.
[ "${SPIRA_ALLOW_DIRTY_STAGE:-}" = 1 ] && exit 0

snap="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)/spira-dirty-before"
[ -f "$snap" ] && [ -s "$snap" ] || exit 0

bad=""
while IFS= read -r path; do
    if grep -qxF -- "$path" "$snap"; then
        bad="${bad}  ${path}
"
    fi
done < <(git diff --cached --name-only 2>/dev/null)

[ -n "$bad" ] || exit 0

printf 'spira: refusing commit — staged paths were dirty before this aeon started:\n%s' "$bad" >&2
printf 'Stage only paths you wrote: git add -- <specific-path>\n' >&2
printf 'Override (only when necessary): SPIRA_ALLOW_DIRTY_STAGE=1 git commit ...\n' >&2
exit 1
