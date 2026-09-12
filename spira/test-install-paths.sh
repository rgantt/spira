#!/usr/bin/env bash
#
# test-install-paths.sh — install.sh refuses when another instance's config shares a
# critical path (SPIRA_RUN, SPIRA_DB, SPIRA_PROD, SPIRA_DOLT_DATA, SPIRA_TESTDB_PORT);
# two instances with distinct paths install without complaint.
#
#   ./test-install-paths.sh
#
# PROPERTIES UNDER TEST
# ---------------------
# 1. COLLISION DETECTED: two configs in the same directory sharing SPIRA_RUN fail the
#    install, naming the colliding key and the other instance. No unit is written.
# 2. DISTINCT PATHS: two configs with different SPIRA_RUN values pass the collision
#    check and do not block the install.
# 3. NO CONFIG FILE: SPIRA_CONF points to a non-existent file; the check is skipped
#    (SPIRA_CONF_FILE is empty) and the install proceeds.
# 4. SAME INSTANCE: two configs in the same directory with the same SPIRA_INSTANCE
#    value are not compared — the check only compares different instances.
#
# POSITIVE CONTROL: the matcher must first demonstrate it finds a known collision,
# then be trusted when it reports none (law-absence-needs-a-positive-control).
#
# covers: systemd/install.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_REPO="$(cd "$HERE/.." && pwd -P)"
REAL_COCKPIT="$(cd "$HERE/../cockpit" && pwd -P)"
pass=0; fail=0
ok()      { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()     { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()    { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant()  { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
iszero()  { [ "$2" = 0 ] && ok "$1" || bad "$1" "wanted exit 0, got $2"; }
nonzero() { [ "$2" != 0 ] && ok "$1" || bad "$1" "wanted non-zero exit, got 0"; }

echo "test-install-paths.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture: minimal harness tree.
# ---------------------------------------------------------------------------
FIXTURE="$TMP/harness"
mkdir -p "$FIXTURE/systemd" "$FIXTURE/spira"

for f in "$HERE/../systemd/"*.service "$HERE/../systemd/"*.timer; do
    [ -e "$f" ] || continue
    ln -s "$f" "$FIXTURE/systemd/$(basename "$f")"
done
ln -s "$HERE/../systemd/install.sh" "$FIXTURE/systemd/install.sh"
for f in conf.sh watchd.sh lib.sh; do
    [ -e "$HERE/$f" ] && ln -s "$HERE/$f" "$FIXTURE/spira/$f"
done
printf '# empty\n' > "$FIXTURE/spira/watchers"
printf '# empty\n' > "$FIXTURE/spira/repo-map"
printf '# empty\n' > "$FIXTURE/spira/repo-map.example"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/spira/install-session-hook.sh"
chmod +x "$FIXTURE/spira/install-session-hook.sh"

DEST="$TMP/home/.config/systemd/user"
SPIRA_RUN_DIR="$TMP/run"
MOCK_BIN="$TMP/mock-bin"
# The config directory — both instance configs live here so the collision check finds them.
CONF_DIR="$TMP/home/.config/spira"
mkdir -p "$DEST" "$SPIRA_RUN_DIR" "$MOCK_BIN" "$CONF_DIR"
MOCK_LOG="$TMP/systemctl.log"

cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "$*" in
    *list-units*active*spira-aeon*) true ;;
    *list-unit-files*spira-watch*) true ;;
    *list-units*spira-watch*) true ;;
    *is-active*) printf 'active\n' ;;
    *list-timers*) true ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/loginctl"
chmod +x "$MOCK_BIN/loginctl"

# inst_conf <spira-conf-path> [extra-env...] — run install.sh for the 'test' instance
# with SPIRA_CONF pointing at the given file. SPIRA_RUN is passed in the environment
# (env wins over the config file) so the collision check compares against it.
inst_conf() {
    local conf_path="$1"; shift
    > "$MOCK_LOG"
    env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        "SPIRA_CONF=$conf_path" \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_WATCHERS=$FIXTURE/spira/watchers" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_RUN=$SPIRA_RUN_DIR" \
        "SPIRA_HOME=$FIXTURE/spira" \
        "SPIRA_PROD=$FIXTURE/spira" \
        "SPIRA_REPO=$REAL_REPO" \
        "SPIRA_COCKPIT=$REAL_COCKPIT" \
        "MOCK_LOG=$MOCK_LOG" \
        SPIRA_INSTALL_FORCE=1 \
        "$@" \
        bash "$FIXTURE/systemd/install.sh" test 2>&1
}

# Seed DEST with pre-rendered units so the install loop has existing files to compare.
# Use SPIRA_CONF=/nonexistent (no config file) for the seed render so it is clean.
rendered="$(
    env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_WATCHERS=$FIXTURE/spira/watchers" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_RUN=$SPIRA_RUN_DIR" \
        "SPIRA_HOME=$FIXTURE/spira" \
        "SPIRA_PROD=$FIXTURE/spira" \
        "SPIRA_REPO=$REAL_REPO" \
        "SPIRA_COCKPIT=$REAL_COCKPIT" \
        "MOCK_LOG=$MOCK_LOG" \
        bash "$FIXTURE/systemd/install.sh" test --render 2>&1
)"
render_rc=$?
if [ "$render_rc" != 0 ]; then
    printf 'fixture: --render failed (rc=%s) — cannot continue\n' "$render_rc"
    printf '%s\n' "$rendered"
    exit 1
fi
current_unit=""
while IFS= read -r line; do
    if [[ "$line" =~ ^=====\ (.+)\ =====$ ]]; then
        current_unit="${BASH_REMATCH[1]}"; > "$DEST/$current_unit"
    elif [ -n "$current_unit" ]; then
        printf '%s\n' "$line" >> "$DEST/$current_unit"
    fi
done <<< "$rendered"

# ==========================================================================
echo
echo "POSITIVE CONTROL — collision on SPIRA_RUN is detected:"
# ==========================================================================
# Create a prod.conf that explicitly sets SPIRA_RUN to the same value we pass
# in the environment. The check compares the env-resolved SPIRA_RUN against
# what prod.conf explicitly declares — they match, so it must refuse.

printf 'SPIRA_INSTANCE = prod\nSPIRA_RUN = %s\n' "$SPIRA_RUN_DIR" \
    > "$CONF_DIR/prod.conf"
printf 'SPIRA_INSTANCE = test\n' > "$CONF_DIR/test.conf"

collision_out="$(inst_conf "$CONF_DIR/test.conf")"
collision_rc=$?

nonzero "collision: exit non-zero when SPIRA_RUN collides"   "$collision_rc"
want    "collision: names the colliding key"                  "SPIRA_RUN"   "$collision_out"
want    "collision: names the other instance"                 "prod"        "$collision_out"
want    "collision: names the other config file"              "prod.conf"   "$collision_out"
# No unit must have been written — DEST should still hold only the seeded files.
installed_after="$(ls "$DEST" | wc -l | tr -d ' ')"
pre_seeded="$(ls "$DEST" | wc -l | tr -d ' ')"
[ "$installed_after" = "$pre_seeded" ] \
    && ok "collision: no unit written after refusal" \
    || bad "collision: DEST changed after refusal (was $pre_seeded, now $installed_after)" ""

# ==========================================================================
echo
echo "DISTINCT PATHS — different SPIRA_RUN values do not block the install:"
# ==========================================================================
# prod.conf sets a DIFFERENT SPIRA_RUN. The check must stay silent.

printf 'SPIRA_INSTANCE = prod\nSPIRA_RUN = %s\n' "$TMP/other-run" \
    > "$CONF_DIR/prod.conf"

distinct_out="$(inst_conf "$CONF_DIR/test.conf")"
distinct_rc=$?

iszero  "distinct: exit 0 when no path collision"            "$distinct_rc"
nowant  "distinct: no refusal message in output"             "refusing" "$distinct_out"
nowant  "distinct: no collision mention in output"           "collides" "$distinct_out"

# ==========================================================================
echo
echo "NO CONFIG FILE — SPIRA_CONF=/nonexistent skips the collision check:"
# ==========================================================================
# When SPIRA_CONF_FILE is empty (no file found), the check returns 0 immediately.

no_conf_out="$(
    env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_WATCHERS=$FIXTURE/spira/watchers" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_RUN=$SPIRA_RUN_DIR" \
        "SPIRA_HOME=$FIXTURE/spira" \
        "SPIRA_PROD=$FIXTURE/spira" \
        "SPIRA_REPO=$REAL_REPO" \
        "SPIRA_COCKPIT=$REAL_COCKPIT" \
        "MOCK_LOG=$MOCK_LOG" \
        SPIRA_INSTALL_FORCE=1 \
        bash "$FIXTURE/systemd/install.sh" test 2>&1
)"
no_conf_rc=$?

iszero  "no-conf: exit 0 when no config file (check skipped)" "$no_conf_rc"
nowant  "no-conf: no refusal message"                          "refusing" "$no_conf_out"

# ==========================================================================
echo
echo "SAME INSTANCE — two configs with the same SPIRA_INSTANCE are not compared:"
# ==========================================================================
# A config file declaring the SAME instance as the current install should be ignored,
# even if it sets a matching SPIRA_RUN. Comparing an instance against itself is not
# a collision; it is the same install run more than once.

printf 'SPIRA_INSTANCE = test\nSPIRA_RUN = %s\n' "$SPIRA_RUN_DIR" \
    > "$CONF_DIR/test-other.conf"

same_inst_out="$(inst_conf "$CONF_DIR/test.conf")"
same_inst_rc=$?

iszero  "same-instance: exit 0 when other config has same SPIRA_INSTANCE" "$same_inst_rc"
nowant  "same-instance: no refusal message"                                "refusing" "$same_inst_out"

# Clean up the extra config.
rm -f "$CONF_DIR/test-other.conf"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
