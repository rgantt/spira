#!/usr/bin/env bash
#
# test-skew-behind-dirty.sh — when the checkout is BOTH behind AND dirty, check() surfaces
# the reason automatic refresh declined rather than treating BEHIND and DIRTY as peer findings.
#
# THREE CASES UNDER TEST:
#   1. BEHIND + DIRTY (genuine change) — REFRESH-DECLINED note in output, paths listed.
#   2. BEHIND + DIRTY (byte-identical to base ref) — byte-identical noted, git checkout remedy.
#   3. BEHIND + CLEAN (positive control) — no REFRESH-DECLINED; proves the note depends on dirt.
#   4. refresh() stamp — writes $SPIRA_RUN/skew.refresh-declined when dirty tree declines.
#
# THE FIXTURE IS A REAL LOCAL CLONE so origin/master advances past the clone's HEAD and
# `git fetch` works without a network call.  A fake install.sh prevents CANNOT-DIFF from
# adding a soft finding that would suppress the escalation call.
#
# A GOOD_NOTIFY script echoes its arguments and exits 0 so check() reaches escalate() and
# we can inspect the evidence block in the test output.
#
# covers: spira/skew.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-skew-behind-dirty.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Build a bare ORIGIN and a SRC that can push to it.
# SRC starts with a base commit (the clone will be at this point).
# Then SRC advances one commit past the clone so the clone is BEHIND.
# ---------------------------------------------------------------------------
ORIGIN="$TMP/origin"
git init --bare -q "$ORIGIN"

SRC="$TMP/src"
git init -q "$SRC"
git -C "$SRC" config user.email "test@test"
git -C "$SRC" config user.name "test"
mkdir -p "$SRC/spira" "$SRC/systemd"

# Harness signature files: scope_from_paths in exclude.sh requires boundary, gate.sh, lib.sh.
printf '# harness boundary\n'  > "$SRC/spira/boundary"
printf '#!/usr/bin/env bash\n' > "$SRC/spira/gate.sh"
printf '#!/usr/bin/env bash\n' > "$SRC/spira/lib.sh"
# A tracked file we will selectively modify in clones to create dirty states.
printf '#!/usr/bin/env bash\n# original content\n' > "$SRC/spira/extra.sh"

# Stub install.sh exits 0 for --diff so STALE does not produce a CANNOT-DIFF soft
# finding — that would prevent the escalation path from being reached in check().
cat > "$SRC/systemd/install.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--diff" ] && { echo "stub: installed units match"; exit 0; }
exit 0
EOF
chmod +x "$SRC/systemd/install.sh"

git -C "$SRC" add spira/ systemd/
git -C "$SRC" commit -q -m "fixture: base"

# Detect what the default branch is called (master or main).
DEF_BRANCH="$(git -C "$SRC" branch --show-current 2>/dev/null || echo master)"

# Push the base commit to ORIGIN so we can clone from it.
git -C "$SRC" remote add origin "file://$ORIGIN"
git -C "$SRC" push -q origin "${DEF_BRANCH}:${DEF_BRANCH}"

# Clone at the BASE commit.  After clone, the clone's HEAD == origin/$DEF_BRANCH == base.
BASE_CLONE="$TMP/base-clone"
git clone -q "file://$ORIGIN" "$BASE_CLONE"
git -C "$BASE_CLONE" config user.email "test@test"
git -C "$BASE_CLONE" config user.name "test"

# Advance SRC and push so ORIGIN is now 1 commit ahead of the clone.
printf '\n# landed fix\n' >> "$SRC/spira/extra.sh"
git -C "$SRC" add spira/extra.sh
git -C "$SRC" commit -q -m "fixture: advance"
git -C "$SRC" push -q origin "HEAD:${DEF_BRANCH}"

# ---------------------------------------------------------------------------
# make_repo <name> <dirty: genuine|identical|clean>
#   Creates a fresh test repo by copying BASE_CLONE, fetches origin so
#   origin/$DEF_BRANCH is 1 commit ahead of HEAD, then applies the dirty state.
# ---------------------------------------------------------------------------
make_repo() {
    local name="$1" dirty="$2"
    local repo="$TMP/$name"
    cp -r "$BASE_CLONE" "$repo"
    git -C "$repo" config user.email "test@test"
    git -C "$repo" config user.name "test"
    # fetch advances origin/$DEF_BRANCH to the "advance" commit while HEAD stays at base.
    git -C "$repo" fetch -q
    case "$dirty" in
        genuine)
            # Content different from both HEAD and origin/$DEF_BRANCH.
            printf '\n# different local modification\n' >> "$repo/spira/extra.sh"
            ;;
        identical)
            # Overwrite with the origin/$DEF_BRANCH content: dirty relative to HEAD but
            # byte-identical to the base ref.  This is the hand-apply-instead-of-pull case.
            git -C "$repo" show "origin/${DEF_BRANCH}:spira/extra.sh" \
                > "$repo/spira/extra.sh" 2>/dev/null
            ;;
        clean)
            # Leave the working tree as-is (clean).
            ;;
    esac
    printf '%s' "$repo"
}

# ---------------------------------------------------------------------------
# run_skew <repo> [env-var=val ...]
#   Runs check --escalate in a minimal environment for the given repo.
# ---------------------------------------------------------------------------
run_skew() {
    local repo="$1"; shift
    local run_dir
    run_dir="$(mktemp -d "$TMP/run-XXXXX")"
    env -i PATH="$PATH" \
        HOME="$TMP/home" \
        SPIRA_CONF=/nonexistent \
        SPIRA_HOME="$repo/spira" \
        SPIRA_REPO="$repo" \
        SPIRA_RUN="$run_dir" \
        SPIRA_DOLT_DATA="" \
        SPIRA_TESTDB_DATA="" \
        "${@}" \
        bash "$HERE/skew.sh" check --escalate 2>&1
    return "${PIPESTATUS[0]:-$?}"
}

# A notify stub that prints its arguments (so we can see the evidence block) and exits 0.
GOOD_NOTIFY="$TMP/good-notify.sh"
cat > "$GOOD_NOTIFY" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
echo "sp-xxxx"
exit 0
EOF
chmod +x "$GOOD_NOTIFY"

# ===========================================================================
echo
echo "BEHIND + DIRTY (genuine change) — REFRESH-DECLINED, paths listed, remedy to review:"
# ===========================================================================
REPO_GENUINE="$(make_repo repo-genuine genuine)"
genuine_out="$(run_skew "$REPO_GENUINE" SPIRA_NOTIFY="$GOOD_NOTIFY")"; genuine_rc=$?
is   "genuine: exits 1 (divergence found)"        "1"                "$genuine_rc"
want "genuine: BEHIND present"                     "BEHIND"           "$genuine_out"
want "genuine: DIRTY present"                      "DIRTY"            "$genuine_out"
want "genuine: REFRESH-DECLINED present"           "REFRESH-DECLINED" "$genuine_out"
want "genuine: modified path listed"               "extra.sh"         "$genuine_out"

# ===========================================================================
echo
echo "BEHIND + DIRTY (byte-identical to base ref) — byte-identical noted, checkout remedy:"
# ===========================================================================
REPO_IDENTICAL="$(make_repo repo-identical identical)"
identical_out="$(run_skew "$REPO_IDENTICAL" SPIRA_NOTIFY="$GOOD_NOTIFY")"; identical_rc=$?
is   "identical: exits 1 (divergence found)"      "1"                          "$identical_rc"
want "identical: REFRESH-DECLINED present"        "REFRESH-DECLINED"            "$identical_out"
want "identical: byte-identical noted"            "byte-for-byte identical"     "$identical_out"
want "identical: checkout remedy present"         "checkout"                    "$identical_out"

# ===========================================================================
echo
echo "BEHIND + CLEAN (positive control) — no REFRESH-DECLINED; note depends on dirt:"
# ===========================================================================
REPO_CLEAN="$(make_repo repo-clean clean)"
clean_out="$(run_skew "$REPO_CLEAN" SPIRA_NOTIFY="$GOOD_NOTIFY")"; clean_rc=$?
is     "clean: exits 1 (behind)"             "1"                "$clean_rc"
want   "clean: BEHIND present"               "BEHIND"           "$clean_out"
nowant "clean: no REFRESH-DECLINED"          "REFRESH-DECLINED" "$clean_out"
nowant "clean: no DIRTY"                     "DIRTY "           "$clean_out"

# ===========================================================================
echo
echo "refresh() — stamp file written when dirty tree declines:"
# ===========================================================================
REPO_STAMP="$(make_repo repo-stamp genuine)"
STAMP_RUN="$TMP/stamp-run"
mkdir -p "$STAMP_RUN"
env -i PATH="$PATH" \
    HOME="$TMP/home" \
    SPIRA_CONF=/nonexistent \
    SPIRA_HOME="$REPO_STAMP/spira" \
    SPIRA_REPO="$REPO_STAMP" \
    SPIRA_RUN="$STAMP_RUN" \
    SPIRA_DOLT_DATA="" \
    SPIRA_TESTDB_DATA="" \
    bash "$HERE/skew.sh" refresh >/dev/null 2>&1 || true
[ -f "$STAMP_RUN/skew.refresh-declined" ] \
    && ok "refresh: stamp file written when dirty tree declines" \
    || bad "refresh: stamp file written when dirty tree declines" \
           "stamp not found at $STAMP_RUN/skew.refresh-declined"

# ===========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
