#!/usr/bin/env bash
#
# test-branch-guard.sh — branch-guard.sh refuses aeon commits to the base branch;
# it does not refuse operator commits or aeon commits on non-base branches.
#
# Three positive controls (the guard MUST fire on the bad cases), two negative controls
# (the guard MUST NOT fire on the good cases), and two check-mode cases (the audit detects
# an aeon tip and a checkout ahead of remote, then clears on both counts after cleanup).
#
# covers: spira/branch-guard.sh spira/hooks/pre-commit
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want(){ case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "wanted [$2] in [$3]" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Minimal harness copy the guard resolves relative to its own location.
SH="$TMP/spira"
mkdir -p "$SH/hooks"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/branch-guard.sh" "$SH/"
cp "$HERE/hooks/pre-commit" "$SH/hooks/"

# A bare remote plus a working checkout with main as its base branch.
REMOTE="$TMP/remote.git"
REPO="$TMP/repo"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
printf 'initial content\n' > "$REPO/f.txt"
GIT_AUTHOR_NAME=op GIT_AUTHOR_EMAIL="op@example.com" \
GIT_COMMITTER_NAME=op GIT_COMMITTER_EMAIL="op@example.com" \
git -C "$REPO" add -A
GIT_AUTHOR_NAME=op GIT_AUTHOR_EMAIL="op@example.com" \
GIT_COMMITTER_NAME=op GIT_COMMITTER_EMAIL="op@example.com" \
git -C "$REPO" commit -q -m "initial"
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
# Cache origin/HEAD so spira_landref finds the base without a network call.
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

GIT_BIN="$(dirname "$(command -v git)")"
mkdir -p "$TMP/run"

# run_guard <email> <repo> -> exit code of branch-guard.sh staged
run_guard() {
    local email="$1" root="$2"
    # RUN IN AN EXPLICIT MINIMAL ENVIRONMENT. Ambient conf is the thing that silently decides
    # verdicts in a suite that inherits it. SPIRA_CONF points at a nonexistent file so no
    # config file is read; SPIRA_REPO_MAP likewise so no map is consulted.
    env -i HOME="$TMP" PATH="$GIT_BIN:/usr/bin:/bin" \
        GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="$email" \
        SPIRA_CONF="$TMP/none.conf" SPIRA_REPO="$root" \
        SPIRA_REPO_MAP="$TMP/none.map" SPIRA_DB="$TMP/none.db" \
        SPIRA_RUN="$TMP/run" \
        bash "$SH/branch-guard.sh" staged "$root" >/dev/null 2>&1
}

echo "test-branch-guard.sh — staged: refuse aeon on base branch; pass otherwise"

# Stage a change so git commit would have something to commit.
printf 'line\n' >> "$REPO/f.txt"
git -C "$REPO" add -A

# ---------------------------------------------------------------------------------------
# POSITIVE CONTROL — the guard MUST fire when it should. "A check that finds nothing must
# first prove it could have found something" (law-absence-needs-a-positive-control).
# Plant the bad case and require the guard to say so, then believe it when it is silent.
# ---------------------------------------------------------------------------------------
out="$(env -i HOME="$TMP" PATH="$GIT_BIN:/usr/bin:/bin" \
    GIT_COMMITTER_NAME="aeon-shiva" GIT_COMMITTER_EMAIL="aeon-shiva@spira.local" \
    SPIRA_CONF="$TMP/none.conf" SPIRA_REPO="$REPO" \
    SPIRA_REPO_MAP="$TMP/none.map" SPIRA_DB="$TMP/none.db" \
    SPIRA_RUN="$TMP/run" \
    bash "$SH/branch-guard.sh" staged "$REPO" 2>&1)"; guard_rc=$?
is   "aeon on base branch: guard exits 1" 1 "$guard_rc"
want "aeon on base branch: names the committer email" "aeon-shiva@spira.local" "$out"
want "aeon on base branch: names the branch" "main" "$out"
want "aeon on base branch: names the override" "--no-verify" "$out"

# ---------------------------------------------------------------------------------------
# NEGATIVE CONTROL 1 — operator identity on base branch must be allowed through.
# ---------------------------------------------------------------------------------------
rc=0; run_guard "op@example.com" "$REPO" || rc=$?
is "operator on base branch: guard exits 0" 0 "$rc"

# ---------------------------------------------------------------------------------------
# NEGATIVE CONTROL 2 — aeon identity on a non-base branch must be allowed through.
# ---------------------------------------------------------------------------------------
git -C "$REPO" checkout -q -b "spira/sp-test" 2>/dev/null
rc=0; run_guard "aeon-shiva@spira.local" "$REPO" || rc=$?
is "aeon on non-base branch: guard exits 0" 0 "$rc"
git -C "$REPO" checkout -q main 2>/dev/null

echo ""
echo "test-branch-guard.sh — check: detect aeon tip and checkout ahead of remote"

# ---------------------------------------------------------------------------------------
# SET UP: plant an aeon commit directly on main (reproducing the defect), WITHOUT pushing.
# This exercises both anomalies: (1) aeon commit at the base branch tip, and (2) shared
# checkout is ahead of its remote.
# ---------------------------------------------------------------------------------------
printf 'aeon direct commit\n' >> "$REPO/f.txt"
GIT_AUTHOR_NAME="aeon-shiva" GIT_AUTHOR_EMAIL="aeon-shiva@spira.local" \
GIT_COMMITTER_NAME="aeon-shiva" GIT_COMMITTER_EMAIL="aeon-shiva@spira.local" \
git -C "$REPO" add -A
GIT_AUTHOR_NAME="aeon-shiva" GIT_AUTHOR_EMAIL="aeon-shiva@spira.local" \
GIT_COMMITTER_NAME="aeon-shiva" GIT_COMMITTER_EMAIL="aeon-shiva@spira.local" \
git -C "$REPO" commit -q -m "sp-test: aeon commit planted directly on main"

# The check is run with SPIRA_REPO=$REPO so spira_repos returns the home repo name and
# repo_root resolves to $REPO. SPIRA_REPO_MAP is absent so the map contributes nothing.
run_check() {
    env -i HOME="$TMP" PATH="$GIT_BIN:/usr/bin:/bin" \
        SPIRA_CONF="$TMP/none.conf" SPIRA_REPO="$REPO" \
        SPIRA_REPO_MAP="$TMP/none.map" SPIRA_DB="$TMP/none.db" \
        SPIRA_RUN="$TMP/run" \
        bash "$SH/branch-guard.sh" check 2>&1
}

check_out="$(run_check)"; check_rc=$?
is   "check: exits 1 when aeon tip and ahead-of-remote" 1 "$check_rc"
want "check: reports AEON COMMIT ON" "AEON COMMIT ON" "$check_out"
want "check: reports SHARED CHECKOUT AHEAD" "SHARED CHECKOUT AHEAD" "$check_out"

# ---------------------------------------------------------------------------------------
# After pushing, the checkout is no longer ahead. The aeon commit is still the tip on
# both sides, so AEON COMMIT is still reported but SHARED CHECKOUT AHEAD is not.
# ---------------------------------------------------------------------------------------
git -C "$REPO" push -q origin main

check_out="$(run_check)"; check_rc=$?
is   "check: still exits 1 (aeon is still the tip)" 1 "$check_rc"
want "check: still reports AEON COMMIT ON" "AEON COMMIT ON" "$check_out"
case "$check_out" in
    *"SHARED CHECKOUT AHEAD"*) bad "check: no longer ahead after push" "still reported AHEAD" ;;
    *) ok "check: SHARED CHECKOUT AHEAD gone after push" ;;
esac

# ---------------------------------------------------------------------------------------
# After an operator commit on top, the aeon is no longer the tip. Check should be clean.
# ---------------------------------------------------------------------------------------
printf 'operator restores order\n' >> "$REPO/f.txt"
GIT_AUTHOR_NAME=op GIT_AUTHOR_EMAIL="op@example.com" \
GIT_COMMITTER_NAME=op GIT_COMMITTER_EMAIL="op@example.com" \
git -C "$REPO" add -A
GIT_AUTHOR_NAME=op GIT_AUTHOR_EMAIL="op@example.com" \
GIT_COMMITTER_NAME=op GIT_COMMITTER_EMAIL="op@example.com" \
git -C "$REPO" commit -q -m "chore: operator commit restoring a clean tip"
git -C "$REPO" push -q origin main

check_out="$(run_check)"; check_rc=$?
is   "check: exits 0 after operator commit" 0 "$check_rc"
want "check: reports clean" "clean" "$check_out"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
