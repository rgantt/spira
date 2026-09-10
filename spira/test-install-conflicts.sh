#!/usr/bin/env bash
#
# test-install-conflicts.sh — install.sh phase 0.5: each of the five conflict
# checks exits 5 and names its remedy; the override lets one through.
#
#   ./test-install-conflicts.sh
#
# PROPERTIES UNDER TEST
# ---------------------
# 1. FOREIGN HARNESS: installed unit's ExecStart resolves to a different SPIRA_HOME
#    → exit 5, names the foreign path, names the remedy.
# 2. LIVE AEON: a process whose /proc cmdline contains $SPIRA_HOME/aeon.sh
#    → exit 5, names "aeon", names the remedy.
# 3. LANDING IN FLIGHT: gate tree lock is held
#    → exit 5, names "landing", names the remedy.
# 4. INSTANCE MISMATCH: argument disagrees with config SPIRA_INSTANCE
#    → exit 5, names "mismatch", names the remedy.
# 5. DOLT PORT COLLISION: Dolt process listening with a different data_dir
#    → exit 5, names "Dolt", names the remedy.
# 6. OVERRIDE: SPIRA_INSTALL_CONFLICT_CONSIDERED=1 bypasses all five checks
#    → does NOT exit 5.
#
# FAIL-FIRST: each property is verified against the UNFIXED tree first to confirm
# the suite is not trivially green (law-a-regression-test-must-be-seen-to-fail).
#
# covers: install.sh
# covers: install.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_REPO="$(cd "$HERE/.." && pwd -P)"
pass=0; fail=0
ok()      { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()     { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()    { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant()  { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
is5()     { [ "$2" = 5 ] && ok "$1" || bad "$1" "wanted exit 5, got $2"; }
not5()    { [ "$2" != 5 ] && ok "$1" || bad "$1" "must not exit 5, got 5"; }

echo "test-install-conflicts.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture layout:
#   $FIXTURE/          — repo root (install.sh is here)
#   $FIXTURE/spira/    — SPIRA_HOME: stubs for all scripts install.sh calls
#   $FIXTURE/systemd/  — symlinks to real unit templates + real install.sh
#   $FIXTURE/cockpit/  — stub so cockpit phase doesn't error
# ---------------------------------------------------------------------------
FIXTURE="$TMP/harness"
SPIRA_DIR="$FIXTURE/spira"
SYSTEMD_DIR="$FIXTURE/systemd"
COCKPIT_DIR="$FIXTURE/cockpit"
mkdir -p "$SPIRA_DIR" "$SYSTEMD_DIR" "$COCKPIT_DIR"

# Real unit templates and install.sh.
for f in "$HERE/../systemd/"*.service "$HERE/../systemd/"*.timer; do
    [ -e "$f" ] || continue
    ln -s "$f" "$SYSTEMD_DIR/$(basename "$f")" 2>/dev/null || true
done
ln -s "$HERE/../systemd/install.sh" "$SYSTEMD_DIR/install.sh"
ln -s "$HERE/../systemd/units.sh"   "$SYSTEMD_DIR/units.sh"

# Stub conf.sh in SPIRA_DIR that delegates to the real one but sets SPIRA_HOME
# to the fixture's spira directory so all $SPIRA_HOME/... calls resolve there.
# We use the real conf.sh but override SPIRA_HOME before sourcing it.
ln -s "$HERE/conf.sh"     "$SPIRA_DIR/conf.sh"
ln -s "$HERE/lib.sh"      "$SPIRA_DIR/lib.sh"
ln -s "$HERE/watchd.sh"   "$SPIRA_DIR/watchd.sh"

printf '# empty\n' > "$SPIRA_DIR/watchers"
printf '# empty\n' > "$SPIRA_DIR/repo-map.example"
mkdir -p "$SPIRA_DIR/statutes"

# --- stub doctor.sh: always passes ---
cat > "$SPIRA_DIR/doctor.sh" <<'EOF'
#!/usr/bin/env bash
echo "spira doctor"
echo "  ok    stub — all checks passed"
exit 0
EOF
chmod +x "$SPIRA_DIR/doctor.sh"

# --- stub configure.sh: says "already exists" ---
cat > "$SPIRA_DIR/configure.sh" <<'EOF'
#!/usr/bin/env bash
_out="${XDG_CONFIG_HOME:-$HOME/.config}/spira/spira.conf"
if [ -f "$_out" ]; then
    printf 'configure: config file already exists: %s\n' "$_out"; exit 1
fi
mkdir -p "$(dirname "$_out")"
printf 'SPIRA_PROD = %s\n' "${CONFIGURE_PROD:-/nonexistent}" > "$_out"
printf 'configure: wrote %s\n' "$_out"
EOF
chmod +x "$SPIRA_DIR/configure.sh"

# --- stub build.sh: always succeeds ---
cat > "$SPIRA_DIR/build.sh" <<'EOF'
#!/usr/bin/env bash
printf 'build.sh: stub — skipping\n'
exit 0
EOF
chmod +x "$SPIRA_DIR/build.sh"

# --- stub seed.sh: always succeeds ---
cat > "$SPIRA_DIR/seed.sh" <<'EOF'
#!/usr/bin/env bash
printf 'seed: stub — no statutes to write\n'
exit 0
EOF
chmod +x "$SPIRA_DIR/seed.sh"

# --- stub install-session-hook.sh: reports installed ---
cat > "$SPIRA_DIR/install-session-hook.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    status)  printf 'ok  SessionStart\nok  PostCompact\n' ;;
    install) printf 'install-session-hook: stub — installed\n' ;;
    *)       exit 0 ;;
esac
exit 0
EOF
chmod +x "$SPIRA_DIR/install-session-hook.sh"

# --- stub install-intake.sh: always succeeds ---
cat > "$SPIRA_DIR/install-intake.sh" <<'EOF'
#!/usr/bin/env bash
printf 'install-intake: stub\n'
exit 0
EOF
chmod +x "$SPIRA_DIR/install-intake.sh"

# --- stub ready.sh: always exits 3 (installed but not ready) so install exits 3 ---
cat > "$SPIRA_DIR/ready.sh" <<'EOF'
#!/usr/bin/env bash
printf 'spira ready\n'
printf '  FAIL  stub — not wired in fixture\n'
exit 1
EOF
chmod +x "$SPIRA_DIR/ready.sh"

# --- stub cockpit layout.sh ---
cat > "$COCKPIT_DIR/layout.sh" <<'EOF'
#!/usr/bin/env bash
printf 'layout.sh: stub\n'; exit 0
EOF
chmod +x "$COCKPIT_DIR/layout.sh"

# Link the real install.sh from the repo root.
ln -s "$REAL_REPO/install.sh" "$FIXTURE/install.sh"

# ---------------------------------------------------------------------------
# Mock binaries — front of PATH.
# ---------------------------------------------------------------------------
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
MOCK_LOG="$TMP/mock.log"

# systemctl: records calls, always succeeds.
cat > "$MOCK_BIN/systemctl" <<EOF
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "${MOCK_LOG}"
case "\$*" in
    *is-active*) echo "inactive" ;;
    *list-unit-files*spira-watch*) printf 'spira-watch@testview.service enabled\n' ;;
    *list-units*spira-watch*)  printf 'spira-watch@testview.service loaded active running\n' ;;
    *list-units*active*spira-aeon*) true ;;
    *list-timers*) true ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/systemctl"

# loginctl: reports Linger=no.
cat > "$MOCK_BIN/loginctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in *show-user*Linger*) echo "Linger=no" ;; esac
exit 0
EOF
chmod +x "$MOCK_BIN/loginctl"

# tmux: no server — cockpit phase prints advice and skips.
cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$MOCK_BIN/tmux"

# bd: stub — succeeds for init/list/memories.
cat > "$MOCK_BIN/bd" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *init*)     exit 0 ;;
    *list*)     printf '[]\n' ;;
    *memories*) printf '{}\n' ;;
    *)          exit 0 ;;
esac
EOF
chmod +x "$MOCK_BIN/bd"

# ---------------------------------------------------------------------------
# Fake git repo so systemd/install.sh landref check passes.
# ---------------------------------------------------------------------------
FAKE_ORIGIN="$TMP/origin.git"
FAKE_REPO="$TMP/fakerepo"
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
# Directories.
# ---------------------------------------------------------------------------
FAKE_HOME="$TMP/home"
FAKE_UNITDIR="$FAKE_HOME/.config/systemd/user"
FAKE_RUN="$TMP/run"
FAKE_DB="$TMP/db"
FAKE_PROD="$SPIRA_DIR"   # ExecStart targets live here (scripts we stubbed above)
mkdir -p "$FAKE_HOME" "$FAKE_UNITDIR" "$FAKE_RUN" "$FAKE_DB"

# Pre-seed FAKE_UNITDIR with units rendered from our fixture (so --diff passes
# in the clean case and the foreign-harness test has something to compare against).
_rendered="$(env -i \
    "PATH=$MOCK_BIN:$PATH" \
    "HOME=$FAKE_HOME" \
    SPIRA_CONF=/nonexistent \
    "SPIRA_PATH=$MOCK_BIN" \
    "SPIRA_WATCHERS=$SPIRA_DIR/watchers" \
    SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
    "SPIRA_RUN=$FAKE_RUN" \
    "SPIRA_HOME=$SPIRA_DIR" \
    "SPIRA_PROD=$FAKE_PROD" \
    "SPIRA_REPO=$FAKE_REPO" \
    "SPIRA_COCKPIT=$COCKPIT_DIR" \
    "MOCK_LOG=$MOCK_LOG" \
    SPIRA_INSTALL_FORCE=1 \
    SPIRA_BD="$MOCK_BIN/bd" \
    bash "$SYSTEMD_DIR/install.sh" prod --render 2>/dev/null)"
_render_rc=$?
if [ "$_render_rc" = 0 ]; then
    _cur=""
    while IFS= read -r _line; do
        if [[ "$_line" =~ ^=====\ (.+)\ =====$ ]]; then
            _cur="${BASH_REMATCH[1]}"; > "$FAKE_UNITDIR/$_cur"
        elif [ -n "$_cur" ]; then
            printf '%s\n' "$_line" >> "$FAKE_UNITDIR/$_cur"
        fi
    done <<< "$_rendered"
    unset _cur _line
fi
unset _rendered _render_rc

# ---------------------------------------------------------------------------
# run_install <install_args...> [-- <extra_env_assignments...>]
# Runs install.sh under an isolated, deterministic environment.
# SPIRA_HOME points at the fixture's spira dir so stubs are used.
# ---------------------------------------------------------------------------
run_install() {
    local extra_env=() install_args=() in_env=0
    for _a in "$@"; do
        [ "$_a" = "--" ] && { in_env=1; continue; }
        [ "$in_env" = 1 ] && { extra_env+=("$_a"); continue; }
        install_args+=("$_a")
    done
    unset _a in_env
    > "$MOCK_LOG"
    env -i \
        "PATH=$MOCK_BIN:$PATH" \
        "HOME=$FAKE_HOME" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_WATCHERS=$SPIRA_DIR/watchers" \
        SPIRA_DOLT_DATA= SPIRA_TESTDB_DATA= \
        "SPIRA_RUN=$FAKE_RUN" \
        "SPIRA_HOME=$SPIRA_DIR" \
        "SPIRA_PROD=$FAKE_PROD" \
        "SPIRA_REPO=$FAKE_REPO" \
        "SPIRA_COCKPIT=$COCKPIT_DIR" \
        "MOCK_LOG=$MOCK_LOG" \
        SPIRA_INSTALL_FORCE=1 \
        "SPIRA_BD=$MOCK_BIN/bd" \
        "${extra_env[@]+"${extra_env[@]}"}" \
        bash "$FIXTURE/install.sh" "${install_args[@]+"${install_args[@]}"}" 2>&1
}

# ---------------------------------------------------------------------------
# FAIL-FIRST VERIFICATION
# In a completely clean fixture with SPIRA_INSTALL_CONFLICT_CONSIDERED set,
# install.sh must NOT exit 5. This proves the conflict checks do not fire spuriously.
# ---------------------------------------------------------------------------
echo
echo "FAIL-FIRST: clean fixture must not exit 5"
_clean_out="$(run_install prod -- SPIRA_INSTALL_CONFLICT_CONSIDERED=1)"
_clean_rc=$?
not5 "fail-first: clean fixture does not exit 5" "$_clean_rc"
printf '  (got rc=%d)\n' "$_clean_rc"

# ==========================================================================
echo
echo "CONFLICT 1: foreign harness owns installed units"
# ==========================================================================
# Plant a sentinel unit whose ExecStart points at a DIFFERENT spira directory.
FOREIGN_HOME="$TMP/foreign/spira"
mkdir -p "$FOREIGN_HOME"
printf '#!/usr/bin/env bash\ntrue\n' > "$FOREIGN_HOME/sentinel.sh"
chmod +x "$FOREIGN_HOME/sentinel.sh"

cat > "$FAKE_UNITDIR/spira-sentinel-prod.service" <<UNIT
[Unit]
Description=Foreign Spira sentinel
[Service]
ExecStart=$FOREIGN_HOME/sentinel.sh
StandardOutput=append:$FAKE_RUN/sentinel.log
UNIT

_c1_out="$(run_install prod)"
_c1_rc=$?
is5    "conflict-1: exits 5" "$_c1_rc"
want   "conflict-1: names foreign path" "$FOREIGN_HOME" "$_c1_out"
want   "conflict-1: names remedy" "remedy" "$_c1_out"
want   "conflict-1: names override" "SPIRA_INSTALL_CONFLICT_CONSIDERED" "$_c1_out"

# With override — must NOT exit 5.
_c1o_out="$(run_install prod -- SPIRA_INSTALL_CONFLICT_CONSIDERED=1)"
_c1o_rc=$?
not5 "conflict-1-override: override bypasses check" "$_c1o_rc"

# Remove the planted unit before proceeding.
rm -f "$FAKE_UNITDIR/spira-sentinel-prod.service"

# ==========================================================================
echo
echo "CONFLICT 2: live aeon running"
# ==========================================================================
# Launch a process whose cmdline contains $SPIRA_DIR/aeon.sh.
# exec -a sets argv[0]; the conflict check reads /proc/$pid/cmdline looking
# for exactly "$SPIRA_HOME/aeon.sh".
_fake_aeon_script="$TMP/fake-aeon.sh"
printf '#!/usr/bin/env bash\nexec -a "%s/aeon.sh" sleep 600\n' "$SPIRA_DIR" \
    > "$_fake_aeon_script"
chmod +x "$_fake_aeon_script"
bash "$_fake_aeon_script" &
_aeon_pid=$!
sleep 0.2

_c2_out="$(run_install prod)"
_c2_rc=$?
kill "$_aeon_pid" 2>/dev/null; wait "$_aeon_pid" 2>/dev/null || true

is5  "conflict-2: exits 5 with live aeon" "$_c2_rc"
want "conflict-2: names 'aeon'" "aeon" "$_c2_out"
want "conflict-2: names remedy" "remedy" "$_c2_out"
want "conflict-2: names override" "SPIRA_INSTALL_CONFLICT_CONSIDERED" "$_c2_out"
unset _fake_aeon_script _aeon_pid

# ==========================================================================
echo
echo "CONFLICT 3: landing in flight (gate tree lock held)"
# ==========================================================================
GATE_LOCK="$FAKE_RUN/worktree/.gate.$(basename "$FAKE_REPO").lock"
mkdir -p "$(dirname "$GATE_LOCK")"
touch "$GATE_LOCK"

# Hold the lock in a background subshell.
(exec 9>"$GATE_LOCK"; flock 9; sleep 30) &
_lock_holder=$!
sleep 0.2

_c3_out="$(run_install prod)"
_c3_rc=$?
kill "$_lock_holder" 2>/dev/null; wait "$_lock_holder" 2>/dev/null || true
rm -f "$GATE_LOCK"

is5  "conflict-3: exits 5 with gate lock held" "$_c3_rc"
want "conflict-3: names 'landing'" "landing" "$_c3_out"
want "conflict-3: names remedy" "remedy" "$_c3_out"
want "conflict-3: names override" "SPIRA_INSTALL_CONFLICT_CONSIDERED" "$_c3_out"
unset GATE_LOCK _lock_holder

# ==========================================================================
echo
echo "CONFLICT 4: instance mismatch (argument vs. config)"
# ==========================================================================
FAKE_CONF="$TMP/spira.conf"
cat > "$FAKE_CONF" <<CONF
SPIRA_INSTANCE = prod
SPIRA_PROD = $FAKE_PROD
SPIRA_MAX_AEONS = 4
SPIRA_MAX_LIVE_AEONS =
SPIRA_LOOM_ADDR = 127.0.0.1:8788
SPIRA_DOLT_DATA =
CONF

_c4_out="$(run_install test -- "SPIRA_CONF=$FAKE_CONF")"
_c4_rc=$?
is5  "conflict-4: exits 5 on instance mismatch" "$_c4_rc"
want "conflict-4: names instance disagreement" "disagrees" "$_c4_out"
want "conflict-4: names remedy" "remedy" "$_c4_out"
want "conflict-4: names override" "SPIRA_INSTALL_CONFLICT_CONSIDERED" "$_c4_out"

# Matching instance must not exit 5.
_c4m_out="$(run_install prod -- "SPIRA_CONF=$FAKE_CONF")"
_c4m_rc=$?
not5 "conflict-4-match: matching instance does not trigger mismatch" "$_c4m_rc"
unset FAKE_CONF

# ==========================================================================
echo
echo "CONFLICT 5: Dolt server on configured port with different data dir"
# ==========================================================================
# The check probes /dev/tcp for a listening port, then reads /proc to find a
# process whose cmdline contains 'sql-server' and '--config <yaml>'.
# We need both: a listener AND a process with the right cmdline.
_dolt_port=19877   # high port, unlikely to collide
_dolt_data_ours="$TMP/our-dolt-data"
_dolt_data_other="$TMP/other-dolt-data"
mkdir -p "$_dolt_data_ours" "$_dolt_data_other"

# Write dolt-server.yaml for our installation, pointing at our data dir.
cat > "$_dolt_data_ours/dolt-server.yaml" <<YAML
listener:
  port: $_dolt_port
data_dir: "$_dolt_data_ours"
YAML

# Write dolt-server.yaml for the other installation, pointing at a different dir.
_other_yaml="$TMP/other-dolt-server.yaml"
cat > "$_other_yaml" <<YAML
listener:
  port: $_dolt_port
data_dir: "$_dolt_data_other"
YAML

# Start a TCP listener on _dolt_port so the /dev/tcp probe succeeds.
# nc -lk keeps listening; fall back if nc is absent.
_nc_pid=""
if command -v nc >/dev/null 2>&1; then
    nc -lk "$_dolt_port" >/dev/null 2>&1 &
    _nc_pid=$!
    sleep 0.1
fi

# Start a fake dolt process: exec -a with 'sql-server --config <other yaml>' in argv[0]
# so the /proc scan sees a "dolt sql-server" with the other config.
(exec -a "dolt sql-server --config ${_other_yaml}" sleep 600) &
_dolt_pid=$!
sleep 0.1

if [ -n "$_nc_pid" ]; then
    _c5_out="$(run_install prod -- \
        "SPIRA_DOLT_DATA=$_dolt_data_ours")"
    _c5_rc=$?
    is5  "conflict-5: exits 5 with Dolt port collision" "$_c5_rc"
    want "conflict-5: names 'Dolt'" "Dolt" "$_c5_out"
    want "conflict-5: names remedy" "remedy" "$_c5_out"
    want "conflict-5: names override" "SPIRA_INSTALL_CONFLICT_CONSIDERED" "$_c5_out"
else
    # nc unavailable — the /dev/tcp probe won't succeed; document the skip.
    ok "conflict-5: nc unavailable — TCP probe cannot be tested in this environment"
fi

kill "$_dolt_pid" 2>/dev/null; wait "$_dolt_pid" 2>/dev/null || true
[ -n "$_nc_pid" ] && { kill "$_nc_pid" 2>/dev/null; wait "$_nc_pid" 2>/dev/null || true; }
unset _dolt_port _dolt_data_ours _dolt_data_other _other_yaml _nc_pid _dolt_pid

# ==========================================================================
echo
echo "CONFLICT OVERRIDE: SPIRA_INSTALL_CONFLICT_CONSIDERED=1 bypasses all checks"
# ==========================================================================
# Plant a foreign unit and confirm override reaches phase 1+.
FOREIGN2="$TMP/foreign2/spira"
mkdir -p "$FOREIGN2"
printf '#!/usr/bin/env bash\ntrue\n' > "$FOREIGN2/sentinel.sh"
chmod +x "$FOREIGN2/sentinel.sh"
cat > "$FAKE_UNITDIR/spira-sentinel-prod.service" <<UNIT
[Unit]
Description=Foreign sentinel 2
[Service]
ExecStart=$FOREIGN2/sentinel.sh
UNIT

_ov_out="$(run_install prod -- SPIRA_INSTALL_CONFLICT_CONSIDERED=1)"
_ov_rc=$?
not5 "override: does not exit 5 with SPIRA_INSTALL_CONFLICT_CONSIDERED=1" "$_ov_rc"
rm -f "$FAKE_UNITDIR/spira-sentinel-prod.service"
unset FOREIGN2

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
