#!/usr/bin/env bash
#
# test-promote.sh — promote.sh names its model and behaves accordingly.
#
# WHAT THIS SUITE IS FOR
# ----------------------
# promote.sh supports two installation layouts: split-checkout (SPIRA_PROD outside
# SPIRA_REPO) and single-checkout (SPIRA_PROD inside SPIRA_REPO). The latter is the
# case where the dev/prod separation does not exist, and promote.sh must not silently
# do nothing — it exits non-zero and names the right tool (skew.sh refresh).
#
# THE INVARIANT UNDER OPTION B (single-checkout model):
# promote.sh --dry-run exits non-zero when SPIRA_PROD is inside SPIRA_REPO, and the
# error output names the condition. "Exits non-zero doing nothing" is the bug this
# closes; the fix is an explicit, named exit.
#
# THE POSITIVE CONTROL IS FIRST. Before asserting that the fixed promote.sh names the
# condition correctly, prove that a version WITHOUT the fix would fail the invariant —
# i.e., that the invariant is discriminating and not trivially satisfied.
#
# covers: spira/promote.sh spira/conf.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "${2:-}"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }

echo "test-promote.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A minimal git repo doubles as both SPIRA_REPO and a fake SPIRA_PROD parent.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" commit --allow-empty -m "init" -q

# A real conf.sh and lib.sh are needed so promote.sh can source lib.sh -> conf.sh.
# We link the real ones so the detection logic they contain stays live.
mkdir -p "$REPO/spira"
ln -s "$HERE/lib.sh"  "$REPO/spira/lib.sh"
ln -s "$HERE/conf.sh" "$REPO/spira/conf.sh"
printf '# empty\n' > "$REPO/spira/repo-map.example"
printf '# empty\n' > "$REPO/spira/watchers"

# ==========================================================================
echo
echo "positive control — old promote.sh (pre-fix) silently exits 0 in single-checkout mode:"
# ==========================================================================
# A promote.sh that has no single-checkout detection would fast-forward PROD_REPO ==
# dirname(SPIRA_PROD). When SPIRA_PROD is inside SPIRA_REPO, PROD_REPO is also inside
# SPIRA_REPO, and the script would attempt git operations against itself. In practice the
# pre-fix code: (a) resolves the ref, (b) checks if PROD_REPO/.git exists, (c) clones if
# not. Since PROD_REPO (dirname of SPIRA_PROD = SPIRA_REPO) has a .git, it goes into the
# fast-forward path and exits 0 after printing "nothing to do" or advancing the HEAD —
# treating the repo AS the prod checkout. This is the silent incorrect behaviour the fix
# closes.
#
# We recreate the pre-fix behaviour by building a stripped promote.sh that omits the
# single-checkout block. The invariant check then asserts that this OLD version exits 0
# — proving the invariant would have failed before the fix.
OLD_PROMOTE="$TMP/old-promote.sh"
# Strip the single-checkout detection block from the real promote.sh. Everything between
# "_promote_prod=" and "unset _promote_prod" is the detection block.
sed '/^_promote_prod=/,/^unset _promote_prod/d' "$HERE/promote.sh" > "$OLD_PROMOTE"
chmod +x "$OLD_PROMOTE"

# Single-checkout configuration: SPIRA_PROD is inside SPIRA_REPO.
PROD_INSIDE="$REPO/spira"   # <-- inside the repo

old_rc=0
env -i PATH="$PATH" HOME="$TMP/home" \
    SPIRA_HOME="$REPO/spira" \
    SPIRA_REPO="$REPO" \
    SPIRA_PROD="$PROD_INSIDE" \
    SPIRA_RUN="$TMP/run" \
    SPIRA_DB="$TMP/db" \
    SPIRA_CONF=/nonexistent \
    SPIRA_WATCHERS="$REPO/spira/watchers" \
    bash "$OLD_PROMOTE" --dry-run HEAD 2>/dev/null
old_rc=$?
# The pre-fix code exits 0 (nothing to do, already at HEAD). That is the WRONG behaviour.
if [ "$old_rc" -eq 0 ]; then
    ok "positive control: pre-fix promote.sh exits 0 in single-checkout mode (this is the bug)"
else
    bad "positive control: pre-fix promote.sh exits 0 in single-checkout mode" \
        "expected rc=0, got rc=$old_rc"
fi

# ==========================================================================
echo
echo "invariant — fixed promote.sh exits non-zero in single-checkout mode:"
# ==========================================================================
err_out=""
rc=0
err_out="$(env -i PATH="$PATH" HOME="$TMP/home" \
    SPIRA_HOME="$REPO/spira" \
    SPIRA_REPO="$REPO" \
    SPIRA_PROD="$PROD_INSIDE" \
    SPIRA_RUN="$TMP/run" \
    SPIRA_DB="$TMP/db" \
    SPIRA_CONF=/nonexistent \
    SPIRA_WATCHERS="$REPO/spira/watchers" \
    bash "$HERE/promote.sh" --dry-run HEAD 2>&1)" || rc=$?

if [ "$rc" -ne 0 ]; then
    ok "fixed promote.sh exits non-zero in single-checkout mode (rc=$rc)"
else
    bad "fixed promote.sh exits non-zero in single-checkout mode" "exited 0 — silently did nothing"
fi

want "error output names single-checkout mode" "single-checkout" "$err_out"
want "error output names skew.sh refresh"      "skew.sh refresh" "$err_out"

# ==========================================================================
echo
echo "split-checkout mode — promote.sh does NOT exit early when SPIRA_PROD is outside SPIRA_REPO:"
# ==========================================================================
# When SPIRA_PROD is outside SPIRA_REPO, the single-checkout gate must not fire.
# Verify that by confirming the error message for single-checkout is absent in that case.
# (The script will fail for other reasons — no real prod clone — but not for single-checkout.)
PROD_OUTSIDE="$TMP/prod/spira"   # outside the repo
mkdir -p "$(dirname "$PROD_OUTSIDE")"

err_out2=""
env -i PATH="$PATH" HOME="$TMP/home" \
    SPIRA_HOME="$REPO/spira" \
    SPIRA_REPO="$REPO" \
    SPIRA_PROD="$PROD_OUTSIDE" \
    SPIRA_RUN="$TMP/run" \
    SPIRA_DB="$TMP/db" \
    SPIRA_CONF=/nonexistent \
    SPIRA_WATCHERS="$REPO/spira/watchers" \
    bash "$HERE/promote.sh" --dry-run HEAD 2>&1 | head -5 > /dev/null
err_out2="$(env -i PATH="$PATH" HOME="$TMP/home" \
    SPIRA_HOME="$REPO/spira" \
    SPIRA_REPO="$REPO" \
    SPIRA_PROD="$PROD_OUTSIDE" \
    SPIRA_RUN="$TMP/run" \
    SPIRA_DB="$TMP/db" \
    SPIRA_CONF=/nonexistent \
    SPIRA_WATCHERS="$REPO/spira/watchers" \
    bash "$HERE/promote.sh" --dry-run HEAD 2>&1 || true)"

if [[ "$err_out2" != *"single-checkout"* ]]; then
    ok "single-checkout gate does not fire when SPIRA_PROD is outside SPIRA_REPO"
else
    bad "single-checkout gate does not fire when SPIRA_PROD is outside SPIRA_REPO" \
        "found 'single-checkout' in output: $err_out2"
fi

# ==========================================================================
echo
echo "symlink case — detection works when SPIRA_PROD is a symlink into SPIRA_REPO:"
# ==========================================================================
LINK_PROD="$TMP/link-prod"
ln -s "$REPO/spira" "$LINK_PROD"   # symlink resolves to inside REPO

sym_err=""
sym_rc=0
sym_err="$(env -i PATH="$PATH" HOME="$TMP/home" \
    SPIRA_HOME="$REPO/spira" \
    SPIRA_REPO="$REPO" \
    SPIRA_PROD="$LINK_PROD" \
    SPIRA_RUN="$TMP/run" \
    SPIRA_DB="$TMP/db" \
    SPIRA_CONF=/nonexistent \
    SPIRA_WATCHERS="$REPO/spira/watchers" \
    bash "$HERE/promote.sh" --dry-run HEAD 2>&1)" || sym_rc=$?

if [ "$sym_rc" -ne 0 ]; then
    ok "single-checkout detection works through a symlink (rc=$sym_rc)"
else
    bad "single-checkout detection works through a symlink" "exited 0 — symlink defeated the check"
fi
want "symlink error names single-checkout" "single-checkout" "$sym_err"

# ==========================================================================
echo
echo "summary"
# ==========================================================================
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
