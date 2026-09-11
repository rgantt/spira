#!/usr/bin/env bash
#
# test-aeon-worktree-guard.sh — branch-guard.sh staged refuses aeon commits outside the
#                               assigned worktree; operator commits and worktree-path commits pass.
#
#   ./test-aeon-worktree-guard.sh
#
# THE DEFECT THIS GUARDS. aeon-yojimbo committed directly into the production checkout
# (/workspaces/spira-prod) rather than its assigned worktree. The commit:
#   - existed only in the production checkout, unlanded and invisible to the gate
#   - left the checkout DIVERGED from origin/main
#   - froze every promote pass that followed
#
# One stranded commit froze the whole promote path. The guard makes an out-of-worktree
# commit structurally impossible: aeon.sh exports SPIRA_WORK (the assigned path) before
# launching the session; branch-guard.sh staged reads it and refuses if the committing
# tree does not match.
#
# FOUR CASES (law-absence-needs-a-positive-control):
#   1. Aeon commits in SPIRA_WORK (the assigned worktree) → allowed.
#   2. Aeon commits in REPO (the production checkout) with SPIRA_WORK set → REFUSED.
#   3. Aeon commits in REPO without SPIRA_WORK (no assigned worktree, e.g. a sweep) → allowed.
#   4. Operator commits in REPO with SPIRA_WORK set → allowed (not an aeon identity).
#
# Case 2 is the positive control for the guard: if it does not fire on that case, the test
# proves nothing (law-absence-needs-a-positive-control).
#
# Driven against branch-guard.sh directly (via a pre-commit hook), without a full aeon.sh
# invocation. The hook is what enforces the rule; testing via aeon.sh would test that the
# harness invoked a model, not that the guard fires.
#
# covers: spira/branch-guard.sh spira/aeon.sh
# defect: sp-tjw9k
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "wanted [$2] in [$3]" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# GUARD ON THE GUARD: the guard must exist or the positive control cannot fire.
[ -f "$HERE/branch-guard.sh" ] || { echo "SKIP: branch-guard.sh not found beside this suite" >&2; exit 0; }

# ---- minimal harness copy ---------------------------------------------------------------
# branch-guard.sh sources lib.sh (which sources conf.sh) relative to its own location.
SH="$TMP/spira"
mkdir -p "$SH"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/branch-guard.sh" "$SH/"

# ---- git fixture ------------------------------------------------------------------------
# A bare remote and a working checkout with main as its base branch.
REMOTE="$TMP/remote.git"
REPO="$TMP/repo"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/f"
GIT_AUTHOR_NAME=op GIT_AUTHOR_EMAIL="op@example.com" \
GIT_COMMITTER_NAME=op GIT_COMMITTER_EMAIL="op@example.com" \
git -C "$REPO" add f
GIT_AUTHOR_NAME=op GIT_AUTHOR_EMAIL="op@example.com" \
GIT_COMMITTER_NAME=op GIT_COMMITTER_EMAIL="op@example.com" \
git -C "$REPO" commit -q -m "initial"
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

# Enable per-worktree config (prerequisite for per-worktree hooks in the worktree).
git -C "$REPO" config extensions.worktreeConfig true

# Create a worktree at a path that matches the sanctioned root pattern.
WORK="$TMP/run/worktree/sp-test"
mkdir -p "$(dirname "$WORK")"
git -C "$REPO" worktree add -q -b spira/sp-test "$WORK" origin/main

# ---- install the hook in REPO -----------------------------------------------------------
# Points core.hooksPath at a directory containing a pre-commit script that calls
# branch-guard.sh staged. This mirrors what exclude.sh install does in production.
HOOK_DIR="$TMP/hooks"
mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/pre-commit" << HOOK
#!/usr/bin/env bash
exec bash "$SH/branch-guard.sh" staged
HOOK
chmod +x "$HOOK_DIR/pre-commit"
git -C "$REPO" config core.hooksPath "$HOOK_DIR"
# The worktree also needs the hook. Use the same hook dir — the guard is the same.
git -C "$WORK" config --worktree core.hooksPath "$HOOK_DIR"

export GIT_RUN="$TMP/run"
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_CONF="$TMP/no-such.conf"

echo
echo "test-aeon-worktree-guard.sh"
echo

# ======================================================================================
echo "CASE 1: aeon commits in the assigned worktree (SPIRA_WORK == current tree) — ALLOWED:"
# ======================================================================================
# The guard must NOT fire when the commit happens in the worktree it was assigned.
printf 'aeon work v1\n' > "$WORK/g"
git -C "$WORK" add g
out="$(GIT_AUTHOR_NAME="aeon-t" GIT_AUTHOR_EMAIL="aeon-t@spira.local" \
       GIT_COMMITTER_NAME="aeon-t" GIT_COMMITTER_EMAIL="aeon-t@spira.local" \
       SPIRA_WORK="$WORK" \
       git -C "$WORK" commit -m "sp-test: work in worktree" 2>&1)"; rc=$?
is "case 1: commit in worktree is allowed" "0" "$rc"

echo
# ======================================================================================
echo "CASE 2 (positive control): aeon commits in REPO (production checkout) with SPIRA_WORK set — REFUSED:"
# ======================================================================================
# This is the exact defect: committing in the production checkout while the worktree path
# is set to something else. The guard must fire and name both paths.
git -C "$REPO" checkout -q spira/sp-test 2>/dev/null || git -C "$REPO" checkout -q main
printf 'production change\n' >> "$REPO/f"
git -C "$REPO" add f
out="$(GIT_AUTHOR_NAME="aeon-t" GIT_AUTHOR_EMAIL="aeon-t@spira.local" \
       GIT_COMMITTER_NAME="aeon-t" GIT_COMMITTER_EMAIL="aeon-t@spira.local" \
       SPIRA_WORK="$WORK" \
       git -C "$REPO" commit -m "sp-test: wrong checkout" 2>&1)"; rc=$?
is "case 2: commit in production checkout is refused" "1" "$rc"
want "case 2: refusal names the production checkout path" "$REPO" "$out"
want "case 2: refusal names SPIRA_WORK" "$WORK" "$out"
want "case 2: refusal message identifies branch-guard.sh" "branch-guard.sh" "$out"
# Unstage so later cases start clean.
git -C "$REPO" restore --staged f 2>/dev/null || git -C "$REPO" reset -q HEAD f 2>/dev/null || true

echo
# ======================================================================================
echo "CASE 3: aeon commits in REPO without SPIRA_WORK set (no assigned worktree) — ALLOWED:"
# ======================================================================================
# A sweep or other beadless session has no SPIRA_WORK. The guard must not fire.
# Use a feature branch (not main) so the existing base-branch check does not also fire —
# the case under test is specifically the SPIRA_WORK check, not the base-branch check.
git -C "$REPO" checkout -q -b spira/sp-sweep 2>/dev/null || git -C "$REPO" checkout -q spira/sp-sweep
printf 'unassigned aeon change\n' >> "$REPO/f"
git -C "$REPO" add f
out="$(GIT_AUTHOR_NAME="aeon-t" GIT_AUTHOR_EMAIL="aeon-t@spira.local" \
       GIT_COMMITTER_NAME="aeon-t" GIT_COMMITTER_EMAIL="aeon-t@spira.local" \
       git -C "$REPO" commit -m "sp-test: sweep commit" 2>&1)"; rc=$?
is "case 3: commit with no SPIRA_WORK is allowed" "0" "$rc"

echo
# ======================================================================================
echo "CASE 4: operator commits in REPO with SPIRA_WORK set — ALLOWED (not an aeon identity):"
# ======================================================================================
# The guard must not affect operator commits, which have a normal email address.
printf 'operator change\n' >> "$REPO/f"
git -C "$REPO" add f
out="$(GIT_AUTHOR_NAME="op" GIT_AUTHOR_EMAIL="op@example.com" \
       GIT_COMMITTER_NAME="op" GIT_COMMITTER_EMAIL="op@example.com" \
       SPIRA_WORK="$WORK" \
       git -C "$REPO" commit -m "operator direct commit" 2>&1)"; rc=$?
is "case 4: operator commit in production checkout is allowed" "0" "$rc"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
