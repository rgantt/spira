#!/usr/bin/env bash
#
# test-install-instance.sh — install.sh renders per-instance unit names; prune
# follows per-instance naming; installing one instance does not disrupt another.
#
#   ./test-install-instance.sh
#
# PROPERTIES UNDER TEST
# ---------------------
# 1. PER-INSTANCE NAMING: install.sh test writes spira-*-test.service/timer files to
#    DEST and does NOT write spira-*-prod.* files (no cross-instance contamination).
#    Non-spira units (cockpit-ensure, concierge, beads-push) keep their plain names.
# 2. PRUNE: a spira-watch-*-test.service unit that was installed for a watcher row now
#    absent from the manifest is disabled. The old template pattern (spira-watch@*.service)
#    is gone; prune operates on per-instance names.
# 3. AEON ISOLATION: installing the 'test' instance succeeds even when 'prod' aeons are
#    live, because the guard matches spira-aeon-*-test.service, not spira-aeon-*-prod.service.
# 4. WATCHER INSTALL: when the manifest has a 'testview' row, install.sh writes
#    spira-watch-testview-test.service (not spira-watch@testview.service).
#
# THE FIXTURE USES A MOCK systemctl THAT RECORDS CALLS AND RETURNS CONTROLLED OUTPUT.
# Drive install.sh from a scratch unit directory pinned to a non-default instance
# so the test cannot silently assert against whatever instance the operator has installed
# (law-gates-run-in-a-clean-environment).
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
atleast() { [ "$3" -ge "$2" ] && ok "$1" || bad "$1" "wanted >= $2, got $3"; }

echo "test-install-instance.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture: minimal harness tree (same pattern as the other install tests).
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

DEST="$TMP/home/.config/systemd/user"
SPIRA_RUN_DIR="$TMP/run"
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$DEST" "$SPIRA_RUN_DIR" "$MOCK_BIN"
MOCK_LOG="$TMP/systemctl.log"

# ---------------------------------------------------------------------------
# Mock systemctl records every call.
#
#   MOCK_AEONS      space-separated unit names returned as 'active' aeon units
#   MOCK_IS_ACTIVE  what is-active returns; defaults to "active"
#   MOCK_WATCH_LIST newline-separated per-instance watcher units returned by
#                   list-unit-files/list-units queries; empty = none
#
# The mock must return per-instance unit names so the prune grep can match them.
# The OLD template pattern (spira-watch@*.service) is never returned here.
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "$*" in
    *list-units*active*spira-aeon*)
        for a in ${MOCK_AEONS:-}; do printf '%s\n' "$a"; done
        ;;
    *list-unit-files*spira-watch*)
        printf '%s\n' "${MOCK_WATCH_LIST:-}"
        ;;
    *list-units*spira-watch*)
        printf '%s\n' "${MOCK_WATCH_LIST:-}"
        ;;
    *is-active*)
        printf '%s\n' "${MOCK_IS_ACTIVE:-active}"
        ;;
    *list-timers*)
        true
        ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/loginctl"
chmod +x "$MOCK_BIN/loginctl"

# ---------------------------------------------------------------------------
# inst [args] — run install.sh in the controlled environment.
# Always installs the 'test' instance (non-default) so the test asserts against
# an instance that cannot match whatever the operator has configured.
# ---------------------------------------------------------------------------
inst() {
    > "$MOCK_LOG"
    env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_WATCHERS=${MOCK_WATCHERS:-$FIXTURE/spira/watchers}" \
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
        "SPIRA_INSTALL_FORCE=${MOCK_FORCE:-}" \
        bash "$FIXTURE/systemd/install.sh" test "$@" 2>&1
}

# ==========================================================================
echo
echo "PER-INSTANCE NAMING — install.sh test writes spira-*-test.* to DEST:"
# ==========================================================================

# Empty watchers file so only fixed units are installed.
printf '# empty\n' > "$FIXTURE/spira/watchers"

# Seed DEST: --render with instance 'test' produces spira-*-test.* headers.
rendered="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE=1 MOCK_WATCH_LIST= \
             MOCK_WATCHERS="$FIXTURE/spira/watchers" inst --render)"
render_rc=$?
if [ "$render_rc" != 0 ]; then
    printf 'fixture: install.sh test --render failed (rc=%s)\n' "$render_rc"
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

clean_out="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE=1 MOCK_WATCH_LIST= \
              MOCK_WATCHERS="$FIXTURE/spira/watchers" inst)"
clean_rc=$?
clean_log="$(cat "$MOCK_LOG")"

iszero "naming: install.sh test exits 0" "$clean_rc"

# Every spira-* file in DEST must carry the -test suffix.
# Count files that start with 'spira-' but do NOT have '-test' suffix before their extension.
bad_files="$(cd "$DEST" && ls -1 spira-* 2>/dev/null \
              | grep -v '^spira-.*-test\.' || true)"
[ -z "$bad_files" ] \
    && ok "naming: no spira-* file without -test suffix in DEST" \
    || bad "naming: spira-* files without -test suffix found: $bad_files" ""

# Every spira-* file must end in -test.service or -test.timer.
test_files="$(cd "$DEST" && ls -1 spira-*-test.service spira-*-test.timer 2>/dev/null | wc -l | tr -d ' ')"
atleast "naming: at least 14 spira-*-test units installed" 14 "$test_files"

# Non-spira units must be present with their plain names.
want  "naming: cockpit-ensure.service present" "cockpit-ensure.service" "$(ls "$DEST")"
want  "naming: concierge.service present"      "concierge.service"      "$(ls "$DEST")"
want  "naming: beads-push.service present"     "beads-push.service"     "$(ls "$DEST")"

# The ENABLE calls must use per-instance names.
want  "naming: sentinel timer enabled with -test suffix" "spira-sentinel-test.timer" "$clean_log"
nowant "naming: no plain spira-sentinel.timer in enable" \
      "enable --now spira-sentinel.timer" "$clean_log"

# ==========================================================================
echo
echo "PRUNE — orphaned spira-watch-*-test.service is disabled:"
# ==========================================================================

# Watchers file: no rows (empty). The mock reports a stale per-instance watcher unit.
# The prune must disable it because it has no manifest row.
MOCK_WATCH_LIST="spira-watch-oldwatcher-test.service enabled"
prune_out="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE=1 \
              MOCK_WATCH_LIST="$MOCK_WATCH_LIST" \
              MOCK_WATCHERS="$FIXTURE/spira/watchers" inst)"
prune_rc=$?
prune_log="$(cat "$MOCK_LOG")"

iszero  "prune: exit 0 even when pruning an orphan"       "$prune_rc"
want    "prune: disable called on orphaned watcher"        \
        "disable" "$prune_log"
want    "prune: orphaned unit named in disable call"       \
        "spira-watch-oldwatcher-test.service" "$prune_log"
# The OLD template pattern must not appear anywhere in the systemctl calls.
nowant  "prune: no spira-watch@ template in systemctl log" \
        "spira-watch@" "$prune_log"

# ==========================================================================
echo
echo "WATCHER INSTALL — manifest row installs spira-watch-testview-test.service:"
# ==========================================================================

printf 'testview|daemon|/bin/true\n' > "$FIXTURE/spira/watchers"

# Seed DEST for the watcher scenario.
wrendered="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE=1 MOCK_WATCH_LIST= \
              MOCK_WATCHERS="$FIXTURE/spira/watchers" inst --render)"
current_unit=""
while IFS= read -r line; do
    if [[ "$line" =~ ^=====\ (.+)\ =====$ ]]; then
        current_unit="${BASH_REMATCH[1]}"; > "$DEST/$current_unit"
    elif [ -n "$current_unit" ]; then
        printf '%s\n' "$line" >> "$DEST/$current_unit"
    fi
done <<< "$wrendered"

# The --render output must contain a spira-watch-testview-test.service header.
want   "watcher install: --render includes spira-watch-testview-test.service header" \
       "===== spira-watch-testview-test.service =====" "$wrendered"
nowant "watcher install: --render has no @-template name" \
       "spira-watch@testview" "$wrendered"

watcher_out="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE=1 MOCK_WATCH_LIST= \
                MOCK_WATCHERS="$FIXTURE/spira/watchers" inst)"
watcher_rc=$?
watcher_log="$(cat "$MOCK_LOG")"

iszero  "watcher install: exit 0" "$watcher_rc"
want    "watcher install: installed spira-watch-testview-test.service" \
        "installed spira-watch-testview-test.service" "$watcher_out"
want    "watcher install: enabled spira-watch-testview-test.service" \
        "spira-watch-testview-test.service" "$watcher_log"
nowant  "watcher install: no @-template name in systemctl log" \
        "spira-watch@testview" "$watcher_log"
[ -f "$DEST/spira-watch-testview-test.service" ] \
    && ok "watcher install: unit file written to DEST" \
    || bad "watcher install: unit file missing from DEST" ""

# ==========================================================================
echo
echo "AEON ISOLATION — installing test does not block on prod aeons:"
# ==========================================================================

printf '# empty\n' > "$FIXTURE/spira/watchers"

# Prod aeons are running (named spira-aeon-*-prod.service). The test instance
# guard matches spira-aeon-*-test.service, so these should be invisible to it.
aeon_out="$(MOCK_AEONS="spira-aeon-builder-9999-prod.service" \
             MOCK_IS_ACTIVE=active MOCK_FORCE= MOCK_WATCH_LIST= \
             MOCK_WATCHERS="$FIXTURE/spira/watchers" inst)"
aeon_rc=$?

iszero "aeon isolation: exit 0 when prod aeons are live during test install" "$aeon_rc"

# Verify the guard was consulted for the test instance, not for prod.
aeon_log="$(cat "$MOCK_LOG")"
want   "aeon isolation: guard queries test-instance pattern" \
       "spira-aeon-*-test.service" "$aeon_log"
nowant "aeon isolation: guard does not query prod-instance pattern" \
       "spira-aeon-*-prod.service" "$aeon_log"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
