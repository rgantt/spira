#!/usr/bin/env bash
#
# test-doctor-unit-dup.sh — doctor.sh's "installed units" section warns when a
# plain-named spira unit coexists with its instance-named successor.
#
#   ./test-doctor-unit-dup.sh
#
# WHAT THIS TESTS
# ---------------
# Before per-instance naming, spira-* units were installed without a suffix
# (spira-sentinel.service). install.sh migrates them by disabling the old unit and
# removing the file. If the file remains — because the migration ran before the rm
# step was added — `systemctl list-unit-files` shows two units claiming the same
# service, which breaks the assumption that the instance-named unit is the only
# copy.
#
# THREE PROPERTIES are tested:
#
#   1. POSITIVE CONTROL. A planted duplicate pair must be reported before the
#      clean case is trusted. A checker that never fires looks identical to one
#      that fires and passes.
#
#   2. DUPLICATE CASE. When both spira-sentinel.service and
#      spira-sentinel-prod.service exist in the unit directory, doctor.sh outputs
#      a WARN for the pair.
#
#   3. CLEAN CASE. When only spira-sentinel-prod.service exists (no plain-named
#      copy), doctor.sh reports "no duplicate plain/instance unit pairs".
#
#   4. TEMPLATE EXCLUSION. The watcher template (spira-watch@.service) must NOT
#      be flagged as a duplicate even when it sits alongside instance-named watcher
#      units.
#
# covers: spira/doctor.sh spira/conf.sh
# covers: systemd/install.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-doctor-unit-dup.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Shared infrastructure
# ---------------------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"

# Fake bd: handles the calls doctor.sh makes.
cat > "$BIN/bd" <<'FAKESCRIPT'
#!/usr/bin/env bash
case "$*" in
    *"migrate schema"*) printf '✓ Schema already at v61\n'; exit 0 ;;
    *"list"*"--limit"*) printf '[]\n'; exit 0 ;;
    *) exit 0 ;;
esac
FAKESCRIPT
chmod +x "$BIN/bd"

# Fake systemctl: reports all units as active, watcher lists as empty.
cat > "$BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"is-active"*"--quiet"*) exit 0 ;;
    *"is-active"*) printf 'active\n' ;;
    *"list-units"*"spira-aeon"*) true ;;
    *"list-unit-files"*"spira-watch"*) true ;;
    *"list-units"*"spira-watch"*) true ;;
    *"list-timers"*) true ;;
esac
exit 0
MOCK
chmod +x "$BIN/systemctl"

# The unit directory doctor.sh reads is $HOME/.config/systemd/user. We redirect
# HOME so the test never touches the real installed units. The unit directory is
# created per-case inside the loop rather than once, so each case starts clean.
FAKE_HOME="$TMP/home"

setup_db() {
    mkdir -p "$FAKE_HOME/.config/systemd/user" "$TMP/db/.beads" "$TMP/run"
}

# Write a minimal unit file containing only the lines relevant to the check.
write_unit() {
    local path="$1" execstart="$2"
    printf '[Service]\nExecStart=%s\n' "$execstart" > "$path"
}

run_doctor() {
    env -i \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        HOME="$FAKE_HOME" \
        SPIRA_CONF=/nonexistent \
        SPIRA_PATH="$BIN" \
        SPIRA_SYSTEMCTL="$BIN/systemctl" \
        SPIRA_DB="$TMP/db" \
        SPIRA_RUN="$TMP/run" \
        SPIRA_INSTANCE=prod \
        SPIRA_BD_PIN="$TMP/run/bd-pin" \
        SPIRA_REPO_MAP=/nonexistent \
        SPIRA_NOTIFY=/nonexistent \
        bash "$HERE/doctor.sh" 2>/dev/null || true
}

UNIT_DIR="$FAKE_HOME/.config/systemd/user"

# ===========================================================================
echo
echo "positive control — duplicate pair is caught before clean case is trusted:"
# ===========================================================================
# Plant both spira-sentinel.service (plain) and spira-sentinel-prod.service.
# The plain one is what _migrate_legacy failed to delete; both having the same
# ExecStart is the "identical" case the bead measured.
rm -rf "$FAKE_HOME"; setup_db
write_unit "$UNIT_DIR/spira-sentinel.service"      "/harness/spira/sentinel.sh"
write_unit "$UNIT_DIR/spira-sentinel-prod.service" "/harness/spira/sentinel.sh"

ctrl_out="$(run_doctor)"
# The sentinel uses the unit name as its only concurrency control; a duplicate pair
# means the mutex is gone. This must be FAIL, not a warning.
want "positive control: FAIL line for sentinel duplicate pair" \
     "  FAIL  duplicate unit pair" "$ctrl_out"
want "positive control: plain unit named in FAIL" \
     "spira-sentinel.service" "$ctrl_out"
want "positive control: instance unit named in FAIL" \
     "spira-sentinel-prod.service" "$ctrl_out"

# ===========================================================================
echo
echo "duplicate case — both plain and instance unit exist: FAIL reported:"
# ===========================================================================
# Same setup as positive control, but verify nowant on the clean message.
nowant "duplicate case: 'no duplicate' line absent when pair exists" \
       "no duplicate plain/instance unit pairs" "$ctrl_out"

# ===========================================================================
echo
echo "clean case — only instance-named unit exists: no WARN:"
# ===========================================================================
rm -rf "$FAKE_HOME"; setup_db
write_unit "$UNIT_DIR/spira-sentinel-prod.service" "/harness/spira/sentinel.sh"

clean_out="$(run_doctor)"
nowant "clean case: no WARN for sentinel" \
       "duplicate unit pair" "$(printf '%s\n' "$clean_out" | grep sentinel || true)"
want   "clean case: ok line for installed units section" \
       "no duplicate plain/instance unit pairs" "$clean_out"

# ===========================================================================
echo
echo "timer duplicates — timer pair also reported:"
# ===========================================================================
rm -rf "$FAKE_HOME"; setup_db
write_unit "$UNIT_DIR/spira-suites.service"      "/harness/spira/suites.sh run"
write_unit "$UNIT_DIR/spira-suites-prod.service" "/harness/spira/suites.sh run"
printf '[Timer]\nOnCalendar=hourly\n' > "$UNIT_DIR/spira-suites.timer"
printf '[Timer]\nOnCalendar=hourly\n' > "$UNIT_DIR/spira-suites-prod.timer"

timer_out="$(run_doctor)"
want "timer case: WARN for service pair"  "spira-suites.service"  "$timer_out"
want "timer case: WARN for timer pair"    "spira-suites.timer"    "$timer_out"

# ===========================================================================
echo
echo "template exclusion — spira-watch@.service must not be flagged:"
# ===========================================================================
rm -rf "$FAKE_HOME"; setup_db
write_unit "$UNIT_DIR/spira-sentinel-prod.service"  "/harness/spira/sentinel.sh"
write_unit "$UNIT_DIR/spira-watch-answers-prod.service" "/harness/spira/watchd.sh"
# The watcher template exists alongside the instance-named watcher; must not warn.
printf '[Service]\nExecStart=/harness/spira/watchd.sh %%i\n' \
    > "$UNIT_DIR/spira-watch@.service"

tmpl_out="$(run_doctor)"
nowant "template exclusion: watch@ not flagged" \
       "duplicate unit pair: spira-watch@.service" "$tmpl_out"
want   "template exclusion: ok line still present" \
       "no duplicate plain/instance unit pairs" "$tmpl_out"

# ===========================================================================
echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
