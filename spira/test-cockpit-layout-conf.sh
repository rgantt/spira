#!/usr/bin/env bash
#
# test-cockpit-layout-conf.sh — SPIRA_CONF propagates to pane commands in layout.sh up.
#
# THE FAILURE THIS SUITE EXISTS FOR. layout.sh spawns health.sh and panel-run.sh in tmux
# panes. tmux gives each new pane the server's environment, which is set once at server
# start and does not carry per-invocation env vars. An operator running
# `SPIRA_CONF=/test.conf layout.sh up` expects test panes; without this fix the panes
# respawn with no SPIRA_CONF and read the prod config instead — the wrong runtime tree,
# silently, with no visible error.
#
# covers: cockpit/layout.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT_DIR="$(dirname "$HERE")/cockpit"
LAYOUT="$COCKPIT_DIR/layout.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
skip() { printf '  skip  %s\n' "$1"; }

if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not available" >&2
    exit 0
fi
if ! command -v script >/dev/null 2>&1; then
    echo "SKIP: 'script' not available" >&2
    exit 0
fi

TMP="$(mktemp -d)"
TMUXDIR="$TMP/tmux-fixture"
mkdir -p "$TMUXDIR"
FIXTURE_UP=0

cleanup() {
    [ "$FIXTURE_UP" -eq 1 ] && TMUX_TMPDIR="$TMUXDIR" tmux kill-server 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# ── Fake cockpit scripts ────────────────────────────────────────────────────
# health.sh and panel-run.sh just sleep so the pane stays alive for inspection.
# The test only needs to read pane_start_command; the scripts need not do anything.
FAKE_COCK="$TMP/cockpit"
mkdir -p "$FAKE_COCK"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$FAKE_COCK/health.sh"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$FAKE_COCK/panel-run.sh"
chmod +x "$FAKE_COCK/health.sh" "$FAKE_COCK/panel-run.sh"

# A fake SPIRA_PANEL binary (panel-run.sh exec's it; it must exist to avoid an error, but
# here panel-run.sh is replaced entirely so it need not do anything real).
mkdir -p "$FAKE_COCK/panel/target/release"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$FAKE_COCK/panel/target/release/panel"
chmod +x "$FAKE_COCK/panel/target/release/panel"

# ── Fixture tmux server ─────────────────────────────────────────────────────
export TMUX_TMPDIR="$TMUXDIR"
unset TMUX

TMUX_TMPDIR="$TMUXDIR" tmux start-server
FIXTURE_UP=1

# Create the session layout.sh will operate on. A 214×53 window matches the layout comment.
TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s cockpit -x 214 -y 53

# ── Run layout.sh up with SPIRA_CONF set ────────────────────────────────────
CONF_PATH="$TMP/myinstance.conf"

SPIRA_COCKPIT="$FAKE_COCK" \
SPIRA_REPO="$TMP" \
SPIRA_HOME="$HERE" \
SPIRA_CONF="$CONF_PATH" \
COCKPIT_CWD="$TMP" \
    bash "$LAYOUT" up --window cockpit:0 2>/dev/null || true

# Allow panes a moment to start.
sleep 0.3

# ── Read what commands the panes were given ──────────────────────────────────
# #{pane_start_command} is the full command string passed to split-window; it survives
# respawn as the command tmux would reuse, so it is the canonical record of what
# SPIRA_CONF will be set to on every restart.
health_cmd=$(TMUX_TMPDIR="$TMUXDIR" \
    tmux list-panes -t cockpit:0 \
    -F '#{@cockpit}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '$1=="health"{print $2; exit}')
panel_cmd=$(TMUX_TMPDIR="$TMUXDIR" \
    tmux list-panes -t cockpit:0 \
    -F '#{@cockpit}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '$1=="panel"{print $2; exit}')

want "health pane command carries SPIRA_CONF" "SPIRA_CONF=" "$health_cmd"
want "health pane command carries the conf path" "$CONF_PATH" "$health_cmd"
want "panel pane command carries SPIRA_CONF" "SPIRA_CONF=" "$panel_cmd"
want "panel pane command carries the conf path" "$CONF_PATH" "$panel_cmd"

# ── Verify the absence case: no SPIRA_CONF → no prefix in the command ───────
TMUX_TMPDIR="$TMUXDIR" tmux kill-server 2>/dev/null || true
FIXTURE_UP=0

TMUX_TMPDIR="$TMUXDIR" tmux start-server
FIXTURE_UP=1
TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s cockpit2 -x 214 -y 53

SPIRA_COCKPIT="$FAKE_COCK" \
SPIRA_REPO="$TMP" \
SPIRA_HOME="$HERE" \
COCKPIT_CWD="$TMP" \
    bash "$LAYOUT" up --window cockpit2:0 2>/dev/null || true

sleep 0.3

health_cmd2=$(TMUX_TMPDIR="$TMUXDIR" \
    tmux list-panes -t cockpit2:0 \
    -F '#{@cockpit}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '$1=="health"{print $2; exit}')
panel_cmd2=$(TMUX_TMPDIR="$TMUXDIR" \
    tmux list-panes -t cockpit2:0 \
    -F '#{@cockpit}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '$1=="panel"{print $2; exit}')

# WITHOUT SPIRA_CONF: commands must not contain a SPIRA_CONF= prefix.
[[ "${health_cmd2:-}" != *"SPIRA_CONF="* ]] \
    && ok "health pane command has no SPIRA_CONF when var is unset" \
    || bad "health pane command has no SPIRA_CONF when var is unset" \
           "got [$health_cmd2]"
[[ "${panel_cmd2:-}" != *"SPIRA_CONF="* ]] \
    && ok "panel pane command has no SPIRA_CONF when var is unset" \
    || bad "panel pane command has no SPIRA_CONF when var is unset" \
           "got [$panel_cmd2]"

printf '\ntest-cockpit-layout-conf: %d ok, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
