#!/usr/bin/env bash
#
# test-install-aeons.sh — install.sh refuses when aeons are live; reports end-state.
#
#   ./test-install-aeons.sh
#
# THE PROPERTIES UNDER TEST
# -------------------------
# 1. AEON GUARD: install.sh refuses to run (exit non-zero) when live aeon units are
#    reported by systemctl, naming them in the error. SPIRA_INSTALL_FORCE=1 bypasses it.
# 2. END-STATE: after a successful install on a healthy world, install.sh verifies that
#    every enabled unit is active and exits non-zero if any is not.
# 3. WATCH PRESERVATION: a spira-watch@ instance whose name IS in the manifest is not
#    disabled by the manifest-prune step, even after daemon-reload.
#
# THE FIXTURE USES A MOCK systemctl THAT RECORDS CALLS AND RETURNS CONTROLLED OUTPUT.
# MOCK_AEONS and MOCK_IS_ACTIVE in the environment drive the mock's responses.
# Pin a non-default SPIRA_RUN so nothing touches the operator's live directory
# (law-gates-run-in-a-clean-environment).
#
# defect: sp-syub
# covers: systemd/install.sh spira/skew.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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

# ---------------------------------------------------------------------------
# Mock systemctl records every call and returns scenario-controlled output.
#
#   MOCK_AEONS      space-separated aeon unit names to report as active; empty = none
#   MOCK_IS_ACTIVE  what is-active returns for every unit; defaults to "active"
#
# The mock always reports spira-watch@testview.service as present in list-unit-files
# and list-units so the prune loop has a real instance to decide about.
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "$*" in
    *list-units*active*spira-aeon*)
        for a in ${MOCK_AEONS:-}; do printf '%s\n' "$a"; done
        ;;
    *list-unit-files*spira-watch*)
        printf 'spira-watch@testview.service enabled\n'
        ;;
    *list-units*spira-watch*)
        printf 'spira-watch@testview.service loaded active running Test watcher\n'
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
# Reads MOCK_AEONS, MOCK_IS_ACTIVE, MOCK_FORCE from the caller's scope.
# MOCK_FORCE is passed as SPIRA_INSTALL_FORCE; empty means the guard is active.
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
        "MOCK_LOG=$MOCK_LOG" \
        "MOCK_AEONS=${MOCK_AEONS:-}" \
        "MOCK_IS_ACTIVE=${MOCK_IS_ACTIVE:-active}" \
        "SPIRA_INSTALL_FORCE=${MOCK_FORCE:-}" \
        bash "$FIXTURE/systemd/install.sh" "$@" 2>&1
}

# Seed DEST with rendered units so the installer does not fail on missing files.
rendered="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE= inst --render)"; render_rc=$?
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
echo "AEON GUARD — install.sh refuses while aeons are live:"
# ==========================================================================

MOCK_AEONS="spira-aeon-builder-9999.service" MOCK_IS_ACTIVE=active MOCK_FORCE= \
    aeon_out="$(MOCK_AEONS="spira-aeon-builder-9999.service" MOCK_IS_ACTIVE=active MOCK_FORCE= inst)"
aeon_rc=$?
aeon_log="$(cat "$MOCK_LOG")"

nonzero "aeon guard: exit non-zero when aeons are live"            "$aeon_rc"
want    "aeon guard: names the live aeon in error output"          "spira-aeon-builder-9999" "$aeon_out"
want    "aeon guard: mentions SPIRA_INSTALL_FORCE override"        "SPIRA_INSTALL_FORCE" "$aeon_out"
# The guard must fire BEFORE any unit file is written or daemon-reload is called.
nowant  "aeon guard: daemon-reload not called when guard fires"    "daemon-reload" "$aeon_log"

# ==========================================================================
echo
echo "FORCE OVERRIDE — SPIRA_INSTALL_FORCE=1 bypasses the aeon guard:"
# ==========================================================================

force_out="$(MOCK_AEONS="spira-aeon-builder-9999.service" MOCK_IS_ACTIVE=active MOCK_FORCE=1 inst)"
force_rc=$?
force_log="$(cat "$MOCK_LOG")"

iszero  "force override: exit 0 with SPIRA_INSTALL_FORCE=1"        "$force_rc"
want    "force override: daemon-reload IS called"                   "daemon-reload" "$force_log"

# ==========================================================================
echo
echo "CLEAN INSTALL — no live aeons; all units become active; watch instance preserved:"
# ==========================================================================

clean_out="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE= inst)"
clean_rc=$?
clean_log="$(cat "$MOCK_LOG")"

iszero  "clean install: exit 0 when all units are active"           "$clean_rc"
nowant  "clean install: watch instance not disabled"   "disable --now spira-watch@testview" "$clean_log"
want    "clean install: daemon-reload is called"                    "daemon-reload" "$clean_log"
want    "clean install: units are enabled with --now"               "--now" "$clean_log"

# ==========================================================================
echo
echo "END-STATE CHECK — install exits non-zero when a unit is not active:"
# ==========================================================================

badstate_out="$(MOCK_AEONS= MOCK_IS_ACTIVE=failed MOCK_FORCE= inst)"
badstate_rc=$?

nonzero "end-state: exit non-zero when units are not active"       "$badstate_rc"
want    "end-state: output names the failure"                      "not active" "$badstate_out"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
