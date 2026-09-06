#!/usr/bin/env bash
#
# collect.sh — gather Gas Town health into a snapshot + time series for the cockpit.
#
#   collect.sh once     one pass, write snapshot and append a history row, exit
#   collect.sh loop     forever: fast tier every 10s, slow tier every 120s
#
# WHY A COLLECTOR AND NOT DIRECT CALLS
# ------------------------------------
# Measured, per invocation:
#
#   gt ready            6900 ms      gt status --json    1202 ms
#   gt scheduler status 4963 ms      bd list deferred     669 ms
#   gt agents            464 ms      gt mq list           293 ms
#
# A pane calling those every repaint would block ~14s per cycle and paint stale frames
# while it did. The cost is paid here on a slow cadence; panes read a file and repaint
# instantly. Two tiers, because the expensive sources are the slow-changing ones.
#
# The snapshot is flat key=value so a renderer can `source` it with no parser, and a
# half-written file cannot wedge a pane. Writes are atomic (temp + mv).
#
# A HISTORY ROW IS APPENDED EVERY PASS so the panes can draw trends rather than a
# single instant — a number that is merely large tells you less than one that is
# climbing. Bounded to HISTORY_MAX rows.
#
# THREE TRAPS, EACH HIT WHILE BUILDING THIS
# -----------------------------------------
# 1. `gt agents` reports "No agent sessions running." unless the cwd is inside the town.
#    Run from anywhere else it reports a healthy town as empty.
# 2. `bd --json` can print `warning: beads.role not configured` on STDOUT before the
#    JSON, so a naive json.load throws.
# 3. `bd list` defaults to `--limit 50`. Counting anything above 50 without `--limit 0`
#    silently truncates.
#
# And the rule that governs all three: **a probe that fails reports `?`, never 0.** The
# first version returned 0 from its exception handler, so a broken parser rendered as
# "no parked beads" — a panel that lies confidently is worse than no panel, because it
# displaces the suspicion that would have prompted a check.
set -uo pipefail

# Every path comes from the harness's one configuration surface. It is two directories
# away because the cockpit ships beside the harness, not inside it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../spira" && pwd -P)/conf.sh"
export BEADS_NO_AUTO_IMPORT=1
TOWN="${TOWN:-$SPIRA_TOWN}"
# EVERY PROBE IN THIS FILE IS THE PREDECESSOR HARNESS'S. An operator who never ran one has no
# such directory, and running anyway would render the whole pane as `?` — which this file
# defines as "the probe failed", so an installation with nothing to collect would look like an
# installation whose collection is broken. Say which it is, and stop. The Spira half of the
# cockpit is spira/cockpit.sh and is unaffected.
if [ -z "$TOWN" ] || [ ! -d "$TOWN" ]; then
    printf 'collect: no predecessor harness configured (SPIRA_TOWN in %s) — nothing to collect\n' \
        "${SPIRA_CONF_FILE:-spira.conf}"
    exit 0
fi
RUN="$SPIRA_REPO/.runtime"
SNAP="$RUN/cockpit.env"
HIST="$RUN/cockpit-history.csv"
HISTORY_MAX=3000
mkdir -p "$RUN"

RIGS=()

# bd --json may emit human warnings on stdout before the payload.
strip_warnings() { grep -vE '^(warning:|  Fix:|  Or:)'; }

# Count deferred beads that no agent has escalated. THE INVARIANT: a filed bead is
# worked XOR escalated; deferred without the escalation label is neither, and 130 of them once
# hid a bug the operator hit himself. Beads the operator deferred himself are their call, not a violation.
count_parked() {
    local rig_dir="$1"
    bd -C "$rig_dir" list --status deferred --limit 0 --json 2>/dev/null | strip_warnings | python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit          # broken probe says so; it never says 0
rows = d if isinstance(d, list) else d.get("issues", [])
print(sum(1 for r in rows
          if (r.get("created_by") or "") != "the operator"
          and os.environ.get("SPIRA_ASK_LABEL", "needs-operator") not in (r.get("labels") or [])))' 2>/dev/null || echo "?"
}

collect_fast() {
    local out="$RUN/.fast.$$"
    {
        echo "FAST_AT=$(date +%s)"

        # MUST run inside the town, or a healthy town reports as empty.
        local agents; agents=$(cd "$TOWN" && gt agents 2>/dev/null)
        if [ -z "$agents" ] || grep -qi 'No agent sessions' <<<"$agents"; then
            echo "AGENT_MAYOR=0"; echo "AGENT_DEACON=0"
            echo "LIVE_POLECATS=0"; echo "LIVE_REFINERIES=0"; echo "LIVE_WITNESSES=0"
        else
            local np nr nw
            np=$(grep -ciE '^[[:space:]]*(😺|.*polecat)' <<<"$agents" || true)
            nr=$(grep -ci 'refinery' <<<"$agents" || true)
            nw=$(grep -ci 'witness'  <<<"$agents" || true)
            echo "AGENT_MAYOR=$(grep -qi 'mayor'  <<<"$agents" && echo 1 || echo 0)"
            echo "AGENT_DEACON=$(grep -qi 'deacon' <<<"$agents" && echo 1 || echo 0)"
            echo "LIVE_POLECATS=${np:-0}"
            echo "LIVE_REFINERIES=${nr:-0}"
            echo "LIVE_WITNESSES=${nw:-0}"
        fi

        local mq; mq=$( (cd "$TOWN" && gt mq list 2>/dev/null) | grep -cE '^[[:space:]]*[a-z]{2}-' || true)
        echo "MQ_DEPTH=${mq:-0}"

        # Watchers: silence from a dead watcher is indistinguishable from a quiet night,
        # which is the failure this panel exists to make visible.
        local w; w=$(bash "$TOWN/settings/watchd.sh" status 2>/dev/null)
        local wl; wl=$(grep -E '^(rig|mail|prs|town)\b' <<<"$w")
        local wr wt
        wr=$(grep -cE '\b(running|cron)\b' <<<"$wl" || true)
        wt=$(grep -c . <<<"$wl" || true)
        echo "WATCH_RUNNING=${wr:-0}"
        echo "WATCH_TOTAL=${wt:-0}"
        echo "WATCH_UNREAD=$(awk '{s+=$3} END{print s+0}' <<<"$wl")"

        echo "DISK_ROOT=$(df -P / | awk 'NR==2{gsub(/%/,"");print $5}')"
        echo "DISK_WS=$(df -P "$SPIRA_WORKSPACES" | awk 'NR==2{gsub(/%/,"");print $5}')"

        # The concierge is the phone's only way in; down means the phone is dark.
        echo "CONCIERGE=$(tmux -L concierge has-session -t concierge 2>/dev/null && echo 1 || echo 0)"

        # the operator's inline replies from the decisions pane. The Monitor tailing this file
        # is the ONLY thing that surfaces them, and it was once killed with
        # eleven others — so a real answer about Aftercare sat unread for eight hours
        # while everything looked healthy. A channel whose only reader can die silently
        # needs a dead-man's switch, so the count is rendered here too.
        if [ -f "$RUN/replies.log" ]; then
            _total=$(grep -c . "$RUN/replies.log" 2>/dev/null || true)
            _seen=$(cat "$RUN/replies.cursor" 2>/dev/null || echo 0)
            echo "REPLIES_UNREAD=$(( ${_total:-0} - ${_seen:-0} ))"
        else
            echo "REPLIES_UNREAD=0"
        fi

        # Mail is a PULL medium — nothing announces a Mayor reply.
        echo "MAIL_UNREAD=$( (cd "$TOWN" && gt mail inbox 2>/dev/null) | head -1 | grep -oE '[0-9]+ unread' | grep -oE '^[0-9]+' || echo 0)"
    } > "$out" 2>/dev/null
    mv -f "$out" "$RUN/fast.env"
}

collect_slow() {
    local out="$RUN/.slow.$$"
    {
        echo "SLOW_AT=$(date +%s)"

        local sched; sched=$(cd "$TOWN" && gt scheduler status 2>/dev/null)
        echo "SCHED_MODE=$(grep -qi 'direct dispatch' <<<"$sched" && echo direct || echo deferred)"
        echo "SCHED_STATE=$(grep -oiE 'State:[[:space:]]*[a-z]+' <<<"$sched" | awk '{print $2}' | head -1)"
        # Kept verbatim: under a cap this reads "0 free of 2 (working: 0, recovery: 6)",
        # which is a deadlock wearing a throttle's clothes and must not be reduced.
        echo "SCHED_CAP=$(grep -i 'Capacity:' <<<"$sched" | sed 's/.*Capacity:[[:space:]]*//' | head -1)"

        local ready; ready=$(cd "$TOWN" && gt ready 2>/dev/null)
        local r total=0
        for r in "${RIGS[@]}" town; do
            local n; n=$(grep -oE "^${r}/ \([0-9]+ items\)" <<<"$ready" | grep -oE '[0-9]+' | head -1)
            n=${n:-0}
            echo "READY_${r}=${n}"
            [ "$r" = town ] || total=$(( total + n ))
        done
        echo "READY_RIGTOTAL=$total"

        local ptotal=0 pbroken=0
        for r in "${RIGS[@]}"; do
            local d; d=$(count_parked "$TOWN/$r")
            echo "PARKED_${r}=${d}"
            if [ "$d" = "?" ]; then pbroken=1; else ptotal=$(( ptotal + d )); fi
        done
        echo "PARKED_TOTAL=$([ "$pbroken" = 1 ] && echo '?' || echo $ptotal)"

        # POLECAT CAPACITY.
        # Three different numbers, and conflating them is what made the auto-feed gate
        # fight itself: `counts_toward_capacity` includes healthy WORKING polecats, so it
        # rises as work flows. `needs_recovery` is the one that means STUCK, and it is what
        # the gate gates on — the dashboard must use the same word for the same thing.
        (cd "$TOWN" && gt polecat list --all --json 2>/dev/null) | strip_warnings | python3 -c '
import json, sys, collections
try:
    rows = json.load(sys.stdin)
except Exception:
    print("POLECAT_PROBE=?"); raise SystemExit
per = collections.defaultdict(collections.Counter)
tot = collections.Counter()
for r in rows:
    rig = r.get("rig", "?")
    marks = [("DIRS", True),
             ("CAP", bool(r.get("counts_toward_capacity"))),
             ("RECOV", bool(r.get("needs_recovery"))),
             ("UNSUB", bool(r.get("needs_mq_submit"))),
             ("WORKING", r.get("state") == "working")]
    for key, hit in marks:
        if hit:
            per[rig][key] += 1
            tot[key] += 1
for rig, c in per.items():
    for key in ("DIRS", "CAP", "RECOV", "UNSUB", "WORKING"):
        print("POLECAT_%s_%s=%d" % (key, rig, c[key]))
for key in ("DIRS", "CAP", "RECOV", "UNSUB", "WORKING"):
    print("POLECAT_%s_TOTAL=%d" % (key, tot[key]))
print("POLECAT_PROBE=ok")' 2>/dev/null || echo "POLECAT_PROBE=?"

        # Recovery survey, written hourly by settings/recover-polecats.sh. Read rather
        # than recomputed: check-recovery is ~40s per polecat and the survey is serial.
        # RECOVERY_BLOCKED is the number that decides whether auto-feed can be enabled at
        # all, since scheduler capacity is max minus this.
        if [ -f "$TOWN/.runtime/recovery/status.env" ]; then
            # Strip the file's own quoting; the snapshot writer quotes everything once
            # on the way out, and quoting twice renders the value as "'13'".
            sed -nE "s/^(RECOVERY_[A-Z]+)='?([^']*)'?$/\1=\2/p" \
                "$TOWN/.runtime/recovery/status.env" 2>/dev/null || true
        else
            echo "RECOVERY_BLOCKED=?"
        fi

        # CLOSED != LANDED. Orphaned commits are work that exists only in a dead
        # worktree; 18 sat unnoticed in one repository alone.
        local otot=0 o
        for r in "${RIGS[@]}"; do
            o=$( (cd "$TOWN" && gt orphans --rig "$r" --all 2>/dev/null) | grep -cE '^  [0-9a-f]{8} ' || true)
            o=${o:-0}
            echo "ORPHANS_${r}=${o}"
            otot=$(( otot + o ))
        done
        echo "ORPHANS_TOTAL=$otot"

        # LAW DRIFT. Memories are per-database, so a statute enacted in the town is
        # invisible to a rig until law-sync runs. Drift means agents are reading
        # different law from each other.
        local town_laws drift=0 rl
        town_laws=$(bd -C "$TOWN" memories --json 2>/dev/null | strip_warnings | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
print(sum(1 for k,v in d.items() if k.startswith("law-") and isinstance(v,str)))' 2>/dev/null || echo -1)
        echo "STATUTES_TOWN=${town_laws}"
        for r in "${RIGS[@]}"; do
            rl=$(bd -C "$TOWN/$r" memories --json 2>/dev/null | strip_warnings | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
print(sum(1 for k,v in d.items() if k.startswith("law-") and isinstance(v,str)))' 2>/dev/null || echo -1)
            [ "$rl" = "$town_laws" ] || drift=$(( drift + 1 ))
        done
        echo "STATUTE_DRIFT=$drift"

        # Load-bearing config that has silently been wrong before.
        echo "CFG_NOTIFY=$(cd "$TOWN" && gt config get convoy.notify_on_complete 2>/dev/null | head -1)"
        echo "CFG_MAXPOLECATS=$(cd "$TOWN" && gt config get scheduler.max_polecats 2>/dev/null | head -1)"
    } > "$out" 2>/dev/null
    mv -f "$out" "$RUN/slow.env"
}

# --------------------------------------------------------------------------------------
# SPIRA. Its own collector, writing its own snapshot at .runtime/spira/cockpit.env, driven
# from here only because this service is already running on a timer of the right shape.
#
# Kept as a separate program and a separate file rather than merged into this one: Gas Town
# is being retired and everything above goes with it, so the Spira half must not be
# entangled with code scheduled for deletion. When this collector goes, `cockpit.sh loop`
# under its own unit replaces the call — a unit file, not a rewrite.
#
# Failure is swallowed on purpose. A broken Spira probe must not stop the town snapshot from
# being written; the pane renders `?` for whatever is missing, which is the honest reading
# and is louder than a collector that silently stopped.
# --------------------------------------------------------------------------------------
collect_spira() {
    bash "$SPIRA_HOME/cockpit.sh" once >/dev/null 2>&1 || true
}

merge_and_append() {
    local out="$RUN/.snap.$$"
    # SHELL-QUOTE EVERY VALUE. The renderers `source` this file, and a raw value like
    #   SCHED_CAP=direct dispatch (scheduler.max_polecats=-1)
    # is a syntax error that aborts the source — so every key AFTER it silently reads as
    # unset and the whole panel renders "?" while the collector looks healthy.
    { cat "$RUN/slow.env" 2>/dev/null; cat "$RUN/fast.env" 2>/dev/null; } \
      | python3 -c '
import sys
for line in sys.stdin:
    line = line.rstrip("\n")
    if "=" not in line:
        continue
    k, _, v = line.partition("=")
    k = k.strip()
    if not k or not (k[0].isalpha() or k[0] == "_"):
        continue
    print("%s=%s" % (k, "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27"))
' > "$out"
    mv -f "$out" "$SNAP"

    # shellcheck disable=SC1090
    set +u; . "$SNAP" 2>/dev/null; set -u
    [ -s "$HIST" ] || echo "ts,live_polecats,mq_depth,ready_rigtotal,parked_total,disk_root,watch_unread,mail_unread" > "$HIST"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date +%s)" "${LIVE_POLECATS:-0}" "${MQ_DEPTH:-0}" "${READY_RIGTOTAL:-0}" \
        "${PARKED_TOTAL:-0}" "${DISK_ROOT:-0}" "${WATCH_UNREAD:-0}" "${MAIL_UNREAD:-0}" >> "$HIST"

    # Bound the series: keep the header plus the newest HISTORY_MAX rows.
    local lines; lines=$(wc -l < "$HIST")
    if [ "$lines" -gt $(( HISTORY_MAX + 1 )) ]; then
        { head -1 "$HIST"; tail -n "$HISTORY_MAX" "$HIST"; } > "$HIST.tmp" && mv -f "$HIST.tmp" "$HIST"
    fi
}

case "${1:-once}" in
once)
    collect_slow; collect_spira; collect_fast; merge_and_append
    echo "collect: $SNAP ($(wc -l < "$SNAP") keys), history $(( $(wc -l < "$HIST") - 1 )) rows"
    ;;
loop)
    last_slow=0
    while :; do
        now=$(date +%s)
        # Spira rides the slow tier: the sentinel it reports on runs every two minutes, so a
        # faster cadence would repaint the same numbers, and its git and bead queries are the
        # same class of cost as everything else on this tier.
        if [ $(( now - last_slow )) -ge 120 ]; then collect_slow; collect_spira; last_slow=$now; fi
        collect_fast; merge_and_append
        sleep 10
    done
    ;;
*) echo "usage: collect.sh once|loop" >&2; exit 1 ;;
esac
