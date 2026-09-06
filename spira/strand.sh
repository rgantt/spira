#!/usr/bin/env bash
#
# strand.sh — stranded-work detection: work that exists and is not moving, with the reason.
#
#   strand.sh report [--json]   the human view; changes nothing   (what `gt convoy stranded` was)
#   strand.sh check             the timer path: act where the fix is mechanical, escalate once
#                               where it is not
#   strand.sh check --dry-run   classify and print, change nothing
#   strand.sh check --from <f>  classify a saved TSV instead of the live graph
#
# WHAT THIS REPLACES, AND THE TWO DEFECTS IT DOES NOT INHERIT
# ----------------------------------------------------------
# `gt convoy stranded`. Its own help calls a convoy stranded when it has ready-but-unassigned
# issues, OR no ready issues at all, OR no issues at all — three unrelated conditions with
# three unrelated fixes, printed as one undifferentiated list. Measured: all six
# convoys were "stranded", every one of them with ready_count 0, and nothing had acted on any
# of them. A list that cannot say WHICH condition it found cannot name an action, and a report
# that names no action becomes wallpaper. Every row here carries a kind and the single command
# that clears it.
#
# The second defect is the one this bead exists for. Gas Town's liveness test is "ready but
# unassigned" — an assignee, which is exactly the proxy that lies. `gt polecat list` counts
# DIRECTORIES; a bead assigned to a polecat that died an hour ago reads as worked. Spira asks
# /proc instead: an aeon writes its pid beside the bead id it claimed, and liveness is that pid
# still being an aeon. Never pgrep -f — the pattern is a substring of the caller's own command
# line, so a check for 'aeon.sh' inside a script that mentions it reports itself alive.
#
# ACT ONCE, THEN ESCALATE — NEVER RETRY FOREVER
# ---------------------------------------------
# A kind whose fix is mechanical (a ghost lease, a stale is_blocked flag) is acted on exactly
# ONCE per episode. If the same strand is still there on the next pass, the action did not work
# and repeating it is noise, so it escalates instead. That bound is what keeps this from
# becoming a loop that reclaims the same bead every two minutes and reports an action it did
# not achieve.
#
# WHY THE EPISODE STATE IS A FILE AND NOT `bd kv`
# -----------------------------------------------
# pilgrimage.sh keeps its completion markers in the beads KV store because "this notice was
# DELIVERED" is a fact about the world that cannot be re-derived. "I first noticed this strand
# at 06:14" can be: it is an observation, recomputed from the graph on every pass, and putting
# it in the store of record would write a Dolt commit into a database mirrored to three
# replicas every time a strand appears or clears.
#
# THE BLIND SPOT, NAMED
# ---------------------
# Run from the sentinel, this cannot detect that the sentinel is dead — a check cannot observe
# the failure of the thing running it. So `starved` reports the harness's own liveness from
# systemd and the log mtime, which is the answer the moment anything ELSE runs this: the
# concierge, the cockpit, or the operator.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

SPIRA_LABELS="${SPIRA_LABELS:-spira,plan}"
# PARKED IS NOT STRANDED. A bead labelled `awaiting-ci` has no live aeon on purpose: its
# work is pushed, its review is open, and the CI sweep is watching the run. Without it here
# that reads exactly like abandoned work — open, unclaimed, nothing moving — and gets
# reclaimed or escalated for doing the right thing.
SPIRA_EXCLUDE_LABELS="${SPIRA_EXCLUDE_LABELS:-spira-poison,$SPIRA_ASK_LABEL,awaiting-ci}"
# THE PERSONAS THAT WORK THIS PARTITION, not every persona that exists. live_aeons below
# answers "is anything working the beads this report is about", and a running Ops aeon says
# nothing about a starved plan — counting it would suppress the one escalation this file
# exists to raise. So the fayths are selected by their own FAYTH_LABELS matching the
# partition being reported on, falling back to the whole chamber if none declares it.
FAYTHS="$(fayths_for_labels "$SPIRA_LABELS" | tr '\n' ' ')"
[ -n "${FAYTHS// /}" ] || FAYTHS="$(spira_fayths)"
# A lease outlives its aeon by design; the grace window is what separates "dead" from the
# few seconds between `bd ready --claim` and the pidfile being written, and the few seconds
# between the pidfile being removed and the unclaim. Default is one lease TTL.
GHOST_GRACE="${SPIRA_GHOST_GRACE:-300}"
# How long a strand must persist before it is worth the operator's attention. Ready work with no aeon
# is NORMAL for one sentinel period — that is the gap between a bead becoming ready and the
# next pass summoning for it. Seven passes is not.
STRAND_GRACE="${SPIRA_STRAND_GRACE:-900}"
STATE="$SPIRA_RUN/strands.json"
ASK="$SPIRA_NOTIFY"
SENTINEL_LOG="$SPIRA_RUN/sentinel.log"

MODE=report; JSON=0; DRY=0; FROM=
# `${1:-report}` defaults for the MATCH only; `MODE="$1"` then dereferenced $1 unguarded,
# so under `set -u` the documented default invocation — a bare `strand.sh`, which is what a
# runbook reaches for — died with "line 76: $1: unbound variable" while `strand.sh check`
# worked. The loop was fine and the human entry point was not.
MODE="${1:-report}"
case "$MODE" in report|check) shift 2>/dev/null || true ;; *) MODE=report ;; esac
while [ $# -gt 0 ]; do
    case "$1" in
        --json)    JSON=1 ;;
        --dry-run) DRY=1 ;;
        # Classify a saved TSV instead of the live graph. This is how the state machine is
        # tested — and how you replay a strand someone reported an hour ago.
        --from)    FROM="${2:?--from needs a file, or - for stdin}"; shift ;;
        -h|--help) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown argument '$1' — try: report [--json] | check [--dry-run]" ;;
    esac
    shift
done

# --------------------------------------------------------------------------------------
# Liveness. holder_alive answers "is a live aeon working THIS bead", which is a stronger
# statement than any status column can make: the bead says in_progress until something
# reclaims it, whether or not anyone is still there.
# --------------------------------------------------------------------------------------
holder_alive() {   # holder_alive <bead-id>
    local id="$1" pf
    for pf in "$SPIRA_RUN"/aeon-*-"$id".pid; do
        [ -e "$pf" ] || continue
        aeon_alive "$pf" && return 0
    done
    return 1
}

live_aeons() { local n=0 f; for f in $FAYTHS; do n=$((n + $(aeon_count "$f"))); done; printf '%d' "$n"; }

# The harness's own pulse, for the case where this is run from outside it.
harness_state() {
    local active age=-1 mtime now
    active="$(systemctl --user is-active spira-sentinel.timer 2>/dev/null)"
    [ -n "$active" ] || active=unknown
    if [ -f "$SENTINEL_LOG" ]; then
        mtime="$(stat -c %Y "$SENTINEL_LOG" 2>/dev/null || echo 0)"
        now="$(date +%s)"; age=$(( now - mtime ))
    fi
    printf '%s %s' "$active" "$age"
}

# ======================================================================================
# CLASSIFY. One `bd list` carries the whole partition — status, labels, parent and the
# dependency edges — so the graph analysis is a single query plus one `bd ready` for the
# claimable set. is_blocked is not in that payload and is deliberately not trusted here:
# `bd ready` is the authority on what a fayth can actually claim.
# ======================================================================================
classify() {
    local beads ready live holders id
    if [ "$FROM" = - ]; then cat; return 0; fi
    if [ -n "$FROM" ]; then cat -- "$FROM"; return 0; fi
    beads="$(bdjson list --limit 0 --label "$SPIRA_LABELS")"
    ready="$(bdjson ready --limit 0 --exclude-type epic --label "$SPIRA_LABELS" \
                    --exclude-label "$SPIRA_EXCLUDE_LABELS")"
    live="$(live_aeons)"

    holders="$(printf '%s' "$beads" | python3 -c '
import sys, json
try: rows = json.load(sys.stdin)
except Exception: rows = []
print("\n".join(r["id"] for r in rows if r.get("status") == "in_progress"))' 2>/dev/null \
    | while IFS= read -r id; do
          [ -n "$id" ] || continue
          if holder_alive "$id"; then printf '%s\t1\n' "$id"; else printf '%s\t0\n' "$id"; fi
      done)"

    BEADS="$beads" READY="$ready" HOLDERS="$holders" LIVE="$live" \
    GHOST_GRACE="$GHOST_GRACE" python3 "$HERE/strand-classify.py"
}

# ======================================================================================
# EPISODE STATE. One JSON object keyed <kind>:<id>, carrying when the strand was first seen
# and whether it has already been acted on or escalated. Pruned every pass against what is
# actually stranded now, so a cleared strand starts a fresh episode rather than inheriting a
# suppression from the last one.
# ======================================================================================
state_apply() {   # state_apply <write:0|1> — stdin: rows; stdout: rows + age, acted, escalated
    ROWS="$(cat)" STATE_FILE="$STATE" WRITE="${1:-0}" python3 <<'PY'
import json, os, time
rows = [r.split("\t") for r in (os.environ.get("ROWS") or "").splitlines() if r.strip()]
path = os.environ["STATE_FILE"]
try:
    with open(path) as fh: st = json.load(fh)
except Exception: st = {}
now = int(time.time())
keep = {}
out = []
for kind, ident, disp, detail, action in rows:
    key = "%s:%s" % (kind, ident)
    e = st.get(key) or {"first": now, "acted": 0, "escalated": 0}
    keep[key] = e
    out.append("\t".join([kind, ident, disp, str(now - int(e["first"])),
                          str(e.get("acted") or 0), str(e.get("escalated") or 0), detail, action]))
if os.environ.get("WRITE") == "1":
    with open(path + ".tmp", "w") as fh: json.dump(keep, fh)
    os.replace(path + ".tmp", path)
print("\n".join(out))
PY
}

state_mark() {    # state_mark <kind> <id> <acted|escalated>
    KEY="$1:$2" FIELD="$3" STATE_FILE="$STATE" python3 <<'PY'
import json, os, time
path = os.environ["STATE_FILE"]
try:
    with open(path) as fh: st = json.load(fh)
except Exception: st = {}
e = st.setdefault(os.environ["KEY"], {"first": int(time.time()), "acted": 0, "escalated": 0})
e[os.environ["FIELD"]] = int(time.time())
with open(path + ".tmp", "w") as fh: json.dump(st, fh)
os.replace(path + ".tmp", path)
PY
}

# ======================================================================================
# report
# ======================================================================================
cmd_report() {
    local rows n active age
    rows="$(classify | state_apply 0)"
    read -r active age < <(harness_state)

    if [ "$JSON" = 1 ]; then
        ROWS="$rows" ACTIVE="$active" AGE="$age" python3 <<'PY'
import json, os
rows = []
for r in (os.environ.get("ROWS") or "").splitlines():
    if not r.strip(): continue
    k, i, d, age, acted, esc, detail, action = r.split("\t")
    rows.append({"kind": k, "id": i, "disposition": d, "age_seconds": int(age),
                 "acted_at": int(acted), "escalated_at": int(esc),
                 "detail": detail, "action": action})
print(json.dumps({"sentinel_timer": os.environ["ACTIVE"],
                  "last_pass_seconds": int(os.environ["AGE"]),
                  "strands": rows}, indent=2))
PY
        return 0
    fi

    printf 'sentinel timer: %s   last pass: %ss ago\n\n' "$active" "$age"
    n="$(printf '%s' "$rows" | grep -c . || true)"
    if [ "${n:-0}" -eq 0 ]; then
        echo "no stranded work in $SPIRA_LABELS"
        return 0
    fi
    printf '%-20s %-16s %-9s %6s  %s\n' KIND ID DISPOSITION AGE DETAIL
    while IFS=$'\t' read -r kind id disp age acted esc detail action; do
        [ -n "${kind:-}" ] || continue
        printf '%-20s %-16s %-9s %5sm  %s\n' "$kind" "$id" "$disp" "$(( age / 60 ))" "$detail"
        printf '%54s→ %s\n' "" "$action"
    done <<< "$rows"
}

# ======================================================================================
# check — the timer path
# ======================================================================================
escalate() {   # escalate <kind> <id> <detail> <action>
    local kind="$1" id="$2" detail="$3" action="$4" title ctx
    # A TITLE BUILT FROM A MISSING ID READS AS A BUG. `starved` is about the plan, not a
    # bead, so $id is "-" and the ask arrived titled "Spira stranded (starved): -".
    if [ -n "$id" ] && [ "$id" != "-" ]; then
        title="Spira: $id is stranded ($kind)"
    else
        title="Spira: the plan is stranded ($kind)"
    fi
    # THE BEAD ITSELF, not just its id. "what went wrong" cannot be decided without
    # "what was this for" (the operator's call).
    ctx="$(bead_context "$id" 2>/dev/null)"
    ctx="$ctx

WHY THIS IS STRANDED
$detail

SENTINEL STATE
$(tail -n 12 "$SENTINEL_LOG" 2>/dev/null || echo '(sentinel log unreadable)')"
    "$ASK" add "$title" \
        --default "$action" \
        --why "$detail — nothing in the plan below it can move until this clears" \
        --evidence "$ctx" >/dev/null 2>&1
}

cmd_check() {
    local rows acted=0 n
    rows="$(classify | state_apply 1)"
    [ -n "$rows" ] || return 0

    while IFS=$'\t' read -r kind id disp age was_acted was_esc detail action; do
        [ -n "${kind:-}" ] || continue
        [ "$disp" = info ] && continue

        if [ "$DRY" = 1 ]; then
            log "would $disp $kind $id (${age}s, acted=$was_acted escalated=$was_esc): $detail"
            continue
        fi

        if [ "$disp" = act ] && [ "$was_acted" = 0 ]; then
            case "$kind" in
                ghost)
                    # --older-than 1s deliberately: reclaim's grace window is a heuristic for
                    # liveness it cannot observe, and we have already observed it directly.
                    # The bump is the point — a hard-killed aeon never runs its cleanup trap,
                    # so without this the attempt counter under-counts and a bead that kills
                    # its aeon every time is never poisoned.
                    bdq reclaim --id "$id" --older-than 1s --label "$SPIRA_LABELS" >/dev/null 2>&1
                    # THE SECOND DOOR ONTO THE ATTEMPT COUNTER. aeon.sh declines to charge an
                    # attempt when the API refused the session, but an aeon hard-killed
                    # mid-outage never reaches that code — it arrives here as a ghost, and
                    # charging it would restore exactly the harm by another route. Ask the
                    # bead's own surviving session log first, and fall back to "is the
                    # harness paused right now", which is true for the whole of an outage and
                    # is what covers a session killed before it wrote anything.
                    if capacity_reset_at "$SPIRA_RUN/$id.log" >/dev/null || capacity_paused; then
                        bdq note "$id" "Reclaimed by strand.sh during a capacity outage: the account was out, so no attempt was charged and nothing about the work is implied." >/dev/null 2>&1
                        printf 'RECLAIMED %s (no attempt — capacity outage) — %s\n' "$id" "$detail"
                    else
                        n="$(bump_attempt "$id")"
                        bdq note "$id" "Reclaimed by strand.sh: in_progress with no live aeon holding it and the lease expired. Attempt $n." >/dev/null 2>&1
                        printf 'RECLAIMED %s — %s\n' "$id" "$detail"
                    fi
                    ;;
                stale-blocked)
                    bdq recompute-blocked >/dev/null 2>&1
                    printf 'RECOMPUTED is_blocked — %s stuck with every blocker closed\n' "$id"
                    ;;
            esac
            state_mark "$kind" "$id" acted
            acted=$((acted+1))
            continue
        fi

        # Either the fix is not mechanical, or it was tried and did not clear the strand.
        # Escalate exactly once per episode, and only past the grace window — ready work with
        # no aeon for one sentinel period is the normal gap between the two, not a fault.
        [ "$was_esc" = 0 ] || continue
        if [ "$disp" = act ]; then
            detail="$detail (the mechanical fix ran and did not clear it)"
        elif [ "$age" -lt "$STRAND_GRACE" ]; then
            continue
        fi
        escalate "$kind" "$id" "$detail" "$action"
        state_mark "$kind" "$id" escalated
        printf 'STRANDED %s %s — %s\n' "$kind" "$id" "$detail"
        acted=$((acted+1))
    done <<< "$rows"

    [ "$acted" -gt 0 ] && log "check: $acted stranded item(s) handled"
    return 0
}

case "$MODE" in
    report) cmd_report ;;
    check)  cmd_check ;;
esac
