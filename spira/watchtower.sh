#!/usr/bin/env bash
#
# watchtower.sh — wake Ops on a timer and hand it the state of the pipeline.
#
#   watchtower.sh            gather, and file the sweep Ops claims
#   watchtower.sh --show     gather and print; touch nothing
#
# WHY THIS EXISTS (law-detection-outranks-rejection). Ops has always been able to hear about
# a unit that CRASHED — incident.sh files from a systemd OnFailure, and that is its only
# intake. A queue that has stopped moving while every unit is happily `active` is invisible
# to it, and that is not a hypothetical: on 2026-09-07 nothing landed for the better part of
# a morning while every process was green, every log line was individually true, and eleven
# consecutive gate runs correctly reported that the next pass would take it. Nothing noticed.
# The operator did, by looking.
#
# So this is the second intake: not "a process died" but "the pipeline is not doing the thing
# it exists to do". What the system IS, stated plainly, is N workers pulling from a DAG into
# a merge queue — so the numbers that matter are the depth of that queue, how long its oldest
# member has waited, and how long it has been since anything came out of the far end.
#
# IT DOES NOT DECIDE (the operator's call, 2026-09-07, over a threshold-driven detector).
# This program gathers and hands over; an Ops aeon reads the snapshot and decides what is
# wrong and what beads to cut. Thresholds anticipate only the outage you already had — every
# stall so far has been a shape nobody had a number for.
#
# THE SESSION IS BOUNDED BY THIS CADENCE, and that constraint lives in ops.fayth: a sweep
# arrives every ten minutes, so an Ops session gets eight. The first live one ran eighteen
# and would have been working the 22:30 snapshot while 22:40 and 22:50 queued behind it. The
# sweep is also deduped to one open at a time, so a cycle arriving while Ops is still working
# the last one bumps a recurrence rather than filing a second.
#
# IT IS DETERMINISTIC AND CHEAP, deliberately (law-deterministic-before-inference). It reads
# files that already exist and shells out to nothing slow, because the one thing a watchtower
# may not be is another thing that is down during an outage.
#
# A FIELD IT COULD NOT READ RENDERS `?`, NEVER 0 (law-absence-needs-a-positive-control). A
# broken probe reporting "0 branches waiting" is an all-clear that displaces the suspicion
# which would have prompted a look — the exact failure this whole program is a response to.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

SNAP_AGE_MAX="${SPIRA_WATCH_SNAP_MAX:-600}"
now="$(date +%s)"

# ---------------------------------------------------------------------------------------
# THE COLLECTOR'S SNAPSHOT, and whether it can be believed at all. Every other number below
# is read out of cockpit.env, so its freshness is the first fact — a stale file makes the
# whole sweep a report about the past, and reporting the past as the present during an
# outage is worse than reporting nothing.
# ---------------------------------------------------------------------------------------
ENVF="$SPIRA_RUN/cockpit/cockpit.env"
[ -r "$ENVF" ] || ENVF="$SPIRA_RUN/cockpit.env"
snap_age="?"
if [ -r "$ENVF" ]; then
    # shellcheck disable=SC1090
    eval "$(sed -n 's/^\(SP_[A-Z_0-9]*\)=\(.*\)$/\1=\2/p' "$ENVF" 2>/dev/null)" 2>/dev/null || true
    [ -n "${SP_AT:-}" ] && snap_age=$(( now - SP_AT ))
fi
g() { local v="${!1:-}"; [ -n "$v" ] && printf '%s' "$v" || printf '?'; }

# ---------------------------------------------------------------------------------------
# HOW LONG SINCE ANYTHING LANDED — the one number that says whether the pipeline works, and
# the one nothing recorded until landing.sh began writing a landstate file per bead. Read
# from those records rather than from the log, because a log line is prose and this has to
# be arithmetic.
# ---------------------------------------------------------------------------------------
last_land="?"; last_land_id=""
if [ -d "$SPIRA_RUN/landstate" ]; then
    while IFS= read -r f; do
        [ -r "$f" ] || continue
        read -r st _tip at _why < "$f" 2>/dev/null || continue
        [ "$st" = LANDED ] || continue
        case "$at" in ''|*[!0-9]*) continue ;; esac
        if [ "$last_land" = "?" ] || [ "$at" -gt "$last_land" ]; then
            last_land="$at"; last_land_id="$(basename "$f")"
        fi
    done < <(find "$SPIRA_RUN/landstate" -maxdepth 1 -type f 2>/dev/null)
fi
since_land="?"
[ "$last_land" != "?" ] && since_land=$(( (now - last_land) / 60 ))

# ---------------------------------------------------------------------------------------
# WHAT IS STUCK, AND FOR HOW LONG. A queue depth on its own says nothing — a deep queue that
# is moving is a busy system. The age of its oldest member is what tells them apart.
# ---------------------------------------------------------------------------------------
oldest_wait="?"; oldest_br=""
if [ -r "$SPIRA_RUN/gate.log" ]; then
    # The largest wait any gate has recorded in the last 50 rows. The meter that shipped with
    # the tree lock exists precisely to answer this, and on 2026-09-07 it read 1584s while
    # every other signal was green.
    read -r oldest_wait oldest_br < <(tail -50 "$SPIRA_RUN/gate.log" 2>/dev/null | awk '
        match($0, /waited=[0-9]+s/) {
            w = substr($0, RSTART+7, RLENGTH-8) + 0
            if (w > m) { m = w; b = $3 }
        } END { print (m ? m : 0), b }')
fi

# Branches whose gate could not reach a verdict, and how many times in a row. Written by the
# landing pass; three of one reason on one branch is what it escalates on.
nv_worst=0; nv_worst_key=""
if [ -d "$SPIRA_RUN/noverdict" ]; then
    while IFS= read -r f; do
        case "$f" in *.asked) continue ;; esac
        n="$(cat "$f" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) continue ;; esac
        [ "$n" -gt "$nv_worst" ] && { nv_worst="$n"; nv_worst_key="$(basename "$f")"; }
    done < <(find "$SPIRA_RUN/noverdict" -maxdepth 1 -type f 2>/dev/null)
fi

# AEONS ARE COUNTED HERE, FROM /proc, NOT READ OUT OF THE SNAPSHOT. The collector's file is
# up to a minute old, and the first live sweep reported "0 aeons" while two were running —
# because the snapshot predated the summon. Every other number here tolerates being a minute
# stale; this one does not, because "ready work and no workers" is the single shape that
# most looks like a stalled loop, and reporting it wrongly sends Ops to diagnose a stall that
# is not happening. It costs one pass over /proc.
#
# THROUGH aeon_count, THE HARNESS'S OWN PRIMITIVE, not a second implementation. The first
# version of this scanned /proc for a command line containing "aeon.sh" and counted 7 where
# there were 3 — because the scan matched the shell pipelines that were themselves grepping
# for the string, this program's own diagnostics included. That is the `pgrep -f` failure
# exactly, arriving in a hand-rolled shape, three lines under a comment warning about it.
#
# aeon_count reads the pidfiles, which are the authoritative record of a claim, and confirms
# each against /proc on argv rather than on a substring. It is also what the sentinel's pool
# arithmetic uses, so the number reported here and the number the loop acts on cannot drift.
aeons_live=0
for _f in $(spira_fayths 2>/dev/null); do
    aeons_live=$(( aeons_live + $(aeon_count "$_f" 2>/dev/null || echo 0) ))
done

snapshot() {
cat <<EOF
## Spira pipeline, $(date -u +%Y-%m-%dT%H:%M:%SZ)

N workers pull from a DAG into a merge queue. These are that queue's vital signs. A field
reading \`?\` is one this pass COULD NOT READ — never treat it as a zero.

### The far end — is anything coming out?

  minutes since the last landing      ${since_land}      (last: ${last_land_id:-none recorded})
  branches finished but not landed    $(g SP_UNLANDED)
  branches done and waiting           $(g SP_BRANCH_DONE)
  longest gate wait, recent           ${oldest_wait}s   ${oldest_br:-}
  worst no-verdict streak             ${nv_worst}       ${nv_worst_key:-none}

### The workers

  aeons alive                         ${aeons_live}      (counted now, not from the snapshot)
  beads in progress                   $(g SP_INPROG)
  ready to claim                      $(g SP_READY)
  poisoned                            $(g SP_POISON)
  stranded (claimed, nobody home)     $(g SP_STRANDS)
  account capacity paused             $(g SP_CAPACITY_PAUSED)

### The graph

  open $(g SP_OPEN) · closed $(g SP_CLOSED) · landed $(g SP_LANDED) · needs-operator $(g SP_NEEDSOP)
  parked on CI $(g SP_AWAITING_N), oldest $(g SP_AWAITING_AGE), stuck $(g SP_AWAITING_STUCK)

### Can this snapshot be believed?

  collector snapshot age              ${snap_age}s   (stale above ${SNAP_AGE_MAX}s)
  sentinel timer                      $(g SP_SENTINEL_TIMER)   last pass $(g SP_SENTINEL_AGE)s ago
EOF
}

[ "${1:-}" = "--show" ] && { snapshot; exit 0; }

# ---------------------------------------------------------------------------------------
# HAND IT TO OPS. Through incident.sh, which is the intake that already exists — it spools
# write-ahead before touching the database, dedupes on the ref so a sweep filed while the
# last one is still open bumps a recurrence rather than filing a second, and escalates a
# class that keeps returning without ever being fixed. None of that is worth reimplementing.
#
# THE BEAD CARRIES THE NUMBERS. An incident that says "go and look" makes the aeon spend its
# first minutes gathering what this pass has already gathered, and it would gather it a few
# minutes later — so a sweep about a stall would describe a slightly different stall
# (law-escalations-carry-their-evidence).
# ---------------------------------------------------------------------------------------
INC="$(dirname "$0")/incident.sh"
[ -x "$INC" ] || [ -r "$INC" ] || { log "watchtower: $INC is missing — the sweep reaches nobody"; exit 1; }
# FILED AS A CHORE BY THE WATCHTOWER, not as a bug by whoever ran the timer. The intake
# defaults to `--type bug --priority 1` because its original caller was a crashed unit; a
# ten-minute health sweep is routine, and filing it that way put a chore in the operator's
# own queue wearing his name and a defect's type.
SPIRA_INCIDENT_TYPE=chore \
SPIRA_INCIDENT_PRIORITY=2 \
SPIRA_INCIDENT_ACTOR=watchtower \
snapshot | bash "$INC" file "Spira sweep — is the pipeline moving?" - >/dev/null || {
    log "watchtower: could not file the sweep"; exit 1; }
log "watchtower: swept — ${since_land}m since the last landing, $(g SP_UNLANDED) unlanded, ${aeons_live} aeons"
