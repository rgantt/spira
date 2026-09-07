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

# EVERY PARTITION THE CHAMBER DECLARES, NOT ONE NAMED HERE. This defaulted to `spira,plan`
# — the builder's partition standing in for every persona — so stalled work belonging to any
# other persona was never reported as stalled, by a report whose empty output reads as a
# healthy harness. SPIRA_LABELS still narrows this to one partition, which is what a targeted
# report wants and what the fixtures below pin.
SPIRA_LABELS="${SPIRA_LABELS:-}"
# PARKED IS NOT STRANDED. A bead carrying $SPIRA_CI_LABEL has no live aeon on purpose: its
# work is pushed, its review is open, and the CI sweep is watching the run. Without it here
# that reads exactly like abandoned work — open, unclaimed, nothing moving — and gets
# reclaimed or escalated for doing the right thing.
#
# THE EXCLUSION IS UNCONDITIONAL HERE, AND THE PARK IS WHAT EXPIRES. A park in a repository
# with no CI, or one that has outlived the longest plausible run, is not parked but lost —
# and it must be reported rather than excluded from the report that would have found it. The
# sweep strips the label in both cases, so such a bead arrives here already unparked and is
# classified like any other. Ageing the exclusion here as well would be a second predicate
# answering the same question, and two predicates that can disagree is the defect, not the fix.
# A PARTITION'S EXCLUSIONS ARE ITS OWN, read from the persona that works it. Set
# SPIRA_EXCLUDE_LABELS to override every partition at once; EXCLUDE_DEFAULT is what a
# partition whose fayth declares none falls back to.
SPIRA_EXCLUDE_LABELS="${SPIRA_EXCLUDE_LABELS:-}"
EXCLUDE_DEFAULT="spira-poison,$SPIRA_ASK_LABEL,$SPIRA_CI_LABEL"
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

# THE PERSONAS THAT WORK ONE PARTITION, not every persona that exists. This answers "is
# anything working the beads this row is about", and a running ops aeon says nothing about a
# starved plan — counting it would suppress the one escalation this file exists to raise. So
# the fayths are selected by their own FAYTH_LABELS matching the partition being asked about,
# falling back to the whole chamber if no persona declares it.
live_aeons() {   # live_aeons <labels> -> live aeons working THAT partition
    local fs n=0 f
    fs="$(fayths_for_labels "$1" | tr '\n' ' ')"
    [ -n "${fs// /}" ] || fs="$(spira_fayths)"
    for f in $fs; do n=$((n + $(aeon_count "$f"))); done
    printf '%d' "$n"
}

# THE PARTITIONS THIS RUN COVERS: one "<labels>\t<exclude-labels>" a line. SPIRA_LABELS
# narrows it to a single partition; otherwise it is every partition in the chamber, so
# installing a persona is the whole of having its work watched.
partitions() {
    local labels exclude
    if [ -n "$SPIRA_LABELS" ]; then
        printf '%s\t%s\n' "$SPIRA_LABELS" "${SPIRA_EXCLUDE_LABELS:-$EXCLUDE_DEFAULT}"
        return 0
    fi
    while IFS=$'\t' read -r labels exclude; do
        [ -n "$labels" ] || continue
        printf '%s\t%s\n' "$labels" "${SPIRA_EXCLUDE_LABELS:-${exclude:-$EXCLUDE_DEFAULT}}"
    done < <(fayth_partitions)
    return 0
}

# The partitions named, for a human: what an empty report is an empty report ABOUT.
watching() { partitions | cut -f1 | paste -sd' ' -; }

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
# Every row carries the partition it came from as its first column, because the partition is
# part of a strand's identity: the episode state keyed on kind and id alone let one starved
# partition suppress the escalation for the next one to starve, and a report of several
# partitions cannot name an action without saying which queue it is about.
classify() {
    local labels exclude n=0
    if [ -n "$FROM" ]; then
        # A saved TSV is already classified, so the partition dimension does not apply to it:
        # the rows are attributed to SPIRA_LABELS if one was named, and to `-` otherwise.
        { [ "$FROM" = - ] && cat || cat -- "$FROM"; } \
        | while IFS= read -r r; do
              [ -n "$r" ] && printf '%s\t%s\n' "${SPIRA_LABELS:--}" "$r"
          done
        return 0
    fi
    while IFS=$'\t' read -r labels exclude; do
        [ -n "$labels" ] || continue
        n=$((n+1))
        classify_one "$labels" "$exclude" \
        | while IFS= read -r r; do
              [ -n "$r" ] && printf '%s\t%s\n' "$labels" "$r"
          done
    done < <(partitions)
    # NOTHING WATCHED AND NOTHING STRANDED ARE THE SAME SILENCE unless one of them says so
    # (law-absence-needs-a-positive-control).
    [ "$n" -gt 0 ] || log "WARN no persona in the chamber declares a partition — no work is being watched for strands" >&2
    return 0
}

classify_one() {   # classify_one <labels> <exclude-labels> -> the classifier's own TSV
    local labels="$1" exclude="$2" beads ready live holders id
    beads="$(bdjson list --limit 0 --label "$labels")"
    ready="$(bdjson ready --limit 0 --exclude-type epic --label "$labels" \
                    --exclude-label "$exclude")"
    live="$(live_aeons "$labels")"

    holders="$(printf '%s' "$beads" | python3 -c '
import sys, json
try: rows = json.load(sys.stdin)
except Exception: rows = []
print("\n".join(r["id"] for r in rows if r.get("status") == "in_progress"))' 2>/dev/null \
    | while IFS= read -r id; do
          [ -n "$id" ] || continue
          if holder_alive "$id"; then printf '%s\t1\n' "$id"; else printf '%s\t0\n' "$id"; fi
      done)"

    # THE TWO PAYLOADS GO THROUGH FILES, NOT THE ENVIRONMENT. One environment string may
    # not exceed MAX_ARG_STRLEN (128 KiB); a partition of a few hundred beads is several
    # times that, and execve then refuses the classifier with "Argument list too long" on
    # every pass — which the sentinel logged 204 times in one afternoon while every other
    # line of each pass read as normal. The holders list and the counters stay inline;
    # they are lines, not corpora.
    local tmp; tmp="$(mktemp -d)" || return 1
    printf '%s' "$beads" > "$tmp/beads.json"
    printf '%s' "$ready" > "$tmp/ready.json"
    BEADS_FILE="$tmp/beads.json" READY_FILE="$tmp/ready.json" HOLDERS="$holders" LIVE="$live" \
    GHOST_GRACE="$GHOST_GRACE" python3 "$HERE/strand-classify.py"
    local rc=$?
    rm -rf "$tmp"
    return "$rc"
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
for part, kind, ident, disp, detail, action in rows:
    # THE PARTITION IS PART OF THE IDENTITY. Keyed on kind and id alone, the `starved` row —
    # whose id is "-" because it is about a queue rather than a bead — collided across
    # partitions, so the second queue to starve inherited the first's suppression and its
    # escalation was never raised.
    key = "%s:%s:%s" % (part, kind, ident)
    e = st.get(key) or {"first": now, "acted": 0, "escalated": 0}
    keep[key] = e
    out.append("\t".join([part, kind, ident, disp, str(now - int(e["first"])),
                          str(e.get("acted") or 0), str(e.get("escalated") or 0), detail, action]))
if os.environ.get("WRITE") == "1":
    with open(path + ".tmp", "w") as fh: json.dump(keep, fh)
    os.replace(path + ".tmp", path)
print("\n".join(out))
PY
}

state_mark() {    # state_mark <partition> <kind> <id> <acted|escalated>
    KEY="$1:$2:$3" FIELD="$4" STATE_FILE="$STATE" python3 <<'PY'
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
    part, k, i, d, age, acted, esc, detail, action = r.split("\t")
    rows.append({"partition": part, "kind": k, "id": i, "disposition": d, "age_seconds": int(age),
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
        # NAME WHAT WAS LOOKED AT. "no stranded work" over a partition nobody works reads
        # exactly like a healthy harness, which is the defect this file was scoped by.
        echo "no stranded work in [$(watching)]"
        return 0
    fi
    printf '%-16s %-20s %-16s %-9s %6s  %s\n' PARTITION KIND ID DISPOSITION AGE DETAIL
    while IFS=$'\t' read -r part kind id disp age acted esc detail action; do
        [ -n "${kind:-}" ] || continue
        printf '%-16s %-20s %-16s %-9s %5sm  %s\n' "$part" "$kind" "$id" "$disp" "$(( age / 60 ))" "$detail"
        printf '%71s→ %s\n' "" "$action"
    done <<< "$rows"
}

# ======================================================================================
# check — the timer path
# ======================================================================================
escalate() {   # escalate <partition> <kind> <id> <detail> <action>
    local part="$1" kind="$2" id="$3" detail="$4" action="$5" title ctx
    # A TITLE BUILT FROM A MISSING ID READS AS A BUG. `starved` is about a queue, not a
    # bead, so $id is "-" and the ask arrived titled "Spira stranded (starved): -". The
    # queue is then named by its partition, because "the plan is stranded" is the wrong
    # sentence about an incident queue and the operator cannot tell which one is meant.
    if [ -n "$id" ] && [ "$id" != "-" ]; then
        title="Spira: $id is stranded ($kind)"
    elif [ -n "$part" ] && [ "$part" != "-" ]; then
        title="Spira: the [$part] queue is stranded ($kind)"
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
    local rows acted=0 n; local -a scope
    rows="$(classify | state_apply 1)"
    [ -n "$rows" ] || return 0

    while IFS=$'\t' read -r part kind id disp age was_acted was_esc detail action; do
        [ -n "${kind:-}" ] || continue
        [ "$disp" = info ] && continue

        if [ "$DRY" = 1 ]; then
            log "would $disp $kind $id in [$part] (${age}s, acted=$was_acted escalated=$was_esc): $detail"
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
                    # SCOPED TO THE ROW'S OWN PARTITION, never to one named here: a
                    # reclaim filtered by the builder's labels is a no-op on every other
                    # persona's bead, and it exits 0 saying nothing.
                    scope=(); [ "$part" != "-" ] && scope=(--label "$part")
                    bdq reclaim --id "$id" --older-than 1s "${scope[@]}" >/dev/null 2>&1
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
            state_mark "$part" "$kind" "$id" acted
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
        escalate "$part" "$kind" "$id" "$detail" "$action"
        state_mark "$part" "$kind" "$id" escalated
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
