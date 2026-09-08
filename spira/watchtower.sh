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
# HALTED? A deliberately stopped world must not manufacture incidents. Every pipeline
# metric grows monotonically while nothing is wrong — time since last landing, queue depth
# — so a sweep against a halted world describes a system that is broken when it is not.
# cockpit/health.sh reads the same stamp directly for the same reason: a stale or absent
# snapshot must not mask a deliberate halt.
# ---------------------------------------------------------------------------------------
HALT_STAMP="$SPIRA_RUN/world.halted"
halt_since=""; halt_why=""
if [ -f "$HALT_STAMP" ]; then
    halt_since="$(head -1 "$HALT_STAMP" 2>/dev/null)"
    halt_why="$(sed -n '2s/^why: //p' "$HALT_STAMP" 2>/dev/null)"
fi

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
# THE RECORD HAS NO TRAILING NEWLINE, and `read` reports that as failure. land_mark writes
# with `printf '%s %s %s %s'` deliberately — the in-tree reader strips newlines anyway — so
# every landstate file ends mid-line, and `read` returns 1 at EOF-without-delimiter EVEN
# THOUGH IT HAS ALREADY POPULATED EVERY VARIABLE. A `|| continue` on that status therefore
# discarded a perfectly good record, and this field rendered `?  (last: none recorded)` on
# every sweep ever filed, including passes where six beads had landed in the previous twelve
# minutes. Three Ops sessions were woken by it, each one re-deriving the same directory by
# hand to prove the pipeline was moving.
#
# So the reader tolerates the failed status and lets the guards below it judge the content:
# a record is believed only if its state is LANDED and its timestamp is numeric, which a
# truncated or empty file cannot satisfy. Do not "fix" this by adding a newline to the
# writer — two readers already depend on the current format and the writer is not wrong.
#
# THE FOUR VARIABLES ARE RESET BEFORE EACH READ, and that is load-bearing rather than tidy:
# `read` leaves the previous iteration's values in place when it fails early, so an
# unreadable file would otherwise be judged on the LAST file's state and this loop would
# attribute one bead's landing to another.
last_land="?"; last_land_id=""
if [ -d "$SPIRA_RUN/landstate" ]; then
    while IFS= read -r f; do
        [ -r "$f" ] || continue
        st=""; _tip=""; at=""; _why=""
        read -r st _tip at _why < "$f" 2>/dev/null || true
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
# THE WINDOW IS A DURATION, NEVER A ROW COUNT. "The worst wait in the last 50 rows" reads as
# recent and is not: gate.log holds one row per gate run, so on a quiet day fifty rows are a
# week and "recent" silently means "ever". That is not hypothetical either — this field spent
# a day reporting 1584s from a wait produced by a locking topology the gate rebuild had
# already deleted, while every row written since read `waited=0s`. A decommissioned
# mechanism's worst case was being presented to Ops as a live signal, and three sweeps
# re-investigated it.
#
# THE CUTOFF IS COMPARED AS A STRING, which is exactly as sound as arithmetic here and needs
# no date parsing in awk: the meter writes `date -u +%Y-%m-%dT%H:%M:%SZ`, and ISO-8601 UTC
# timestamps of fixed width sort lexicographically in chronological order. A row whose first
# field is not such a timestamp — a truncated write, a line from some older format — falls
# outside every window and is ignored rather than counted as now.
#
# NO ROW INSIDE THE WINDOW RENDERS `?`, NOT 0. "No gate has waited recently" and "no gate has
# RUN recently" are opposite facts and a zero states the reassuring one (law-absence-needs-a-
# positive-control); the second is what a stalled pipeline looks like from here.
GATE_WINDOW="${SPIRA_WATCH_GATE_WINDOW:-21600}"
# THROUGH THE SAME KEY THE METER WRITES. This read `$SPIRA_RUN/gate.log` directly, so an
# operator who moved the log left this field reading `?` forever while the gate went on
# writing somewhere else — a probe pointed at the wrong place, which is the failure the whole
# `?` convention exists to make visible rather than one it is allowed to have.
WT_GATE_LOG="${SPIRA_GATE_LOG:-$SPIRA_RUN/gate.log}"
oldest_wait="?"; oldest_br=""
if [ -r "$WT_GATE_LOG" ]; then
    gate_since="$(date -u -d "@$(( now - GATE_WINDOW ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    if [ -n "$gate_since" ]; then
        read -r oldest_wait oldest_br < <(awk -v since="$gate_since" '
            $1 >= since && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$/ &&
            match($0, /waited=[0-9]+s/) {
                w = substr($0, RSTART+7, RLENGTH-8) + 0
                if (!n++ || w > m) { m = w; b = $3 }
            } END { if (n) print m, b; else print "?", "" }' "$WT_GATE_LOG" 2>/dev/null)
    fi
fi
# What the field PRINTS, decided here rather than in the heredoc, so that a `?` is not
# rendered as `?s` — a unit on an unreadable field invites reading it as a measurement.
gate_wait_disp="?"
[ "$oldest_wait" = "?" ] || gate_wait_disp="${oldest_wait}s"
# The window is NAMED in the field, because "recent" is the word that let this go wrong: a
# reader who can see the bound can tell a quiet six hours from a broken probe.
if [ "$GATE_WINDOW" -ge 3600 ] 2>/dev/null; then gate_win_label="last $(( GATE_WINDOW / 3600 ))h"
else gate_win_label="last $(( GATE_WINDOW / 60 ))m"; fi

# ---------------------------------------------------------------------------------------
# IS THE GATE WORTH WHAT IT COSTS? The wait above says what the gate costs the queue; these
# say whether it is buying anything. A gate whose reds are mostly its own fault has negative
# value and can be deleted in a sentence on this evidence, instead of after twelve hours of
# fallout — which is how the last one went (law-gate-earns-its-place).
#
# READ BY OPS, NOT ONLY BY A HUMAN AT A PANE. Ops is the actor that reads this sweep and cuts
# beads from it; a yield that could only be seen by somebody who went looking would be the
# same failure one layer up, since going to look is exactly what nobody did.
#
# yield.sh renders `?` for anything it could not read and this passes that through unchanged.
# SPIRA_RUN is passed explicitly because conf.sh does not export it, and a child re-deriving
# it would read a different directory and report a confident zero.
YIELD_REDS="?"; YIELD_DEFECT="?"; YIELD_FAULT="?"; YIELD_UNKNOWN="?"; YIELD_RECORDER="?"
YIELD_DEFECT_INFERRED="?"; YIELD_TOP_FAULT="?"
YIELD_SOLO_N="?"; YIELD_SOLO_MED="?"; YIELD_SOLO_MAX="?"
YIELD_CONC_N="?"; YIELD_CONC_MED="?"; YIELD_CONC_MAX="?"
YIELD_SH="$(dirname "$0")/yield.sh"
YIELD_WINDOW_S="${SPIRA_YIELD_WINDOW:-86400}"
if [ -r "$YIELD_SH" ]; then
    # shellcheck disable=SC1090
    eval "$(SPIRA_RUN="$SPIRA_RUN" SPIRA_YIELD_WINDOW="$YIELD_WINDOW_S" \
            bash "$YIELD_SH" report 2>/dev/null \
            | sed -n 's/^\(YIELD_[A-Z_]*\)=\(.*\)$/\1="\2"/p')" 2>/dev/null || true
fi
if [ "$YIELD_WINDOW_S" -ge 86400 ] 2>/dev/null; then yield_win_label="last $(( YIELD_WINDOW_S / 86400 ))d"
elif [ "$YIELD_WINDOW_S" -ge 3600 ] 2>/dev/null; then yield_win_label="last $(( YIELD_WINDOW_S / 3600 ))h"
else yield_win_label="last $(( YIELD_WINDOW_S / 60 ))m"; fi
# A UNIT ON AN UNREADABLE FIELD INVITES READING IT AS A MEASUREMENT — `?s` looks like a
# duration somebody forgot to fill in, and this whole file exists because a reassuring
# reading displaced a look.
secs() { [ "${1:-?}" = "?" ] && printf '?' || printf '%ss' "$1"; }
# A `?` WITH NO EXPLANATION SENDS OPS TO THE CODE. The yield's own positive control is the
# gate meter, which writes a row on every red whether or not anything is measuring; when the
# two disagree the count is withheld, and this is the sentence that says which of them was
# silent so the sweep names the fault rather than the symptom.
yield_note_txt=""
case "$YIELD_RECORDER" in
    silent) yield_note_txt="   <- the gate meter saw ${YIELD_LOG_REDS:-?} red(s) and none reached the record: THE RECORDER IS NOT RUNNING" ;;
    absent) yield_note_txt="   <- nothing recorded here yet, and the meter has logged no reds either" ;;
    '?')    yield_note_txt="   <- no positive control: the gate meter could not be read" ;;
esac

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

# ---------------------------------------------------------------------------------------
# THE MENU. The sweep names scans for the Ops session to RUN; it does not run them here.
#
# That division is the whole point and it is not decoration. This program's contract is to be
# deterministic and cheap, because the one thing a detector may not be is another thing that
# is down during an outage — a several-minute test run inside it would make it exactly that,
# and would push a ten-minute cadence past the interval that produces it. So the menu is a
# NAME plus the cheap facts that say whether the scan is worth this pass, and the session
# spends its own eight minutes on it.
#
# `suites.sh status` is a glob and a read per suite: no database, no network, nothing that
# can hang. A pass that cannot produce it prints why rather than an empty section, because a
# menu with nothing on it and a menu that could not be built read identically otherwise.
SUITES="$(dirname "$0")/suites.sh"
suites_block="  (unavailable — $SUITES is missing, so nothing knows which suites run nowhere)"
if [ -r "$SUITES" ]; then
    suites_block="$(bash "$SUITES" status 2>/dev/null)"
    [ -n "$suites_block" ] || suites_block="  (unreadable — suites.sh status produced nothing)"
fi

# THE STRAND LEDGER IS TWO LINES, NOT ONE. strands.json holds every disposition strand.sh
# classifies, and only `ghost` is the labelled failure this line names — a claimed bead whose
# holder is gone. This rendered the ledger's SIZE under that name, so a childless epic read
# as a dead worker and a sweep spent four commands hunting for a holder that never existed.
# The collector does the classifying (cockpit.sh strand_keys); this only renders it.
#
# A SNAPSHOT WRITTEN BY A COLLECTOR PREDATING THAT SPLIT RENDERS `?`, WHICH IS CORRECT: `g`
# reports an absent key as unread, and during a rollout the two halves are briefly skewed.
# `?` says this pass could not read it. A 0 would say there are none, which nobody checked.

# Pre-computed so the heredoc below can reference it as a plain variable. A trailing
# newline is intentional: the heredoc adds one more, giving a blank line between the halt
# banner and the body text.
halt_section=""
if [ -n "$halt_since" ]; then
    halt_section="!! HALTED since ${halt_since}"
    [ -n "$halt_why" ] && halt_section="${halt_section}
   why: ${halt_why}"
    halt_section="${halt_section}
   No incidents are filed while the halt is in force.
"
fi

snapshot() {
cat <<EOF
## Spira pipeline, $(date -u +%Y-%m-%dT%H:%M:%SZ)
${halt_section}
N workers pull from a DAG into a merge queue. These are that queue's vital signs. A field
reading \`?\` is one this pass COULD NOT READ — never treat it as a zero.

### The far end — is anything coming out?

  minutes since the last landing      ${since_land}      (last: ${last_land_id:-none recorded})
  branches finished but not landed    $(g SP_UNLANDED)
  branches done and waiting           $(g SP_BRANCH_DONE)
  $(printf '%-36s' "longest gate wait, $gate_win_label")${gate_wait_disp}   ${oldest_br:-}
  worst no-verdict streak             ${nv_worst}       ${nv_worst_key:-none}

### The gate — is it buying anything?

  UNKNOWN is never folded into either column. A run of them means this measurement has
  itself stopped working, which is the one thing a yield figure must not hide.

  $(printf '%-36s' "gate reds, $yield_win_label")${YIELD_REDS}${yield_note_txt}
  $(printf '%-36s' "  the branch really was wrong")${YIELD_DEFECT}      (${YIELD_DEFECT_INFERRED} inferred from a later pass, not stated)
  $(printf '%-36s' "  the gate's own fault")${YIELD_FAULT}      worst: ${YIELD_TOP_FAULT}
  $(printf '%-36s' "  never classified")${YIELD_UNKNOWN}
  $(printf '%-36s' "gate cost, solo")$(secs "$YIELD_SOLO_MED") median, $(secs "$YIELD_SOLO_MAX") worst (n=${YIELD_SOLO_N})
  $(printf '%-36s' "gate cost, another gate overlapping")$(secs "$YIELD_CONC_MED") median, $(secs "$YIELD_CONC_MAX") worst (n=${YIELD_CONC_N})

### The workers

  aeons alive                         ${aeons_live}      (counted now, not from the snapshot)
  beads in progress                   $(g SP_INPROG)
  ready to claim                      $(g SP_READY)
  poisoned                            $(g SP_POISON)
  stranded (claimed, nobody home)     $(g SP_STRAND_GHOST)
  strand ledger, other classes        $(g SP_STRAND_OTHER)
  account capacity paused             $(g SP_CAPACITY_PAUSED)

### The graph

  open $(g SP_OPEN) · closed $(g SP_CLOSED) · landed $(g SP_LANDED) · needs-operator $(g SP_NEEDSOP)
  parked on CI $(g SP_AWAITING_N), oldest $(g SP_AWAITING_AGE), stuck $(g SP_AWAITING_STUCK)

### The menu — run these scans, then look for what they do not cover

A sweep is not only a set of numbers to read. These are the scans that are worth sampling
before anything else, because each answers a question the numbers above cannot.

  bash $SUITES run

    Every \`spira/test-*.sh\` in the tree that the landing gate does NOT run, discovered by
    glob so a new suite is run by existing and a deleted one stops being run. It files a bead
    per red, blocks nothing and reopens nothing, and is budgeted at ${SPIRA_SUITES_BUDGET:-420}s
    so it fits inside your own wall. Worth a pass when a figure below says a timed suite has
    no result or a stale one; skip it when they are all fresh and green.

$suites_block

### Can this snapshot be believed?

  collector snapshot age              ${snap_age}s   (stale above ${SNAP_AGE_MAX}s)
  sentinel timer                      $(g SP_SENTINEL_TIMER)   last pass $(g SP_SENTINEL_AGE)s ago
EOF
}

[ "${1:-}" = "--show" ] && { snapshot; exit 0; }

# A HALTED WORLD MUST NOT FILE. The halt stamp is the authoritative record; checking it
# here rather than relying on the snapshot's staleness means a slow or dead collector
# cannot make a deliberate halt look like an anomaly worth escalating.
if [ -n "$halt_since" ]; then
    log "watchtower: halted since ${halt_since} (${halt_why:-why unstated}) — sweep skipped"
    exit 0
fi

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
# SPIRA_INCIDENT_SH overrides the path so test suites can inject a mock without reaching
# a real database. Same seam sentinel.sh carries for systemctl.
INC="${SPIRA_INCIDENT_SH:-$(dirname "$0")/incident.sh}"
[ -x "$INC" ] || [ -r "$INC" ] || { log "watchtower: $INC is missing — the sweep reaches nobody"; exit 1; }
# FILED AS A CHORE BY THE WATCHTOWER, not as a bug by whoever ran the timer. The intake
# defaults to `--type bug --priority 1` because its original caller was a crashed unit; a
# ten-minute health sweep is routine, and filing it that way put a chore in the operator's
# own queue wearing his name and a defect's type.
# The prefix must sit on the READER, not the writer: in `VAR=x cmd1 | cmd2`, the
# assignment scopes to cmd1 only — each side of a pipeline forks its own subshell
# before the assignment is applied, so a left-side prefix never reaches incident.sh
# and it silently falls back to --type bug --priority 1, actor unset (sp-b9qs).
snapshot | SPIRA_INCIDENT_TYPE=chore \
SPIRA_INCIDENT_PRIORITY=2 \
SPIRA_INCIDENT_ACTOR=watchtower \
SPIRA_SIN_EXEMPT=1 \
bash "$INC" file "Spira sweep — is the pipeline moving?" - >/dev/null || {
    log "watchtower: could not file the sweep"; exit 1; }
log "watchtower: swept — ${since_land}m since the last landing, $(g SP_UNLANDED) unlanded, ${aeons_live} aeons"
