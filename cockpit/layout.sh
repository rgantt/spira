#!/usr/bin/env bash
#
# layout.sh — build the cockpit: session top-left, panel bottom-left, health down the right.
#
#   layout.sh up       create/repair the dashboard panes (idempotent) and start the collector
#   layout.sh down     remove them, leaving the session pane full-height
#   layout.sh status   what is running
#   layout.sh ensure   heal a cockpit that is already up; SILENT when nothing is wrong
#
#   layout.sh up --window <target>   apply to a different tmux window
#
#                +----------------------------------+---------------+
#                |                                  |               |
#                |   claude session                 |               |
#                |   (flips to hunk for review)     |  ops health   |
#                |                                  |               |
#                +----------------------------------+  full height  |
#                |  WAITING ON YOU                  |               |
#                |  asks + open tasks               |  ~33% wide    |
#                +----------------------------------+---------------+
#                 <---- 100% - COCKPIT_RIGHT_PCT ---> <-- RIGHT_PCT ->
#
# ORDER IS THE GEOMETRY
# ---------------------
# The health pane is split off the WHOLE WINDOW first, which is what gives it the window's
# full height; only then is the remaining left column divided between the session and the
# panel. Split the bottom band first and halve it — as this once did — and the right pane
# can only ever be a quadrant, because by the time it exists its height is already the
# band's. A dashboard with a column's worth of rows is not a cosmetic change: health.sh
# sizes each of its sections to the rows it is given, and in five rows every section is cut
# to one.
#
# PANES ARE ADDRESSED BY TAG, NEVER BY INDEX
# ------------------------------------------
# tmux RENUMBERS pane indices the moment a pane dies, and the session pane is the one most
# likely to die — it holds a shell the operator can exit. When it did, the panel became pane 0 and
# `health` became pane 1, and every index in this script then pointed at the wrong thing:
# `down` killed health and left the panel owning the whole window, and `up` saw two panes,
# decided the cockpit was absent, and SPLIT THE DECISIONS PANE — the top half shrinking and
# the bottom-left growing on each run, which is exactly what the operator reported.
#
# So each dashboard pane carries a pane-scoped option `@cockpit` (panel|health) and is
# resolved by pane id through it. Identity survives renumbering; an index does not.
#
# `up` is a REPAIR, not just a create. It normalises whatever it finds: if the session pane
# is gone it opens a fresh shell at the top before touching anything else (the window must
# never reach zero panes, or it dies and takes the session with it), then rebuilds the dashboards.
#
# WHAT THIS MUST NOT BREAK
# ------------------------
# `cockpit` is built from LINKED WINDOWS: `cockpit:1` and `hunk:0` are the same window
# object, as are `cockpit:2` and `brain:0` — the flip between review and session is tmux
# window navigation over shared panes, not two copies. So a split here is visible from
# both session names, which is what makes the dashboard persist across the flip back.
#
# The session pane is never respawned or killed. `hunk-open.sh` sends keys to the session's
# ACTIVE pane, so this script always restores the session pane as active before exiting.
# Leaving a bottom pane selected would send the next review's launch command into a dashboard.
#
# The panes run renderers that only read `.runtime/cockpit.env`. The collector is the one
# thing that shells out to `gt`, and it runs detached so a slow probe can never stall a
# repaint.
#
# `ensure` — WHAT THE WATCHER CALLS
# ---------------------------------
# `cockpit-remote watch` calls this on its poll loop so the layout self-heals: the session
# pane holds a shell the operator can exit, and nothing else notices when they do. It repairs only
# a cockpit that is ALREADY UP — a window with `@cockpit` panes but no session pane left.
#
# The absence of any `@cockpit` pane means `down` was run, and `ensure` must leave that
# alone. An unattended process that rebuilds the dashboards the operator just dismissed is not a fence,
# it is a fight. Same reason it heals wherever the tagged panes actually are rather than
# at a hardcoded `brain:0`.
#
# It is SILENT on a healthy cockpit — a heartbeat that prints "fine" every 15s buries the
# one line that says it repaired something. Repairs are logged to `.runtime/cockpit-heal.log`,
# because self-healing that leaves no trace is how nobody learns the shell keeps dying.
set -uo pipefail

# Every path comes from the harness's one configuration surface. It is two directories
# away because the cockpit ships beside the harness, not inside it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../spira" && pwd -P)/conf.sh"
COCK="$SPIRA_COCKPIT"
RUN="$SPIRA_REPO/.runtime"
# The panes open where the operator works — COCKPIT_CWD, a spira.conf key.
CWD="$COCKPIT_CWD"
# Pane geometry is the operator's, not the code's: a 13-inch laptop and a 32-inch monitor
# do not want the same proportions. Both are spira.conf keys.
#   COCKPIT_RIGHT_PCT   how wide the full-height ops column is, as a % of the window
#   COCKPIT_BOTTOM_PCT  how tall the attention panel is, as a % of the window, inside the
#                       LEFT column — it no longer has anything to do with the ops pane
BOTTOM_PCT="$COCKPIT_BOTTOM_PCT"
RIGHT_PCT="$COCKPIT_RIGHT_PCT"
mkdir -p "$RUN"

# Default to the window this script was invoked from; fall back to the claude window.
default_window() {
    if [ -n "${TMUX_PANE:-}" ]; then
        tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}' 2>/dev/null && return
    fi
    local w
    w=$(tmux list-panes -a -F '#{session_name}:#{window_index} #{pane_current_command}' 2>/dev/null \
        | awk '$2=="claude"{print $1; exit}')
    [ -n "$w" ] && { echo "$w"; return; }
    echo "cockpit:2"
}

WINDOW=""
ACTION="${1:-status}"; shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --window) WINDOW="${2:?}"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$WINDOW" ] || WINDOW="$(default_window)"

# --- pane identity ------------------------------------------------------------
# Every listing prints pane IDs (%12), which are stable for the pane's whole life. Index
# is used only where tmux itself demands one, and never stored.

tag_pane()   { tmux set-option -p -t "$1" @cockpit "$2" 2>/dev/null; }

# An untagged pane is indistinguishable from the session pane — which is how the first
# repair run picked the ORPHANED decisions pane as the session and split it. So tag it.
#
# Identity comes from what is RUNNING in the pane, not from `pane_start_command`.
# start_command is the command the pane was FIRST created with and it survives
# `respawn-pane`, so after a few swaps the decisions pane still advertised
# "health.sh loop" — both dashboards ended up tagged `health`, `tagged health` resolved
# to the wrong pane, and the real health pane could die unnoticed. Read the pane's
# process and its children instead.
adopt_untagged() {
    tmux list-panes -t "$WINDOW" -F '#{@cockpit}|#{pane_id}|#{pane_pid}' 2>/dev/null \
    | while IFS='|' read -r tag id pid; do
        [ -n "$tag" ] && continue
        local cl=""
        cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        for c in $(pgrep -P "$pid" 2>/dev/null); do
            cl="$cl $(tr '\0' ' ' < "/proc/$c/cmdline" 2>/dev/null)"
        done
        case "$cl" in
            *release/panel*) tag_pane "$id" panel ;;
            *cockpit/health.sh*) tag_pane "$id" health ;;
        esac
      done
}

# Re-derive every dashboard tag from the running process, correcting stale ones.
retag_dashboards() {
    tmux list-panes -t "$WINDOW" -F '#{pane_id}|#{pane_pid}' 2>/dev/null \
    | while IFS='|' read -r id pid; do
        local cl=""
        cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        for c in $(pgrep -P "$pid" 2>/dev/null); do
            cl="$cl $(tr '\0' ' ' < "/proc/$c/cmdline" 2>/dev/null)"
        done
        case "$cl" in
            *release/panel*) tag_pane "$id" panel ;;
            *cockpit/health.sh*) tag_pane "$id" health ;;
        esac
      done
}

# pane id of the dashboard tagged $1, empty if absent.
tagged()     { tmux list-panes -t "$WINDOW" -F '#{@cockpit} #{pane_id}' 2>/dev/null \
                 | awk -v t="$1" '$1==t {print $2; exit}'; }

# every tagged dashboard pane id, one per line (catches duplicates from a bad run).
all_tagged() { tmux list-panes -t "$WINDOW" -F '#{@cockpit} #{pane_id}' 2>/dev/null \
                 | awk 'NF==2 && ($1=="panel" || $1=="health") {print $2}'; }

# untagged panes — the session pane, plus anything the operator split off himself.
untagged()   { tmux list-panes -t "$WINDOW" -F '#{@cockpit} #{pane_id}' 2>/dev/null \
                 | awk '{ if (NF==1) print $1; else if ($1!="panel" && $1!="health") print $2 }'; }

# The session pane: this script's own pane when it is in this window (an agent running
# `up` from the cockpit is the normal case), else the first untagged pane.
session_pane() {
    local me="${TMUX_PANE:-}"
    if [ -n "$me" ]; then
        untagged | grep -Fxq "$me" && { echo "$me"; return; }
    fi
    untagged | head -1
}

panes_in() { tmux list-panes -t "$WINDOW" 2>/dev/null | wc -l; }

HEAL_LOG="$RUN/cockpit-heal.log"
HEAL_STAMP="$RUN/.cockpit-heal-stamp"
HEAL_COOLDOWN="${COCKPIT_HEAL_COOLDOWN:-60}"

heal_log() {
    printf '%s %s\n' "$(TZ="${SPIRA_TZ:-${TZ:-}}" date '+%Y-%m-%dT%H:%M:%S')" "$*" | tee -a "$HEAL_LOG"
}

# One target per DISTINCT window holding cockpit panes. Dedup is by window_id, not by
# name: `cockpit:2` and `brain:0` are the same window object, so a name-keyed scan would
# find the break twice and repair it twice.
cockpit_windows() {
    tmux list-panes -a -F '#{window_id}|#{session_name}:#{window_index}|#{@cockpit}' 2>/dev/null \
        | awk -F'|' '$3=="panel" || $3=="health" { if (!seen[$1]++) print $2 }'
}

# A repair that fails repeatedly must not be retried on every poll.
heal_ready() {
    [ -f "$HEAL_STAMP" ] || return 0
    [ $(( $(date +%s) - $(stat -c %Y "$HEAL_STAMP") )) -ge "$HEAL_COOLDOWN" ]
}

# NEVER `pgrep -f`/`pkill -f` the collector on its own. The pattern is a substring of any
# command line that MENTIONS it — including this script's caller. `pkill -f 'collect.sh
# loop'` in `down` killed the shell that invoked it, and the matching `pgrep` reported
# "collector: already running" by matching that same shell, which is how the panes spent
# 17 hours rendering a frozen snapshot while every check said green.
#
# So pgrep only NOMINATES candidates, and /proc decides. The collector's argv is
# `bash <collect.sh> loop`; any shell that merely names it has argv[1] == "-c".
collector_pids() {
    local p argv
    for p in $(pgrep -f 'cockpit/collect\.sh' 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        argv=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null) || continue
        [ "$(printf '%s\n' "$argv" | sed -n 2p)" = "$COCK/collect.sh" ] || continue
        [ "$(printf '%s\n' "$argv" | sed -n 3p)" = "loop" ] || continue
        echo "$p"
    done
}

collector_running() { [ -n "$(collector_pids)" ]; }

# A collector that is alive but no longer writing is worse than a dead one: the panes keep
# rendering and every liveness check stays green. Freshness is the property that matters,
# so it is what gets measured. One pass is ~27s of probes plus a 10s sleep.
snapshot_age() {
    [ -f "$RUN/cockpit.env" ] || { echo 999999; return; }
    echo $(( $(date +%s) - $(stat -c %Y "$RUN/cockpit.env") ))
}

stop_collector() {
    local p
    for p in $(collector_pids); do kill "$p" 2>/dev/null || true; done
}

start_collector() {
    collector_running && { echo "collector: already running"; return; }
    # systemd owns the collector when the unit is installed. Spawning a nohup copy
    # alongside it gives two writers to one snapshot and two rows per tick in the time
    # series, and systemd's restart would keep resurrecting its own on top.
    if systemctl --user list-unit-files cockpit-collector.service >/dev/null 2>&1 \
       && systemctl --user cat cockpit-collector.service >/dev/null 2>&1; then
        systemctl --user start cockpit-collector.service 2>/dev/null && sleep 1
        collector_running && { echo "collector: started (systemd)"; return; }
    fi
    nohup "$COCK/collect.sh" loop >"$RUN/collect.log" 2>&1 &
    sleep 1
    collector_running && echo "collector: started" || echo "collector: FAILED — see $RUN/collect.log" >&2
}

# Epoch seconds at which a pid started.
# Returns the process's start epoch, or FAILS. It must never answer 0 for "I could not
# tell": every caller compares it against a file mtime, and 0 means infinitely old, so a
# failed probe reads as "running code from before the file existed" and triggers a repair.
#
# That is not hypothetical. `ps` gets slow and drops requests when the box is loaded, and on
# between 19:30 and 20:42 -- while CI, a container build and the visual suite were
# all running -- this restarted the collector 2212 times. Each restart added load, which made
# the next probe likelier to fail. A repair loop that feeds on its own load is worse than the
# staleness it exists to catch.
#
# The dashboard learned this already: a failed probe renders `?`, never 0.
proc_start() {
    local e; e=$(ps -o etimes= -p "$1" 2>/dev/null | tr -d ' ')
    [ -n "$e" ] || return 1
    echo $(( $(date +%s) - e ))
}

# A LONG-RUNNING PROCESS HOLDS THE SCRIPT IT READ AT LAUNCH. Editing health.sh or
# rebuilding the decisions binary changes nothing in a pane that is already running —
# The health pane once ran 39-minute-old code and showed no sign of two edits,
# which read as "the change had no effect" rather than "the change never loaded".
# So: if the code is newer than the process, restart the process.
rebuild_panel_if_stale() {
    # THE BINARY IS GITIGNORED, SO LANDING PANEL CODE SHIPS NOTHING. restart_if_stale
    # compares the BINARY's mtime to the pane's start time and respawns — but nothing
    # rebuilt the binary, and nothing in .claude ran cargo at all. An aeon that lands a
    # panel fix therefore changed the repo and not the pane the operator reads, which is the
    # merged-is-not-deployed trap with a one-minute self-healing loop sitting right next
    # to it doing nothing about it.
    local dir="$COCK/panel" bin="$SPIRA_PANEL" newest
    [ -d "$dir/src" ] || return 0
    command -v cargo >/dev/null 2>&1 || return 0
    newest=$(find "$dir/src" "$dir/Cargo.toml" -newer "$bin" -print -quit 2>/dev/null)
    # No binary at all also means build. -newer against a missing file finds nothing.
    [ -n "$newest" ] || [ ! -x "$bin" ] || return 0
    # One build at a time: the timer fires every minute and a release build is not fast.
    exec 9>"$COCK/panel/.build.lock" 2>/dev/null || return 0
    flock -n 9 || return 0
    heal_log "panel: source newer than binary — rebuilding"
    if (cd "$dir" && timeout 600 nice -n 10 cargo build --release >/dev/null 2>&1); then
        heal_log "panel: rebuilt; restart_if_stale will swap the pane"
    else
        # A broken build must not silently leave the old binary looking current.
        heal_log "panel: REBUILD FAILED — pane still running the previous binary"
    fi
    exec 9>&-
}

restart_if_stale() { # pane_tag script_path
    local tag="$1" src="$2" pane pid started mtime
    pane="$(tagged "$tag")"; [ -n "$pane" ] || return 0
    [ -f "$src" ] || return 0
    pid=$(tmux list-panes -t "$WINDOW" -F '#{@cockpit} #{pane_pid}' 2>/dev/null | awk -v t="$tag" '$1==t{print $2; exit}')
    [ -n "$pid" ] || return 0
    started=$(proc_start "$pid") || {
        heal_log "$WINDOW: $tag start time unreadable — leaving it alone"
        return 0
    }
    mtime=$(stat -c %Y "$src" 2>/dev/null || echo 0)
    [ "$mtime" -gt "$started" ] || return 0
    heal_log "$WINDOW: $tag is running code older than $src — respawning"
    case "$tag" in
        panel) tmux respawn-pane -k -t "$pane" "$COCK/panel-run.sh" 2>/dev/null ;;
        health)    tmux respawn-pane -k -t "$pane" "$COCK/health.sh loop" 2>/dev/null ;;
    esac
    tag_pane "$pane" "$tag"
}

# Same problem for the collector, which systemd supervises but will happily keep running
# a superseded copy of collect.sh forever.
restart_collector_if_stale() {
    local pids p started mtime
    mtime=$(stat -c %Y "$COCK/collect.sh" 2>/dev/null || echo 0)
    for p in $(collector_pids); do
        started=$(proc_start "$p") || {
            heal_log "collector $p start time unreadable — leaving it alone"
            continue
        }
        if [ "$mtime" -gt "$started" ]; then
            # A REPAIR MUST ACT ON THE PROCESS IT DIAGNOSED. This restarted the systemd
            # service whatever it found — so an ORPHANED collector, one systemd does not
            # supervise, was diagnosed correctly every minute and never touched: the
            # restart cycled a healthy service while the offender kept running. Measured
            #: one orphan alive 3.4 days, 4,291 futile restarts logged, and up
            # to three collectors racing on the same cockpit.env.
            local main; main=$(systemctl --user show cockpit-collector.service -p MainPID --value 2>/dev/null || echo 0)
            if [ -n "$main" ] && [ "$main" != 0 ] && [ "$p" = "$main" ]; then
                heal_log "collector $p (supervised) is running code older than collect.sh — restarting the service"
                systemctl --user restart cockpit-collector.service 2>/dev/null
            elif systemctl --user cat cockpit-collector.service >/dev/null 2>&1; then
                # Confirm on argv from /proc before killing: pgrep may nominate, /proc decides.
                if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF 'collect.sh'; then
                    heal_log "collector $p is an ORPHAN systemd does not supervise — killing it"
                    kill "$p" 2>/dev/null || true
                else
                    heal_log "collector $p vanished or is not a collector — leaving it alone"
                fi
            else
                stop_collector; start_collector >/dev/null 2>&1
            fi
            return 0
        fi
    done
}

# --- the two splits, in the one order that produces the shape -------------------
# `-f` IS WHAT MAKES A REPAIR PRODUCE THE SAME SHAPE AS A FRESH BUILD. A plain split takes
# its TARGET pane's height, so a health pane respawned after the left column had already
# been divided came back the height of whichever half it was split from — a quadrant, on
# the correct side, the correct width, running the correct program. `-f` spans the full
# window height whatever the target looks like, so `up` and every repair path agree.
split_health() {   # split_health <any pane in the left column> -> pane id on stdout
    tmux split-window -P -F '#{pane_id}' -d -h -f -l "${RIGHT_PCT}%" -t "$1" -c "$CWD" \
        "$COCK/health.sh loop"
}
# NO `-f` HERE, and that is deliberate: a full-window `-v` split would run under the health
# column too and cut it off at the knees. The panel divides the LEFT column only, which is
# what splitting the session pane in place does.
split_panel() {    # split_panel <session pane> -> pane id on stdout
    tmux split-window -P -F '#{pane_id}' -d -v -l "${BOTTOM_PCT}%" -t "$1" -c "$CWD" \
        "$COCK/panel-run.sh"
}

geom() { tmux display-message -p -t "$1" "$2" 2>/dev/null; }

# POSITION IS PART OF THE LAYOUT, NOT A COINCIDENCE. This file's first line promises the
# session top-left, the panel beneath it and health down the right, and the operator reads
# the three by position — attention on the left is where they look for what is waiting on
# them. Nothing enforced it: repair respawned a dead panel with `split-window -h -t
# <health>`, which places the new pane to the RIGHT of its target, so every repair silently
# flipped the two. Presence was checked, placement never was.
#
# THREE INVARIANTS, AND A QUADRANT VIOLATES THE ONE THAT IS HARDEST TO SEE. A half-height
# health pane is on the right, the right width, and running the right program; only its
# height is wrong, and the eye reads it as the layout working. So the height is measured
# against the window rather than looked at.
normalize_geometry() {
    local d h s dl hl hh wh dt st anchor

    # 1. MIRRORED — the panel holds the right column and health is in the left. A swap
    #    exchanges the two PROCESSES and leaves the geometry alone, which is exactly the
    #    repair: health lands in the pane that is already the full-height column.
    d="$(tagged panel)"; h="$(tagged health)"
    if [ -n "$d" ] && [ -n "$h" ]; then
        dl="$(geom "$d" '#{pane_left}')"; hl="$(geom "$h" '#{pane_left}')"
        if [ -n "$dl" ] && [ -n "$hl" ] && [ "$dl" -gt "$hl" ]; then
            heal_log "$WINDOW: panel is right of health — swapping back"
            tmux swap-pane -s "$d" -t "$h" 2>/dev/null || true
        fi
    fi

    # 2. HEALTH SPANS THE FULL WINDOW HEIGHT. Anything less is the old quadrant coming
    #    back, and it cannot be swapped or resized into the right shape while a pane sits
    #    above or below it — the column has to be cut from the window again.
    h="$(tagged health)"
    if [ -n "$h" ]; then
        hh="$(geom "$h" '#{pane_height}')"; wh="$(geom "$h" '#{window_height}')"
        if [ -n "$hh" ] && [ -n "$wh" ] && [ "$hh" -lt "$wh" ]; then
            heal_log "$WINDOW: health is $hh of $wh rows — rebuilding it as a full-height column"
            anchor="$(session_pane)"; [ -n "$anchor" ] || anchor="$(tagged panel)"
            if [ -n "$anchor" ] && [ "$anchor" != "$h" ]; then
                tmux kill-pane -t "$h" 2>/dev/null || true
                h="$(split_health "$anchor")" && [ -n "$h" ] && tag_pane "$h" health
            fi
        fi
    fi

    # 3. THE PANEL SITS BELOW THE SESSION. Beside it, or above it, is a left column that
    #    never got divided the way `up` divides it.
    d="$(tagged panel)"; s="$(session_pane)"
    if [ -n "$d" ] && [ -n "$s" ]; then
        dt="$(geom "$d" '#{pane_top}')"; st="$(geom "$s" '#{pane_top}')"
        if [ -n "$dt" ] && [ -n "$st" ] && [ "$dt" -le "$st" ]; then
            heal_log "$WINDOW: panel is not below the session — rebuilding it there"
            tmux kill-pane -t "$d" 2>/dev/null || true
            d="$(split_panel "$s")" && [ -n "$d" ] && tag_pane "$d" panel
        fi
    fi
}

repair_dashboards() {
    local sess; sess="$(session_pane)"
    [ -n "$sess" ] || return 0

    # DUPLICATES FIRST. A respawn racing this repair once produced two panes tagged
    # `decisions`, which squeezed the band to 52 columns and wrapped every line to
    # nonsense. `all_tagged` existed to catch this and nothing acted on it.
    local role seen keep p
    for role in panel health; do
        seen=""
        for p in $(tmux list-panes -t "$WINDOW" -F '#{@cockpit} #{pane_id}' 2>/dev/null \
                   | awk -v t="$role" '$1==t {print $2}'); do
            if [ -z "$seen" ]; then seen="$p"; continue; fi
            heal_log "$WINDOW: duplicate $role pane $p — closing"
            tmux kill-pane -t "$p" 2>/dev/null || true
        done
    done

    local d h
    d="$(tagged panel)"; h="$(tagged health)"
    [ -n "$d" ] && [ -n "$h" ] && { normalize_geometry; return 0; }

    # A REBUILD REPRODUCES COLUMN-THEN-ROW, never a band. Both paths anchor on the session
    # pane and use `split_health`/`split_panel` for exactly that reason: the old code split
    # from whichever pane had survived, which under a divided left column handed the new
    # health pane that half's height and quietly restored the quadrant.
    if [ -z "$d" ] && [ -z "$h" ]; then
        heal_log "$WINDOW: both dashboards gone — rebuilding column, then row"
        h="$(split_health "$sess")" || return 1
        [ -n "$h" ] && tag_pane "$h" health
        d="$(split_panel "$sess")" || return 1
        [ -n "$d" ] && tag_pane "$d" panel
    elif [ -z "$h" ]; then
        heal_log "$WINDOW: health pane gone — respawning as the full-height right column"
        h="$(split_health "$sess")" || return 1
        [ -n "$h" ] && tag_pane "$h" health
    else
        heal_log "$WINDOW: panel pane gone — respawning below the session"
        d="$(split_panel "$sess")" || return 1
        [ -n "$d" ] && tag_pane "$d" panel
    fi
    normalize_geometry
    tmux select-pane -t "$sess" 2>/dev/null || true
}

case "$ACTION" in

up)
    tmux has-session -t "${WINDOW%%:*}" 2>/dev/null || { echo "no tmux session for '$WINDOW'" >&2; exit 1; }
    adopt_untagged

    sess="$(session_pane)"
    if [ -z "$sess" ]; then
        # Every pane is a dashboard: the session pane died and the dashboards inherited the
        # window. Open its replacement FIRST — killing the dashboards to make room would
        # empty the window, and an empty window is a destroyed window.
        sess=$(tmux split-window -P -F '#{pane_id}' -b -v -l 60% -t "$(all_tagged | head -1)" -c "$CWD") \
            || { echo "cockpit: could not restore the session pane" >&2; exit 1; }
        echo "cockpit: session pane was gone — opened a shell at $sess"
    fi

    # Rebuild the dashboards from scratch. Killing first is what makes `up` a repair: a duplicated
    # or mis-nested dashboard from an earlier bad run is removed rather than split again.
    for p in $(all_tagged); do tmux kill-pane -t "$p" 2>/dev/null || true; done

    # THE COLUMN FIRST. Splitting the window horizontally while the session pane still owns
    # all of it is the whole trick: the new pane inherits the window's height, and only
    # afterwards is what remains divided between the session and the panel. Reverse these
    # two lines and the dashboard is a quadrant again.
    hea=$(split_health "$sess") \
        || { echo "cockpit: health split failed" >&2; exit 1; }
    tag_pane "$hea" health

    dec=$(split_panel "$sess") \
        || { echo "cockpit: panel split failed" >&2; exit 1; }
    tag_pane "$dec" panel

    echo "cockpit: up in $WINDOW (session $sess · panel $dec · health $hea)"
    # ALWAYS hand focus back to the session pane: hunk-open sends keys to the active pane.
    tmux select-pane -t "$sess" 2>/dev/null || true
    start_collector
    ;;

down)
    adopt_untagged
    sess="$(session_pane)"
    if [ -z "$sess" ]; then
        # Refuse rather than empty the window — `down` promises a full-height session pane,
        # and there is none left to leave behind. `up` is the command that repairs this.
        echo "cockpit: no session pane in $WINDOW — run 'layout.sh up' to restore it" >&2
        exit 1
    fi
    for p in $(all_tagged); do tmux kill-pane -t "$p" 2>/dev/null || true; done
    tmux select-pane -t "$sess" 2>/dev/null || true
    stop_collector
    echo "cockpit: down in $WINDOW (collector stopped)"
    ;;

ensure)
    for w in $(cockpit_windows); do
        WINDOW="$w"
        adopt_untagged
        retag_dashboards
        if [ -n "$(session_pane)" ]; then
            # Session pane is fine — but a DASHBOARD may still be dead. That is exactly
            # what happened on: the health pane exited, the session pane was
            # healthy, so `ensure` skipped the window and nothing ever brought it back.
            repair_dashboards
            rebuild_panel_if_stale
            restart_if_stale panel "$SPIRA_PANEL"
            restart_if_stale health    "$COCK/health.sh"
            continue
        fi
        heal_ready || continue
        : >"$HEAL_STAMP"
        heal_log "$WINDOW: session pane gone — repairing"
        if out=$("$0" up --window "$WINDOW" 2>&1); then
            heal_log "$WINDOW: $(printf '%s' "$out" | tr '\n' ' ')"
        else
            heal_log "$WINDOW: REPAIR FAILED — $(printf '%s' "$out" | tr '\n' ' ')"
        fi
    done
    # A dead collector leaves both panes rendering a frozen snapshot while every process
    # that draws them looks alive. `up` restarts it, but `up` only runs on a broken layout.
    if [ -n "$(cockpit_windows)" ]; then
        restart_collector_if_stale
        age=$(snapshot_age)
        if ! collector_running; then
            heal_log "collector was dead — restarting"
            start_collector 2>&1 | tee -a "$HEAL_LOG"
        elif [ "$age" -gt "${COCKPIT_STALE:-300}" ]; then
            heal_log "collector alive but snapshot ${age}s stale — restarting"
            stop_collector
            start_collector 2>&1 | tee -a "$HEAL_LOG"
        fi
    fi
    ;;

status)
    adopt_untagged
    echo "window:    $WINDOW ($(panes_in) panes)"
    sess="$(session_pane)"
    echo "session:   ${sess:-MISSING — run 'layout.sh up' to restore it}"
    for t in panel health; do
        p="$(tagged "$t")"
        printf '%-10s %s\n' "$t:" "${p:-absent}"
    done
    echo "collector: $(collector_running && echo "running (pid $(collector_pids | tr '\n' ' '))" || echo stopped)"
    if [ -f "$RUN/cockpit.env" ]; then
        echo "snapshot:  $(snapshot_age)s old"
    else
        echo "snapshot:  missing"
    fi
    [ -f "$RUN/cockpit-history.csv" ] && echo "history:   $(( $(wc -l < "$RUN/cockpit-history.csv") - 1 )) rows"
    ;;

*) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
