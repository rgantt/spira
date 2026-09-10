#!/usr/bin/env bash
# test-uninstall.sh — uninstall.sh: removes default tier, idempotent, instance-aware,
# stray-unit sweep reports a deliberately planted leftover.
#
#   ./test-uninstall.sh
#
# PROPERTIES UNDER TEST
# ---------------------
# 1. DEFAULT REMOVAL: units are stopped, disabled, and removed from UNITDIR;
#    linger is disabled; ~/.local/bin symlinks pointing to the harness are removed;
#    session hooks are removed from the agent settings file.
# 2. IDEMPOTENCY: a second run exits 0 with nothing to remove.
# 3. INSTANCE AWARENESS: refuses when multiple instances are installed and no
#    argument is given; accepts an explicit instance argument.
# 4. STRAY SWEEP: a unit file planted after owned.sh runs — not in the manifest —
#    is reported as a STRAY and not silently missed.
# 5. --purge: config and runtime directories are removed.
# 6. --dry-run: nothing is changed; exit 0.
# 7. PARTIAL INSTALL: absent artifacts do not cause non-zero exit.
#
# FAIL-FIRST: tested against the state BEFORE uninstall.sh existed to confirm
# the suite is not trivially green.
#
# covers: spira/uninstall.sh spira/owned.sh systemd/install.sh
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
isfile()  { [ -f "$2" ] && ok "$1" || bad "$1" "expected file: $2"; }
nofile()  { [ ! -e "$2" ] && ok "$1" || bad "$1" "expected absent: $2"; }

echo "test-uninstall.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fake git repo (for install.sh landref check bypass via SPIRA_INSTALL_FORCE).
# ---------------------------------------------------------------------------
FAKE_ORIGIN="$TMP/origin.git"
FAKE_REPO="$TMP/repo"
git init -q --bare -b main "$FAKE_ORIGIN" 2>/dev/null
git init -q -b main "$FAKE_REPO" 2>/dev/null
git -C "$FAKE_REPO" config user.email t@t
git -C "$FAKE_REPO" config user.name test
printf 'seed\n' > "$FAKE_REPO/f"
git -C "$FAKE_REPO" add f
git -C "$FAKE_REPO" commit -qm "seed" 2>/dev/null
git -C "$FAKE_REPO" remote add origin "$FAKE_ORIGIN"
git -C "$FAKE_REPO" push -q origin main 2>/dev/null
git -C "$FAKE_REPO" fetch -q origin 2>/dev/null
git -C "$FAKE_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

# ---------------------------------------------------------------------------
# Fixture: minimal harness tree with real scripts behind symlinks so that
# owned.sh can source conf.sh, watchd.sh, etc.
# ---------------------------------------------------------------------------
FIXTURE="$TMP/harness"
mkdir -p "$FIXTURE/systemd" "$FIXTURE/spira" "$FIXTURE/cockpit"

for f in "$HERE/../systemd/"*.service "$HERE/../systemd/"*.timer; do
    [ -e "$f" ] || continue
    ln -s "$f" "$FIXTURE/systemd/$(basename "$f")"
done
ln -s "$HERE/../systemd/install.sh"  "$FIXTURE/systemd/install.sh"
ln -s "$HERE/../systemd/units.sh"    "$FIXTURE/systemd/units.sh"
for f in conf.sh watchd.sh lib.sh owned.sh install-session-hook.sh; do
    [ -e "$HERE/$f" ] && ln -s "$HERE/$f" "$FIXTURE/spira/$f"
done
# Link the real uninstall.sh so the test drives it.
ln -s "$HERE/uninstall.sh" "$FIXTURE/spira/uninstall.sh"
printf '# empty\n' > "$FIXTURE/spira/repo-map.example"
printf '# empty\n' > "$FIXTURE/spira/watchers"

# Stub install-intake.sh — alert drop-ins are not the focus here; we just need
# it to not fail.
printf '#!/usr/bin/env bash\necho "install-intake: $*"\n' > "$FIXTURE/spira/install-intake.sh"
chmod +x "$FIXTURE/spira/install-intake.sh"

# Stub cockpit/layout.sh: record calls; do not kill any real sessions.
mkdir -p "$FIXTURE/cockpit"
cat > "$FIXTURE/cockpit/layout.sh" <<'LAYOUT'
#!/usr/bin/env bash
printf 'layout.sh: %s\n' "$*" >> "${LAYOUT_LOG:-/dev/null}"
exit 0
LAYOUT
chmod +x "$FIXTURE/cockpit/layout.sh"

# Directories wired into the test environment.
DEST="$TMP/home/.config/systemd/user"
SPIRA_RUN_DIR="$TMP/run"
CONF_DIR="$TMP/home/.config/spira"
MOCK_BIN="$TMP/mock-bin"
LOCAL_BIN="$TMP/home/.local/bin"
LAYOUT_LOG="$TMP/layout.log"
mkdir -p "$DEST" "$SPIRA_RUN_DIR" "$CONF_DIR" "$MOCK_BIN" "$LOCAL_BIN"

MOCK_LOG="$TMP/systemctl.log"
LINGER_LOG="$TMP/loginctl.log"

# ---------------------------------------------------------------------------
# Mock systemctl — records calls; stop/disable always succeed.
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "$*" in
    *list-units*) printf '' ;;
    *is-active*)  printf 'inactive\n' ;;
    *daemon-reload*) ;;
    *) ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/systemctl"

# Mock loginctl — records calls; show-user returns "Linger=yes" when flagged.
cat > "$MOCK_BIN/loginctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LINGER_LOG}"
case "$*" in
    *show-user*Linger*) printf 'Linger=%s\n' "${MOCK_LINGER:-yes}" ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/loginctl"

# Mock tmux — session hooks check reads it; uninstall uses cockpit/layout.sh only.
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/tmux"
chmod +x "$MOCK_BIN/tmux"

# ---------------------------------------------------------------------------
# un [args] — run uninstall.sh in the controlled environment.
# Always uses the 'test' instance. Passes --yes to skip the confirmation prompt.
# ---------------------------------------------------------------------------
un() {
    > "$MOCK_LOG"; > "$LINGER_LOG"; > "$LAYOUT_LOG"
    env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_RUN=$SPIRA_RUN_DIR" \
        "SPIRA_HOME=$FIXTURE/spira" \
        "SPIRA_PROD=$FIXTURE/spira" \
        "SPIRA_REPO=$FAKE_REPO" \
        "SPIRA_COCKPIT=$REAL_COCKPIT" \
        "SPIRA_INSTANCE=test" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_SYSTEMCTL=$MOCK_BIN/systemctl" \
        "SPIRA_LOGINCTL=$MOCK_BIN/loginctl" \
        "SPIRA_TMUX=$MOCK_BIN/tmux" \
        "MOCK_LOG=$MOCK_LOG" \
        "LINGER_LOG=$LINGER_LOG" \
        "LAYOUT_LOG=$LAYOUT_LOG" \
        "MOCK_LINGER=${MOCK_LINGER:-yes}" \
        bash "$FIXTURE/spira/uninstall.sh" test --yes "$@" 2>&1
}

# ---------------------------------------------------------------------------
# Seed DEST with per-instance unit files so uninstall has something to remove.
# Use the same rendering path as install tests: run --render, write the files.
# ---------------------------------------------------------------------------
_seed_units() {
    local rendered rc
    rendered="$(env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_RUN=$SPIRA_RUN_DIR" \
        "SPIRA_HOME=$FIXTURE/spira" \
        "SPIRA_PROD=$FIXTURE/spira" \
        "SPIRA_REPO=$FAKE_REPO" \
        "SPIRA_COCKPIT=$REAL_COCKPIT" \
        "SPIRA_INSTANCE=test" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_SYSTEMCTL=$MOCK_BIN/systemctl" \
        "SPIRA_INSTALL_FORCE=1" \
        bash "$FIXTURE/systemd/install.sh" test --render 2>&1)"
    rc=$?
    if [ "$rc" != 0 ]; then
        printf 'fixture: install.sh --render failed (rc=%s)\n' "$rc" >&2
        printf '%s\n' "$rendered" >&2
        return 1
    fi
    local current_unit=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^=====\ (.+)\ =====$ ]]; then
            current_unit="${BASH_REMATCH[1]}"; > "$DEST/$current_unit"
        elif [ -n "$current_unit" ]; then
            printf '%s\n' "$line" >> "$DEST/$current_unit"
        fi
    done <<< "$rendered"
}

# ---------------------------------------------------------------------------
# Seed agent settings file with fake session hooks.
# ---------------------------------------------------------------------------
SETTINGS="$TMP/home/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
_un_hook="$FIXTURE/spira/hooks/session.sh"
mkdir -p "$FIXTURE/spira/hooks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_un_hook"; chmod +x "$_un_hook"
cat > "$SETTINGS" <<JSON
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "$_un_hook", "timeout": 10}]}
    ],
    "PostCompact": [
      {"hooks": [{"type": "command", "command": "$_un_hook", "timeout": 10}]}
    ]
  }
}
JSON

# Seed ~/.local/bin symlinks pointing into the harness.
ln -sf "$FIXTURE/cockpit/remote-cockpit" "$LOCAL_BIN/cockpit-remote" 2>/dev/null || \
    ln -sf "$FIXTURE/cockpit/layout.sh" "$LOCAL_BIN/cockpit-remote"

# ==========================================================================
echo
echo "DEFAULT REMOVAL — units, linger, symlinks, session hooks:"
# ==========================================================================

_seed_units || { printf 'fixture: seeding failed\n'; exit 1; }

_unit_count="$(ls -1 "$DEST"/*.service "$DEST"/*.timer 2>/dev/null | wc -l | tr -d ' ')"
[ "$_unit_count" -gt 0 ] || { printf 'fixture: no units seeded in DEST\n'; exit 1; }

out="$(un)"
rc=$?

iszero "default: exit 0" "$rc"

# Units must be gone from DEST.
_remaining="$(ls -1 "$DEST"/spira-*-test.service "$DEST"/spira-*-test.timer 2>/dev/null | wc -l | tr -d ' ')"
[ "$_remaining" -eq 0 ] \
    && ok  "default: unit files removed from DEST" \
    || bad "default: $( _remaining ) unit files remain in DEST" "$_remaining"

# systemctl stop and disable must have been called.
want "default: stop called on units"    "stop"    "$(cat "$MOCK_LOG")"
want "default: disable called on units" "disable" "$(cat "$MOCK_LOG")"

# Linger must have been disabled.
want "default: loginctl disable-linger called" "disable-linger" "$(cat "$LINGER_LOG")"

# ~/.local/bin/cockpit-remote symlink must be gone.
nofile "default: cockpit-remote symlink removed" "$LOCAL_BIN/cockpit-remote"

# Session hooks must be removed from settings.
_hook_count="$(python3 -c "
import json, sys
d = json.load(open('$SETTINGS'))
h = d.get('hooks', {})
print(sum(len(v) for v in h.values()))
" 2>/dev/null || echo 999)"
[ "$_hook_count" -eq 0 ] \
    && ok  "default: session hooks removed from settings" \
    || bad "default: session hooks not all removed (remaining entries: $_hook_count)" ""

# ==========================================================================
echo
echo "IDEMPOTENCY — second run exits 0 with nothing to remove:"
# ==========================================================================

out2="$(un)"
rc2=$?
iszero "idempotency: second run exits 0" "$rc2"

# ==========================================================================
echo
echo "INSTANCE AWARENESS — refuses multiple instances; accepts explicit:"
# ==========================================================================

# Plant two sentinel files for two instances to trigger the refusal.
> "$DEST/spira-sentinel-prod.service"
> "$DEST/spira-sentinel-test.service"

multi_out="$(env -i \
    "PATH=$PATH" \
    "HOME=$TMP/home" \
    SPIRA_CONF=/nonexistent \
    "SPIRA_PATH=$MOCK_BIN" \
    "SPIRA_RUN=$SPIRA_RUN_DIR" \
    "SPIRA_HOME=$FIXTURE/spira" \
    "SPIRA_PROD=$FIXTURE/spira" \
    "SPIRA_REPO=$FAKE_REPO" \
    "SPIRA_COCKPIT=$REAL_COCKPIT" \
    SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
    "SPIRA_SYSTEMCTL=$MOCK_BIN/systemctl" \
    "SPIRA_LOGINCTL=$MOCK_BIN/loginctl" \
    "SPIRA_TMUX=$MOCK_BIN/tmux" \
    bash "$FIXTURE/spira/uninstall.sh" 2>&1)"
multi_rc=$?

nonzero "instance: refuses when multiple instances, no argument" "$multi_rc"
want    "instance: names the instances found" "prod" "$multi_out"
want    "instance: names the instances found" "test" "$multi_out"

# Explicit argument should be accepted even with multiple sentinels.
explicit_out="$(env -i \
    "PATH=$PATH" \
    "HOME=$TMP/home" \
    SPIRA_CONF=/nonexistent \
    "SPIRA_PATH=$MOCK_BIN" \
    "SPIRA_RUN=$SPIRA_RUN_DIR" \
    "SPIRA_HOME=$FIXTURE/spira" \
    "SPIRA_PROD=$FIXTURE/spira" \
    "SPIRA_REPO=$FAKE_REPO" \
    "SPIRA_COCKPIT=$REAL_COCKPIT" \
    "SPIRA_INSTANCE=test" \
    SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
    "SPIRA_SYSTEMCTL=$MOCK_BIN/systemctl" \
    "SPIRA_LOGINCTL=$MOCK_BIN/loginctl" \
    "SPIRA_TMUX=$MOCK_BIN/tmux" \
    "MOCK_LINGER=yes" \
    bash "$FIXTURE/spira/uninstall.sh" test --yes 2>&1)"
explicit_rc=$?
iszero "instance: explicit 'test' arg accepted" "$explicit_rc"

# Clean up planted sentinels.
rm -f "$DEST/spira-sentinel-prod.service" "$DEST/spira-sentinel-test.service"

# ==========================================================================
echo
echo "STRAY SWEEP — planted leftover not in manifest is reported:"
# ==========================================================================

# Re-seed units so the removal pass runs and we get to the sweep.
_seed_units || { printf 'fixture: re-seed failed\n'; exit 1; }

# Plant a spira-* unit that owned.sh will never declare — simulating a file left
# by an older harness version.
STRAY_UNIT="$DEST/spira-legacy-shard-test.service"
printf '[Unit]\nDescription=stray legacy unit for test\n' > "$STRAY_UNIT"

stray_out="$(un)"
stray_rc=$?

iszero "sweep: exit 0 even when stray unit found" "$stray_rc"
want   "sweep: stray unit is reported" "STRAY" "$stray_out"
want   "sweep: stray unit name appears in report" "spira-legacy-shard-test.service" "$stray_out"

# The stray should NOT have been removed (report only, no silent deletion).
isfile "sweep: stray unit file NOT removed (report only)" "$STRAY_UNIT"
rm -f "$STRAY_UNIT"

# ==========================================================================
echo
echo "--purge — config and runtime directories removed:"
# ==========================================================================

_seed_units || { printf 'fixture: re-seed for purge failed\n'; exit 1; }
mkdir -p "$CONF_DIR"
printf 'SPIRA_INSTANCE=test\n' > "$CONF_DIR/spira.conf"
mkdir -p "$SPIRA_RUN_DIR/archive"

purge_out="$(env -i \
    "PATH=$PATH" \
    "HOME=$TMP/home" \
    SPIRA_CONF=/nonexistent \
    "SPIRA_PATH=$MOCK_BIN" \
    "SPIRA_RUN=$SPIRA_RUN_DIR" \
    "SPIRA_HOME=$FIXTURE/spira" \
    "SPIRA_PROD=$FIXTURE/spira" \
    "SPIRA_REPO=$FAKE_REPO" \
    "SPIRA_COCKPIT=$REAL_COCKPIT" \
    "SPIRA_INSTANCE=test" \
    SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
    "SPIRA_SYSTEMCTL=$MOCK_BIN/systemctl" \
    "SPIRA_LOGINCTL=$MOCK_BIN/loginctl" \
    "SPIRA_TMUX=$MOCK_BIN/tmux" \
    "MOCK_LINGER=no" \
    bash "$FIXTURE/spira/uninstall.sh" test --yes --purge 2>&1)"
purge_rc=$?

iszero "purge: exit 0" "$purge_rc"
nofile "purge: config file removed" "$CONF_DIR/spira.conf"
[ ! -d "$SPIRA_RUN_DIR" ] \
    && ok  "purge: runtime dir removed" \
    || bad "purge: runtime dir still present" ""

# Recreate SPIRA_RUN_DIR so subsequent sub-tests work.
mkdir -p "$SPIRA_RUN_DIR"

# ==========================================================================
echo
echo "--dry-run — nothing changed:"
# ==========================================================================

_seed_units || { printf 'fixture: re-seed for dry-run failed\n'; exit 1; }
_unit_before="$(ls -1 "$DEST" 2>/dev/null | wc -l | tr -d ' ')"

dryrun_out="$(env -i \
    "PATH=$PATH" \
    "HOME=$TMP/home" \
    SPIRA_CONF=/nonexistent \
    "SPIRA_PATH=$MOCK_BIN" \
    "SPIRA_RUN=$SPIRA_RUN_DIR" \
    "SPIRA_HOME=$FIXTURE/spira" \
    "SPIRA_PROD=$FIXTURE/spira" \
    "SPIRA_REPO=$FAKE_REPO" \
    "SPIRA_COCKPIT=$REAL_COCKPIT" \
    "SPIRA_INSTANCE=test" \
    SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
    "SPIRA_SYSTEMCTL=$MOCK_BIN/systemctl" \
    "SPIRA_LOGINCTL=$MOCK_BIN/loginctl" \
    "SPIRA_TMUX=$MOCK_BIN/tmux" \
    bash "$FIXTURE/spira/uninstall.sh" test --dry-run 2>&1)"
dryrun_rc=$?

_unit_after="$(ls -1 "$DEST" 2>/dev/null | wc -l | tr -d ' ')"

iszero "dry-run: exit 0"                     "$dryrun_rc"
want   "dry-run: reports DRY RUN"            "DRY RUN"  "$dryrun_out"
[ "$_unit_before" = "$_unit_after" ] \
    && ok  "dry-run: unit count unchanged ($_unit_before files)" \
    || bad "dry-run: unit count changed from $_unit_before to $_unit_after" ""

# ==========================================================================
echo
echo "PARTIAL INSTALL — absent artifacts do not cause non-zero exit:"
# ==========================================================================

# Wipe DEST entirely to simulate a partial install.
rm -rf "$DEST"
mkdir -p "$DEST"

partial_out="$(un)"
partial_rc=$?

iszero "partial: exit 0 when DEST is empty" "$partial_rc"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
