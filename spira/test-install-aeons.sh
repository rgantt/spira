#!/usr/bin/env bash
#
# test-install-aeons.sh — install.sh restarts only what changed; drains oneshots;
# never touches transient aeon units; exits 0 with aeons live on a no-op install.
#
#   ./test-install-aeons.sh
#
# THE PROPERTIES UNDER TEST
# -------------------------
# 1. NO-OP INSTALL: when nothing changed and all units are active, install.sh
#    restarts nothing and exits 0, even when live aeon units are present.
# 2. SELECTIVE RESTART: only the unit(s) whose rendered content changed are
#    restarted; others are skipped with an "unchanged" log line.
# 3. AEON SAFETY: no systemctl call ever names a spira-aeon-* unit. Transient
#    aeons are unreachable from UNITS and ENABLE by construction.
# 4. ONESHOT DRAIN: when a changed timer's backing service is a running oneshot,
#    install.sh waits for it to finish before restarting.
# 5. WATCH PRESERVATION: a spira-watch@ instance whose name IS in the manifest
#    is not disabled by the manifest-prune step.
# 6. END-STATE CHECK: after install, install.sh exits non-zero if any enabled
#    unit is not active.
#
# THE FIXTURE USES A MOCK systemctl THAT RECORDS CALLS AND RETURNS CONTROLLED
# OUTPUT.  Pin a non-default SPIRA_RUN so nothing touches the operator's live
# directory (law-gates-run-in-a-clean-environment).
#
# defect: sp-1j0r (replaces sp-syub)
# covers: systemd/install.sh spira/skew.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_REPO="$(cd "$HERE/.." && pwd -P)"
REAL_COCKPIT="$(cd "$HERE/../cockpit" && pwd -P)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
nonzero(){ [ "$2" != 0 ] && ok "$1" || bad "$1" "wanted non-zero exit, got 0"; }
iszero() { [ "$2" = 0 ] && ok "$1" || bad "$1" "wanted exit 0, got $2"; }

echo "test-install-aeons.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture: minimal harness tree mirroring what test-install-halt.sh builds.
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

# The watchers file has one daemon row so the prune loop knows "testview" is legitimate.
cat > "$FIXTURE/spira/watchers" <<'WATCHERS'
testview|daemon|/bin/true
WATCHERS

printf '# empty\n' > "$FIXTURE/spira/repo-map.example"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/spira/install-session-hook.sh"
chmod +x "$FIXTURE/spira/install-session-hook.sh"

DEST="$TMP/home/.config/systemd/user"
SPIRA_RUN_DIR="$TMP/run"
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$DEST" "$SPIRA_RUN_DIR" "$MOCK_BIN"
MOCK_LOG="$TMP/systemctl.log"
# DRAIN_STATE is read by the oneshot-drain mock to simulate a transitioning service.
DRAIN_STATE="$TMP/drain_state"

# ---------------------------------------------------------------------------
# Mock systemctl records every call and returns scenario-controlled output.
#
#   MOCK_IS_ACTIVE     what is-active returns for every unit; defaults to "active"
#   MOCK_ONESHOT_SVC   service name that is-active should report as a transitioning
#                      oneshot (active on first query, inactive thereafter)
#   DRAIN_STATE        file holding current state for MOCK_ONESHOT_SVC queries
#
# The mock always reports spira-watch@testview.service as present so the prune
# loop has a real instance to decide about.
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "$*" in
    *list-unit-files*spira-watch*)
        printf 'spira-watch@testview.service enabled\n'
        ;;
    *list-units*spira-watch*)
        printf 'spira-watch@testview.service loaded active running Test watcher\n'
        ;;
    *show*Type*)
        # Return "oneshot" only for the designated drain target.
        if [[ "$*" == *"${MOCK_ONESHOT_SVC:-__none__}"* ]]; then
            printf 'oneshot\n'
        else
            printf 'simple\n'
        fi
        ;;
    *is-active*"${MOCK_ONESHOT_SVC:-__none__}"*)
        # Transition: "active" on first query, then "inactive".
        state="$(cat "${DRAIN_STATE}" 2>/dev/null || printf 'inactive')"
        printf '%s\n' "$state"
        printf 'inactive\n' > "${DRAIN_STATE}"
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
# Reads MOCK_IS_ACTIVE, MOCK_ONESHOT_SVC from caller's scope.
# SPIRA_DRAIN_INTERVAL=0 makes the drain loop poll without sleeping.
# ---------------------------------------------------------------------------
inst() {
    > "$MOCK_LOG"
    env -i \
        "PATH=$PATH" \
        "HOME=$TMP/home" \
        SPIRA_CONF=/nonexistent \
        "SPIRA_PATH=$MOCK_BIN" \
        "SPIRA_WATCHERS=$FIXTURE/spira/watchers" \
        SPIRA_DOLT_DATA= \
        SPIRA_TESTDB_DATA= \
        "SPIRA_RUN=$SPIRA_RUN_DIR" \
        "SPIRA_HOME=$HERE" \
        "SPIRA_PROD=$HERE" \
        "SPIRA_REPO=$REAL_REPO" \
        "SPIRA_COCKPIT=$REAL_COCKPIT" \
        "MOCK_LOG=$MOCK_LOG" \
        "MOCK_IS_ACTIVE=${MOCK_IS_ACTIVE:-active}" \
        "MOCK_ONESHOT_SVC=${MOCK_ONESHOT_SVC:-__none__}" \
        "DRAIN_STATE=$DRAIN_STATE" \
        SPIRA_DRAIN_INTERVAL=0 \
        bash "$FIXTURE/systemd/install.sh" "$@" 2>&1
}

# Seed DEST with rendered units so every installed unit matches what install.sh
# would render — this is the "nothing changed" baseline.
rendered="$(MOCK_IS_ACTIVE=active MOCK_ONESHOT_SVC=__none__ inst --render)"; render_rc=$?
if [ "$render_rc" != 0 ]; then
    printf 'fixture: install.sh --render failed (rc=%s) — cannot continue\n' "$render_rc"
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
echo "NO-OP INSTALL — nothing changed; all active (including live aeons):"
# ==========================================================================
# Even if aeons are live, a no-op install restarts nothing and exits 0.
# The mock returns "active" for all is-active queries, including any aeon.
noop_out="$(MOCK_IS_ACTIVE=active MOCK_ONESHOT_SVC=__none__ inst)"
noop_rc=$?
noop_log="$(cat "$MOCK_LOG")"

iszero  "no-op: exit 0 when nothing changed"                       "$noop_rc"
want    "no-op: daemon-reload is called"                            "daemon-reload" "$noop_log"
nowant  "no-op: no restart command"                                 "restart" "$noop_log"
nowant  "no-op: no enable --now command"                            "enable --now" "$noop_log"
want    "no-op: unchanged units reported as skipped"                "unchanged" "$noop_out"

# ==========================================================================
echo
echo "SELECTIVE RESTART — one unit content changed; only that unit restarted:"
# ==========================================================================
# Write a different sentinel timer to DEST so it appears changed to install.sh.
timer_file="$DEST/spira-sentinel.timer"
printf '# deliberately altered to trigger restart\n' >> "$timer_file"

selective_out="$(MOCK_IS_ACTIVE=active MOCK_ONESHOT_SVC=__none__ inst)"
selective_rc=$?
selective_log="$(cat "$MOCK_LOG")"

iszero  "selective: exit 0 after selective restart"                 "$selective_rc"
want    "selective: sentinel timer is restarted"                    "spira-sentinel.timer" "$selective_log"
nowant  "selective: other timers not restarted"                     "restart spira-ops" "$selective_log"
nowant  "selective: other timers not enable --now"                  "enable --now spira-ops" "$selective_log"

# Restore the timer to baseline so subsequent tests see no changes.
rendered_timer="$(printf '%s\n' "$rendered" | awk '/^===== spira-sentinel.timer =====$/{found=1;next} /^===== /{found=0} found')"
printf '%s\n' "$rendered_timer" > "$timer_file"

# ==========================================================================
echo
echo "AEON SAFETY — no systemctl call ever names a spira-aeon-* unit:"
# ==========================================================================
aeon_out="$(MOCK_IS_ACTIVE=active MOCK_ONESHOT_SVC=__none__ inst)"
aeon_rc=$?
aeon_log="$(cat "$MOCK_LOG")"

iszero  "aeon safety: install exits 0 even with no aeon guard"      "$aeon_rc"
nowant  "aeon safety: no spira-aeon-* in any systemctl call"        "spira-aeon-" "$aeon_log"

# ==========================================================================
echo
echo "WATCH PRESERVATION — manifest instance is not disabled:"
# ==========================================================================
watch_out="$(MOCK_IS_ACTIVE=active MOCK_ONESHOT_SVC=__none__ inst)"
watch_log="$(cat "$MOCK_LOG")"

nowant  "watch: testview instance not disabled"   "disable --now spira-watch@testview" "$watch_log"

# ==========================================================================
echo
echo "ONESHOT DRAIN — changed timer; backing service is a running oneshot:"
# ==========================================================================
# Alter the sentinel timer content so it appears changed.
printf '# altered for drain test\n' >> "$DEST/spira-sentinel.timer"
# Tell the mock that spira-sentinel.service is a running oneshot that transitions
# to inactive after the first is-active probe.
printf 'active\n' > "$DRAIN_STATE"

drain_out="$(MOCK_IS_ACTIVE=active MOCK_ONESHOT_SVC=spira-sentinel.service inst)"
drain_rc=$?
drain_log="$(cat "$MOCK_LOG")"

iszero  "drain: exit 0 after draining the oneshot"                  "$drain_rc"
want    "drain: is-active was queried on the backing service"        "is-active spira-sentinel.service" "$drain_log"
want    "drain: drain message emitted"                              "mid-pass" "$drain_out"
want    "drain: timer was applied after drain"                      "spira-sentinel.timer" "$drain_log"

# Restore timer.
printf '%s\n' "$rendered_timer" > "$DEST/spira-sentinel.timer"

# ==========================================================================
echo
echo "END-STATE CHECK — install exits non-zero when a unit is not active:"
# ==========================================================================
badstate_out="$(MOCK_IS_ACTIVE=failed MOCK_ONESHOT_SVC=__none__ inst)"
badstate_rc=$?

nonzero "end-state: exit non-zero when units are not active"       "$badstate_rc"
want    "end-state: output names the failure"                      "not active" "$badstate_out"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
