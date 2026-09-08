#!/usr/bin/env bash
#
# test-install-unit-directive.sh — rendered spira-*.timer files carry the
# correct per-instance Unit= directive; _migrate_legacy disables the old
# spira-watch@ template-instantiation form.
#
#   ./test-install-unit-directive.sh
#
# PROPERTIES UNDER TEST
# ---------------------
# 1. TIMER UNIT DIRECTIVE: every rendered spira-*-<instance>.timer carries
#    Unit=spira-*-<instance>.service, not the plain-named (un-suffixed) service.
#    Without this fix, a timer installed as spira-sentinel-prod.timer still
#    carries Unit=spira-sentinel.service in its body, so it fires the legacy
#    service rather than the per-instance one — and on the next install the
#    test timer fires the prod service.
# 2. MIGRATE TEMPLATE INSTANCES: _migrate_legacy disables
#    spira-watch@<name>.service (the systemd template-instantiation form) in
#    addition to the plain-hyphen form. Before per-instance naming, watchers
#    were started via the spira-watch@.service template; the running units were
#    spira-watch@answers.service (@ not hyphen), so a migration that only
#    retires the hyphen form leaves the old instance holding the work, causing
#    the new per-instance unit to crash-loop against it.
#
# ASSERTIONS ARE FROM RENDERED FILES, NOT TEMPLATES. The templates are the
# source; the defect is in the rendered output. Asserting against the template
# source catches nothing: the template was always correct — it just wasn't
# being post-processed.
#
# covers: systemd/install.sh
# covers: systemd/spira-*.timer
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

echo "test-install-unit-directive.sh"

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
printf '# empty\n' > "$FIXTURE/spira/watchers"

DEST="$TMP/home/.config/systemd/user"
SPIRA_RUN_DIR="$TMP/run"
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$DEST" "$SPIRA_RUN_DIR" "$MOCK_BIN"
MOCK_LOG="$TMP/systemctl.log"

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
        unit="${@: -1}"
        for lu in ${MOCK_LEGACY_UNITS:-}; do
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

# Run install.sh in a controlled, non-default instance ('test') so assertions
# cannot silently match whatever the operator has installed.
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
        "MOCK_LEGACY_UNITS=${MOCK_LEGACY_UNITS:-}" \
        "SPIRA_INSTALL_FORCE=${MOCK_FORCE:-1}" \
        bash "$FIXTURE/systemd/install.sh" test "$@" 2>&1
}

# ==========================================================================
echo
echo "TIMER UNIT DIRECTIVE — rendered spira-*-test.timer carries Unit=...-test.service:"
# ==========================================================================

rendered="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE=1 MOCK_WATCH_LIST= \
             MOCK_WATCHERS="$FIXTURE/spira/watchers" inst --render)"
render_rc=$?
iszero "render: --render exits 0" "$render_rc"

# Parse the --render output into per-unit blocks and check each timer file.
timer_count=0
timer_bad=0
current_unit=""
current_body=""
check_unit() {
    local uname="$1" body="$2"
    case "$uname" in
        spira-*-test.timer)
            timer_count=$((timer_count+1))
            # Every Unit= line in this timer must point at a -test.service.
            while IFS= read -r ln; do
                case "$ln" in
                    Unit=spira-*-test.service) : ;;  # correct
                    Unit=*)
                        bad "unit directive: $uname carries wrong Unit= line: $ln" ""
                        timer_bad=$((timer_bad+1))
                        ;;
                esac
            done <<< "$body"
            ;;
    esac
}

while IFS= read -r line; do
    if [[ "$line" =~ ^=====\ (.+)\ =====$ ]]; then
        if [ -n "$current_unit" ]; then
            check_unit "$current_unit" "$current_body"
        fi
        current_unit="${BASH_REMATCH[1]}"
        current_body=""
    elif [ -n "$current_unit" ]; then
        current_body="${current_body}${line}"$'\n'
    fi
done <<< "$rendered"
# Check the last unit.
[ -n "$current_unit" ] && check_unit "$current_unit" "$current_body"

# The render must have found at least the core spira-*.timer set.
if [ "$timer_count" -ge 10 ]; then
    ok "unit directive: at least 10 spira-*-test.timer files checked"
else
    bad "unit directive: expected >= 10 timers, got $timer_count" ""
fi
[ "$timer_bad" -eq 0 ] \
    && ok "unit directive: all checked timers carry the correct -test.service target" \
    || bad "unit directive: $timer_bad timer(s) point at a wrong service name" ""

# Spot-check: sentinel timer must carry Unit=spira-sentinel-test.service.
want "unit directive: spira-sentinel-test.timer has Unit=spira-sentinel-test.service" \
     "Unit=spira-sentinel-test.service" "$rendered"

# Sanity: the plain un-suffixed name must not appear as a Unit= target for any
# spira-*-test.timer (the exact defect this fix closes).
# Scan rendered lines under spira-*-test.timer headers.
in_spira_test_timer=""
while IFS= read -r line; do
    if [[ "$line" =~ ^=====\ (spira-.*-test\.timer)\ =====$ ]]; then
        in_spira_test_timer=1
    elif [[ "$line" =~ ^=====\ .*\ =====$ ]]; then
        in_spira_test_timer=""
    elif [ -n "$in_spira_test_timer" ]; then
        case "$line" in
            Unit=spira-*.service)
                # Must end in -test.service, not plain .service.
                case "$line" in
                    *-test.service) : ;;
                    *) bad "unit directive: plain Unit= target found in a -test.timer: $line" "" ;;
                esac
                ;;
        esac
    fi
done <<< "$rendered"
ok "unit directive: no spira-*-test.timer carries a plain (un-suffixed) Unit= target"

# Non-spira timers (beads-push, cockpit-ensure, concierge) must NOT have a
# suffix added to their Unit= lines — they are shared units.
case "$rendered" in
    *"Unit=beads-push-test.service"*)
        bad "unit directive: beads-push.timer wrongly got -test suffix on Unit=" "" ;;
    *)
        ok "unit directive: beads-push.timer Unit= unchanged (shared unit)" ;;
esac
case "$rendered" in
    *"Unit=cockpit-ensure-test.service"*)
        bad "unit directive: cockpit-ensure.timer wrongly got -test suffix on Unit=" "" ;;
    *)
        ok "unit directive: cockpit-ensure.timer Unit= unchanged (shared unit)" ;;
esac

# ==========================================================================
echo
echo "MIGRATE TEMPLATE INSTANCES — _migrate_legacy disables spira-watch@<name>.service:"
# ==========================================================================

# Fixture: a watchers file with one row so the migration loop runs.
printf 'answers|daemon|/bin/true\n' > "$FIXTURE/spira/watchers"

# MOCK_LEGACY_UNITS contains BOTH the hyphen and the @ form so the mock's
# disable exits 0 for both, which is what _migrate_legacy uses to decide
# whether to print a "migrated" line.
MOCK_LEGACY_UNITS="spira-watch-answers.service spira-watch@answers.service"

migrate_out="$(MOCK_AEONS= MOCK_IS_ACTIVE=active MOCK_FORCE=1 \
               MOCK_WATCH_LIST= \
               MOCK_LEGACY_UNITS="$MOCK_LEGACY_UNITS" \
               MOCK_WATCHERS="$FIXTURE/spira/watchers" \
               inst)"
migrate_rc=$?
migrate_log="$(cat "$MOCK_LOG")"

iszero "migrate @-form: exit 0" "$migrate_rc"

# _migrate_legacy must have called disable on the @ form.
want "migrate @-form: disable called on spira-watch@answers.service" \
     "spira-watch@answers.service" "$migrate_log"

# The migration output must report both retirements.
want "migrate @-form: migrated line for @-form unit" \
     "spira-watch@answers.service" "$migrate_out"

# The hyphen form must also still be retired (regression guard).
want "migrate @-form: disable still called on hyphen form" \
     "spira-watch-answers.service" "$migrate_log"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
