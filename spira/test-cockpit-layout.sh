#!/usr/bin/env bash
#
# test-cockpit-layout.sh — the cockpit's shape, asserted against a real tmux server.
#
#   ./test-cockpit-layout.sh
#
# WHY THIS EXISTS. The ops dashboard is a FULL-HEIGHT RIGHT COLUMN, and the failure it
# regressed into for months looks almost right: a pane on the correct side, the correct
# width, running the correct program, and only half the height. Nobody files that. It is
# caught by comparing the pane to the window, which is a thing a program does and an eye
# does not, so it is a test rather than a convention.
#
# ORDER IS THE GEOMETRY. Splitting the bottom band first and halving it can only ever
# produce a quadrant, because by the time the right pane exists its height is already the
# band's. Every case below is really asking the same question of a different code path —
# `up`, and each of the three repair branches — because each one builds the shape itself.
#
# AGAINST A REAL TMUX, on a private server. A model of tmux would reproduce the surface
# whoever wrote it remembered, and the whole subject here is a behaviour of the real thing:
# that a split takes its TARGET pane's height unless `-f` is given (law-prefer-the-real-
# dependency). TMUX_TMPDIR gives the suite a server of its own, so it can neither see nor
# disturb the operator's cockpit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAYOUT="$HERE/../cockpit/layout.sh"

command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 77; }
[ -f "$LAYOUT" ] || { echo "  FAIL  cannot find layout.sh at $LAYOUT"; exit 1; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }

TMP="$(mktemp -d)"

# A COCKPIT MADE OF STUBS. SPIRA_COCKPIT decides what the panes RUN; layout.sh itself is
# invoked by its real path, so the code under test is the branch's.
COCK="$TMP/cockpit"
mkdir -p "$COCK/panel/target/release"
printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$COCK/health.sh"
chmod +x "$COCK/health.sh"
# The panel is addressed through its binary in one place and its launcher in another, and
# `retag_dashboards` derives a pane's identity from the process actually running in it —
# so the stub has to have the same argv shape, not merely the same behaviour.
printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$COCK/panel/target/release/panel"
chmod +x "$COCK/panel/target/release/panel"
printf '#!/usr/bin/env bash\nexec "%s"\n' "$COCK/panel/target/release/panel" > "$COCK/panel-run.sh"
chmod +x "$COCK/panel-run.sh"
# Backdated so `restart_if_stale` does not read a stub written one second ago as code newer
# than the pane running it, and respawn every pane mid-assertion.
touch -d '1 hour ago' "$COCK"/*.sh "$COCK/panel/target/release/panel" 2>/dev/null

export TMUX_TMPDIR="$TMP/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
WIN=""
WINDN=0

# A PANE PROCESS IS NOT REAPED WITH ITS PANE. tmux hangs up the pty, and a stub that is not
# reading it never notices — thirteen `sleep`s per run outlived the server, each for its full
# ten minutes. So pane processes are killed explicitly, here and on every window swap.
reap_panes() {           # reap_panes -a | -t <target>
    local p
    for p in $(tmux list-panes "$@" -F '#{pane_pid}' 2>/dev/null); do
        pkill -P "$p" 2>/dev/null
        kill "$p" 2>/dev/null
    done
}

# `down` runs before the server goes, so the layout is torn down through the code under test
# rather than only by killing the server out from under it.
cleanup() {
    reap_panes -a
    [ -n "$WIN" ] && lay 33 down >/dev/null 2>&1
    tmux kill-server >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT

# Run layout.sh in the explicit minimal environment a gate would give it, plus the fixture.
# Nothing here may read the operator's spira.conf: SPIRA_CONF names a file that does not exist,
# which conf.sh treats as "read no file at all" (law-gates-run-in-a-clean-environment).
lay() {                  # lay <right-pct> <action> [args...]
    local pct="$1"; shift
    env -i PATH="$PATH" HOME="$TMP/home" TERM=dumb TMUX_TMPDIR="$TMUX_TMPDIR" \
        SPIRA_CONF="$TMP/no.conf" SPIRA_REPO="$TMP/repo" SPIRA_RUN="$TMP/repo/.runtime/spira" \
        SPIRA_COCKPIT="$COCK" SPIRA_PANEL="$COCK/panel/target/release/panel" \
        COCKPIT_CWD="$TMP" COCKPIT_RIGHT_PCT="$pct" COCKPIT_BOTTOM_PCT=28 \
        bash "$LAYOUT" "$@" --window "$WIN" 2>&1
}
mkdir -p "$TMP/home" "$TMP/repo"

# Pane geometry, by tag. Empty when the pane is absent, which every caller distinguishes
# from a number — an assertion that reads a missing pane as 0 passes for the wrong reason.
gfield() {               # gfield <tag> <format>
    local id
    id="$(tmux list-panes -t "$WIN" -F '#{@cockpit} #{pane_id}' 2>/dev/null \
          | awk -v t="$1" '$1==t {print $2; exit}')"
    [ -n "$id" ] || return 1
    tmux display-message -p -t "$id" "$2" 2>/dev/null
}
sess_pane() {            # the one untagged pane
    tmux list-panes -t "$WIN" -F '#{@cockpit} #{pane_id}' 2>/dev/null \
        | awk '{ if (NF==1) print $1; else if ($1!="panel" && $1!="health") print $2 }' | head -1
}
sfield() { tmux display-message -p -t "$(sess_pane)" "$1" 2>/dev/null; }

# THE SHAPE, AS ONE VERDICT. Returns a word per broken invariant so a failure names which
# one broke rather than only that something did.
shape() {
    local hh wh hl dl dt st sl out=""
    hh="$(gfield health '#{pane_height}')" || { echo "no-health"; return; }
    wh="$(gfield health '#{window_height}')"
    hl="$(gfield health '#{pane_left}')"
    dl="$(gfield panel  '#{pane_left}')"  || { echo "no-panel"; return; }
    dt="$(gfield panel  '#{pane_top}')"
    st="$(sfield '#{pane_top}')"; sl="$(sfield '#{pane_left}')"
    [ -n "$st" ] || { echo "no-session"; return; }
    [ "$hh" = "$wh" ]        || out="$out health-not-full-height"
    [ "$hl" -gt "$dl" ]      || out="$out health-not-rightmost"
    [ "$dt" -gt "$st" ]      || out="$out panel-not-below-session"
    [ "$dl" = "$sl" ]        || out="$out panel-not-in-left-column"
    printf '%s' "${out# }"
}

# A FRESH WINDOW PER CASE, NOT A FRESH SERVER. `kill-server` immediately followed by
# `new-session` races the server's own teardown: the new session lands on a socket that is
# being removed, and every later case then reports "no server running" — which reads as a
# broken layout rather than a broken fixture. One long-lived session keeps the server up and
# each case gets a session of its own.
fresh() {                # a window with one shell in it, sized as given
    if [ -n "$WIN" ]; then
        reap_panes -t "${WIN%%:*}"
        tmux kill-session -t "${WIN%%:*}" >/dev/null 2>&1
    fi
    WINDN=$((WINDN+1))
    WIN="ck$WINDN:0"
    tmux new-session -d -s "ck$WINDN" -x "${1:-200}" -y "${2:-50}" 2>/dev/null
    sleep 0.3
}

# Holds the server open across every kill-session above.
tmux new-session -d -s keep -x 80 -y 24 2>/dev/null
sleep 0.2

echo "up — the column first, then the row"
fresh 200 50
lay 33 up >/dev/null; sleep 0.5
is "up builds the promised shape" "" "$(shape)"
is "health spans the full window height" "$(gfield health '#{window_height}')" "$(gfield health '#{pane_height}')"
# 33% of 200 columns, less the one-column divider tmux takes.
w="$(gfield health '#{pane_width}')"
if [ -n "$w" ] && [ "$w" -ge 63 ] && [ "$w" -le 67 ]; then
    ok "health is COCKPIT_RIGHT_PCT of the window wide ($w of 200)"
else bad "health width" "want ~66 of 200, got [$w]"; fi
# THE PANEL IS A FRACTION OF THE WINDOW, NOT OF THE LEFT COLUMN'S LEFTOVERS. The session
# pane owns the whole height when the panel is split off it, so 28% means 28% of 50 rows.
h="$(gfield panel '#{pane_height}')"
if [ -n "$h" ] && [ "$h" -ge 12 ] && [ "$h" -le 15 ]; then
    ok "panel is COCKPIT_BOTTOM_PCT of the window tall ($h of 50)"
else bad "panel height" "want ~14 of 50, got [$h]"; fi

echo
echo "the width is CONFIGURED, not written into the code"
# Pinned to a NON-DEFAULT deliberately: asserting the shipped 33 would pass just as well if
# the percentage were a literal, which is the thing the key exists to stop.
fresh 200 50
lay 50 up >/dev/null; sleep 0.5
w="$(gfield health '#{pane_width}')"
if [ -n "$w" ] && [ "$w" -ge 98 ] && [ "$w" -le 102 ]; then
    ok "COCKPIT_RIGHT_PCT=50 gives half the window ($w of 200)"
else bad "COCKPIT_RIGHT_PCT is not honoured" "want ~100 of 200, got [$w]"; fi
is "and the shape still holds at 50%" "" "$(shape)"

echo
echo "repair — every path rebuilds the column, never a quadrant"

# THE POSITIVE CONTROL FIRST. Before believing that `shape` is silent because the layout is
# right, it has to be seen saying otherwise — so the OLD geometry is built by hand here, and
# it must be caught. A check that has never refused anything is a hypothesis.
fresh 200 50
s="$(tmux list-panes -t "$WIN" -F '#{pane_id}' | head -1)"
d="$(tmux split-window -P -F '#{pane_id}' -d -v -l 28% -t "$s")"
tmux set-option -p -t "$d" @cockpit panel
hq="$(tmux split-window -P -F '#{pane_id}' -d -h -l 50% -t "$d")"
tmux set-option -p -t "$hq" @cockpit health
case "$(shape)" in
    *health-not-full-height*) ok "the assertion catches the old quadrant" ;;
    *) bad "the assertion does not catch a quadrant" "shape said [$(shape)]" ;;
esac

# ...and `ensure` must repair it into a column rather than leave it looking almost right.
fresh 200 50
lay 33 up >/dev/null; sleep 0.5
h="$(tmux list-panes -t "$WIN" -F '#{@cockpit} #{pane_id}' | awk '$1=="health"{print $2}')"
tmux kill-pane -t "$h"
tmux split-window -d -h -l 50% -t "$(tmux list-panes -t "$WIN" -F '#{@cockpit} #{pane_id}' | awk '$1=="panel"{print $2}')" "$COCK/health.sh"
sleep 0.5
lay 33 ensure >/dev/null; sleep 0.5
is "a quadrant health pane is rebuilt as a column" "" "$(shape)"

fresh 200 50
lay 33 up >/dev/null; sleep 0.5
tmux kill-pane -t "$(tmux list-panes -t "$WIN" -F '#{@cockpit} #{pane_id}' | awk '$1=="health"{print $2}')"
sleep 0.3
lay 33 ensure >/dev/null; sleep 0.5
is "a dead health pane comes back full height" "" "$(shape)"

fresh 200 50
lay 33 up >/dev/null; sleep 0.5
tmux kill-pane -t "$(tmux list-panes -t "$WIN" -F '#{@cockpit} #{pane_id}' | awk '$1=="panel"{print $2}')"
sleep 0.3
lay 33 ensure >/dev/null; sleep 0.5
is "a dead panel comes back below the session" "" "$(shape)"

# BOTH GONE IS ITS OWN PATH, and the one that has to reproduce column-then-row from scratch.
fresh 200 50
lay 33 up >/dev/null; sleep 0.5
for p in $(tmux list-panes -t "$WIN" -F '#{@cockpit} #{pane_id}' | awk '$1=="panel"||$1=="health"{print $2}'); do
    tmux kill-pane -t "$p"
done
sleep 0.3
# With no tagged pane left `ensure` is silent by design — an absent cockpit means `down` was
# run, and rebuilding what the operator dismissed is a fight, not a repair. `up` is the command.
lay 33 up >/dev/null; sleep 0.5
is "up after both were killed rebuilds the shape" "" "$(shape)"

echo
echo "up is idempotent — running it twice does not nest or mirror"
fresh 200 50
lay 33 up >/dev/null; sleep 0.5
lay 33 up >/dev/null; sleep 0.5
is "a second up leaves the same shape" "" "$(shape)"
is "and still exactly three panes" "3" "$(tmux list-panes -t "$WIN" | wc -l)"

echo
echo "down leaves one full-window session pane"
lay 33 down >/dev/null; sleep 0.3
is "one pane remains" "1" "$(tmux list-panes -t "$WIN" | wc -l)"
is "and it owns the whole height" "$(sfield '#{window_height}')" "$(sfield '#{pane_height}')"

echo
echo "a short, narrow terminal still gets the shape rather than an error"
fresh 80 24
lay 33 up >/dev/null; sleep 0.5
is "80x24 still builds the column" "" "$(shape)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
