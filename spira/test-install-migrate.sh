#!/usr/bin/env bash
#
# test-install-migrate.sh — install.sh migrates un-suffixed legacy units to
# per-instance naming when they are present.
#
#   ./test-install-migrate.sh
#
# PROPERTIES UNDER TEST
# ---------------------
# 1. MIGRATION ORDERING: when legacy (un-suffixed) spira-* units are present,
#    install.sh disables them BEFORE enabling per-instance units — no window
#    where both sets are enabled simultaneously.
# 2. MIGRATION SCOPE: install.sh disables the spira-* units that have per-instance
#    counterparts (not shared units like cockpit-ensure, concierge, beads-push).
# 3. CLEAN INSTALL: when no legacy units are present, no spurious disable calls
#    report success — a fresh-box install produces no migration output.
#
# THE FIXTURE. A mock systemctl tracks which unit names are presented to it as
# "legacy" via MOCK_LEGACY_UNITS (space-separated). `disable` exits 0 only for
# those names; for all others it exits 1. The log records every call in order,
# so the ordering assertion reads the log top-to-bottom.
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
# before <label> <must-precede> <must-follow> <log>
# Asserts that at least one line containing <must-precede> appears before the
# first line containing <must-follow>.
before() {
    local label="$1" na="$2" nb="$3" log="$4"
    local lno=0 lno_a=0 lno_b=0 line
    while IFS= read -r line; do
        lno=$((lno+1))
        [[ "$line" == *"$na"* ]] && lno_a=$lno
        [[ "$line" == *"$nb"* ]] && { lno_b=$lno; break; }
    done <<< "$log"
    if [ "$lno_a" -gt 0 ] && [ "$lno_b" -gt 0 ] && [ "$lno_a" -lt "$lno_b" ]; then
        ok "$label"
    else
        bad "$label" "[$na] (line $lno_a) must precede [$nb] (line $lno_b)"
    fi
}

echo "test-install-migrate.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture: minimal harness tree (same pattern as other install tests).
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
printf '# empty\n' > "$FIXTURE/spira/repo-map.example"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/spira/install-session-hook.sh"
chmod +x "$FIXTURE/spira/install-session-hook.sh"
printf '# empty\n' > "$FIXTURE/spira/watchers"

DEST="$TMP/home/.config/systemd/user"
SPIRA_RUN_DIR="$TMP/run"
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$DEST" "$SPIRA_RUN_DIR" "$MOCK_BIN"
MOCK_LOG="$TMP/systemctl.log"

# ---------------------------------------------------------------------------
# Mock systemctl.
#
#   MOCK_LEGACY_UNITS  space-separated unit names treated as "present" legacy
#                      units. Any `disable` call exits 0 iff the unit name
#                      (last word of $*) is in MOCK_LEGACY_UNITS; exits 1
#                      otherwise (simulating "unit not found").
#   MOCK_IS_ACTIVE     returned by is-active queries (default: active)
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "$*" in
    *list-units*active*spira-aeon*)
        for a in ${MOCK_AEONS:-}; do printf '%s\n' "$a"; done
        ;;
    *list-unit-files*spira-watch*|*list-units*spira-watch*)
        printf '%s\n' "${MOCK_WATCH_LIST:-}"
        ;;
    *is-active*)
        printf '%s\n' "${MOCK_IS_ACTIVE:-active}"
        ;;
    *list-timers*)
        true
        ;;
    *" disable "*)
        # Extract unit name: last positional argument.
        # ${*##* } strips prefixes per-param rather than across the joined string,
        # so use ${@: -1} to get the actual last arg (the unit name).
        unit="${@: -1}"
        for lu in ${MOCK_LEGACY_UNITS}; do
            [ "$lu" = "$unit" ] && exit 0
        done
        exit 1
        ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/loginctl"
chmod +x "$MOCK_BIN/loginctl"

inst() {
    > "$MOCK_LOG"
    env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_WATCHERS=$FIXTURE/spira/watchers" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_RUN=$SPIRA_RUN_DIR" \
        "SPIRA_HOME=$HERE" \
        "SPIRA_PROD=$HERE" \
        "SPIRA_REPO=$REAL_REPO" \
        "SPIRA_COCKPIT=$REAL_COCKPIT" \
        "MOCK_LOG=$MOCK_LOG" \
        "MOCK_AEONS=${MOCK_AEONS:-}" \
        "MOCK_IS_ACTIVE=${MOCK_IS_ACTIVE:-active}" \
        "MOCK_WATCH_LIST=${MOCK_WATCH_LIST:-}" \
        "MOCK_LEGACY_UNITS=${MOCK_LEGACY_UNITS:-}" \
        "SPIRA_INSTALL_FORCE=${MOCK_FORCE:-1}" \
        bash "$FIXTURE/systemd/install.sh" test "$@" 2>&1
}

# ==========================================================================
echo
echo "MIGRATION ORDERING — disable legacy units before enabling per-instance:"
# ==========================================================================

# DEST is empty — all units are new, so the enable/restart loop calls systemctl
# for each one. This puts both disable and enable/restart calls in the mock log,
# making the ordering assertion possible.
rm -rf "$DEST"; mkdir -p "$DEST"

ord_out="$(MOCK_LEGACY_UNITS="spira-sentinel.service spira-sentinel.timer \
    spira-ops.service spira-ops.timer" \
    MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_WATCH_LIST= \
    inst)"
ord_rc=$?
ord_log="$(cat "$MOCK_LOG")"

iszero "ordering: install.sh exits 0 with legacy units present"  "$ord_rc"
want   "ordering: sentinel legacy unit appears in disable call"  \
       "spira-sentinel.service" "$ord_log"
want   "ordering: ops legacy unit appears in disable call"       \
       "spira-ops.service" "$ord_log"
want   "ordering: install output reports migration"              \
       "migrated" "$ord_out"

# The last disable of a legacy unit must appear in the log before the first
# reference to the corresponding new per-instance unit (enable or restart).
before "ordering: sentinel migrated before new unit starts" \
       "spira-sentinel.service" "spira-sentinel-test" "$ord_log"
before "ordering: ops migrated before new unit starts" \
       "spira-ops.service" "spira-ops-test" "$ord_log"

# ==========================================================================
echo
echo "MIGRATION SCOPE — shared units (cockpit-ensure, concierge, beads-push) excluded:"
# ==========================================================================

# Use the same log from the ordering scenario.
scope_log="$(cat "$MOCK_LOG")"

# Shared units pass through inst_name unchanged; they are not legacy names.
nowant "scope: cockpit-ensure.service not passed to disable" \
       "disable" "$(grep 'cockpit-ensure' "$MOCK_LOG" || true)"
nowant "scope: concierge.service not passed to disable" \
       "disable" "$(grep 'concierge' "$MOCK_LOG" || true)"
nowant "scope: beads-push.service not passed to disable" \
       "disable" "$(grep 'beads-push' "$MOCK_LOG" || true)"

# ==========================================================================
echo
echo "CLEAN INSTALL — no legacy units → disable returns 1, no migration output:"
# ==========================================================================

# Fresh DEST, empty MOCK_LEGACY_UNITS. disable exits 1 for every unit name.
rm -rf "$DEST"; mkdir -p "$DEST"

clean_out="$(MOCK_LEGACY_UNITS= MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_WATCH_LIST= \
    inst)"
clean_rc=$?

iszero  "clean install: exits 0 with no legacy units" "$clean_rc"
# No "migrated" output — disable failed (exit 1) for every legacy name.
nowant  "clean install: no 'migrated' in output" "migrated" "$clean_out"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
