#!/usr/bin/env bash
#
# test-layout-guard.sh — a copy of layout.sh must refuse `ensure`.
#
#   ./test-layout-guard.sh
#
# THE FAILURE THIS SUITE EXISTS FOR. `ensure` iterates over every cockpit window on the
# tmux server and overwrites WINDOW on each pass. A copy running from a worktree therefore
# adopts every live pane and respawns them with the worktree's own $COCK — hijacking the
# installed dashboards. The guard compares the script's own realpath against
# $SPIRA_COCKPIT/layout.sh and exits 0 with a message when they differ.
#
# EVERY CASE CARRIES ITS POSITIVE CONTROL. The guard must fire when a copy is run, and must
# NOT fire when the installed copy is run. Both must be observed, not just one.
#
# defect: sp-zp8
# covers: cockpit/layout.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LAYOUT="$HERE/../cockpit/layout.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# Minimal conf.sh stub — pin every key to a non-default so an ambient spira.conf cannot
# silently decide the verdict (law-gates-run-in-a-clean-environment).
make_tree() {
    local root="$1"
    # layout.sh lives at cockpit/layout.sh and sources ../spira/conf.sh.
    mkdir -p "$root/cockpit" "$root/spira"
    cp "$LAYOUT" "$root/cockpit/layout.sh"
    chmod +x "$root/cockpit/layout.sh"
    # SPIRA_HOME is derived by the real conf.sh from where conf.sh sits, but our stub
    # must set it explicitly; otherwise restart_spira_collector_if_stale fails with
    # "unbound variable" when cockpit_windows finds live panes on the box's tmux server.
    # Point it at a directory without cockpit.sh so the function returns early.
    cat > "$root/spira/conf.sh" <<CONF
SPIRA_HOME="${root}/spira"
SPIRA_COCKPIT="\${SPIRA_COCKPIT:-}"
SPIRA_PANEL="\${SPIRA_PANEL:-/dev/null}"
SPIRA_REPO="\${SPIRA_REPO:-/tmp}"
SPIRA_RUN="\${SPIRA_RUN:-/tmp}"
COCKPIT_CWD="\${COCKPIT_CWD:-/tmp}"
COCKPIT_BOTTOM_PCT="\${COCKPIT_BOTTOM_PCT:-30}"
COCKPIT_RIGHT_PCT="\${COCKPIT_RIGHT_PCT:-33}"
COCKPIT_HEAL_COOLDOWN="\${COCKPIT_HEAL_COOLDOWN:-60}"
SPIRA_TZ="\${SPIRA_TZ:-UTC}"
CONF
}

INST="$(mktemp -d)"
COPY="$(mktemp -d)"
trap 'rm -rf "$INST" "$COPY"' EXIT

make_tree "$INST"
make_tree "$COPY"

echo "positive control: a copy refuses ensure"

# Run ensure from the copy, with SPIRA_COCKPIT pointing at the installed cockpit dir.
# The guard must fire, exit 0, and write the refusal to stderr.
err="$(SPIRA_COCKPIT="$INST/cockpit" bash "$COPY/cockpit/layout.sh" ensure 2>&1 1>/dev/null)"
rc=$?

[ "$rc" -eq 0 ] && ok "copy: ensure exits 0" || bad "copy: ensure exited $rc, expected 0"
case "$err" in
    *"ensure refused"*) ok "copy: refusal message printed to stderr" ;;
    *) bad "copy: expected 'ensure refused' in stderr, got: [$err]" ;;
esac
case "$err" in
    *"$INST/cockpit"*) ok "copy: stderr names the installed path" ;;
    *) bad "copy: stderr does not name the installed path [$INST/cockpit]: [$err]" ;;
esac

echo
echo "installed copy: ensure does not refuse"

# Run ensure from the installed cockpit itself. The guard must NOT fire.
# cockpit_windows returns nothing (no tmux server here), so ensure exits 0 silently.
err_installed="$(SPIRA_COCKPIT="$INST/cockpit" bash "$INST/cockpit/layout.sh" ensure 2>&1 1>/dev/null)"
rc_installed=$?

[ "$rc_installed" -eq 0 ] && ok "installed: ensure exits 0" \
                           || bad "installed: ensure exited $rc_installed, expected 0"
case "$err_installed" in
    *"ensure refused"*) bad "installed: guard fired on the real installed copy" ;;
    *) ok "installed: no refusal message" ;;
esac

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
