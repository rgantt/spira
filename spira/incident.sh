#!/usr/bin/env bash
#
# incident.sh — turn a production event into a bead Ops can claim.
#
#   incident.sh systemd <unit>     file an incident for a failed systemd user unit
#   incident.sh file <title> [-|<file>]   file one from an arbitrary payload
#   incident.sh drain              file everything the spool is holding
#   incident.sh list               open incidents
#
# THE INTAKE ALREADY EXISTED IN SHAPE
# -----------------------------------
# `mtgc-alert-<store>@.service` fires from `OnFailure=` on every unit worth hearing about,
# and pushes the failed unit's journal tail to Pushover. That is a notification: it reaches
# the operator's phone and then it is gone. This turns the same event into work with an identity —
# a bead Ops claims with a lease, resolves, and closes with evidence. `install-intake.sh`
# is the wiring; nothing here has to be remembered by a human.
#
# WRITE-AHEAD, THEN FILE
# ----------------------
# The payload is spooled to disk BEFORE the database is touched, and the spool entry is
# removed only once the bead exists. A production event arrives exactly once and cannot be
# re-asked for: if Dolt is down, or the box is mid-reboot, or `bd` takes longer than its
# timeout, the alternative is losing the only record of the failure. `drain` files whatever
# the spool is still holding, and the ops timer runs it every pass.
#
# DEDUPE, BECAUSE A FLAPPING UNIT IS ONE INCIDENT
# -----------------------------------------------
# A timer that fails every five minutes would otherwise file 300 beads a day, and a queue
# with 300 copies of one problem in it is a queue nobody reads — the failure mode already
# measured at 71 unread on the Mayor. A second failure of a unit that already has an open
# incident bumps a recurrence count on the existing bead instead. Past SIN_AT recurrences
# it is a Sin: a class that keeps returning because no SOP has broken the cycle, which is
# escalated to the operator exactly once (law-alerts-must-be-actionable — a second copy of a page
# is what buries the first).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# WHICH PARTITION AN INTAKE LANDS IN, and therefore who works it. `spira,incident` is Ops's
# and is the default, because the original caller was a crashed unit and Ops is the healer.
# A caller whose finding is a DEFECT rather than an outage sets this to the builder's labels
# instead: a red test suite needs somebody who can change the code, and Ops has eight minutes
# and a runbook. Everything else about the intake — the write-ahead spool, the dedupe on the
# external ref, the recurrence bump, the Sin escalation — is the same either way, and is the
# reason a second implementation of "file a bead, but only once" does not exist.
#
# THE OPEN-BEAD LOOKUP USES THE SAME VALUE. Filing under one label set and deduping under
# another would find no open bead every time and file a fresh one on every pass, which is the
# exact failure the dedupe exists to prevent, arriving silently.
LABELS="${SPIRA_INCIDENT_LABELS:-spira,incident}"

SPOOL="${SPIRA_SPOOL:-$SPIRA_RUN/incident-spool}"
ILOG="${SPIRA_INCIDENT_LOG:-$SPIRA_RUN/incident.log}"
SIN_AT="${SPIRA_SIN_AT:-5}"
ASK="${SPIRA_ASK:-$SPIRA_NOTIFY}"
mkdir -p "$SPOOL" "$(dirname "$ILOG")"

ilog() { printf '%s incident: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$ILOG"; }

# --------------------------------------------------------------------------------------
# The open incident for a dedupe key, or empty. external-ref is the key rather than the
# title, because a title is prose someone will eventually reword and a ref is an identifier.
# --------------------------------------------------------------------------------------
open_incident() {        # open_incident <ref> -> bead id or empty
    # Filtered by the SERVER, not by reading every incident and comparing in python.
    # `bd list --external-ref` is an exact-match filter that already exists, and the
    # hand-rolled version would additionally have depended on external_ref surviving the
    # JSON round trip, which is a fact about a version rather than about the data.
    bdjson list --status open,in_progress --limit 0 --label "$LABELS" \
                --external-ref "$1" 2>/dev/null \
      | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d, list) else [d]):
    print(i["id"]); break
' 2>/dev/null
}

recurrences_of() {       # recurrences_of <id> -> integer
    bdq label list "$1" 2>/dev/null | grep -oE 'sp-recur-[0-9]+' | grep -oE '[0-9]+$' \
        | sort -n | tail -1 || true
}

# --------------------------------------------------------------------------------------
# file_one <ref> <title> <payload-file> — create or dedupe. Prints the bead id.
# Returns non-zero WITHOUT consuming the spool entry if the database could not be reached,
# so a transient failure costs a retry rather than the event.
# --------------------------------------------------------------------------------------
file_one() {
    local ref="$1" title="$2" pf="$3" id n

    # A bd that cannot even answer is a bd that must not be treated as "no open incident" —
    # that reading is how one outage becomes one bead per alert. Probe first, and bail.
    if ! bdq list --limit 1 >/dev/null 2>&1; then
        ilog "database unreachable — $ref stays spooled"
        return 1
    fi

    id="$(open_incident "$ref")"
    if [ -n "${id:-}" ]; then
        n="$(recurrences_of "$id")"; n="${n:-1}"; n=$((n+1))
        bdq label add "$id" "sp-recur-$n" >/dev/null 2>&1
        bdq note "$id" "Recurrence $n at $(date -u +%Y-%m-%dT%H:%M:%SZ).
$(head -c 2000 "$pf")" >/dev/null 2>&1
        ilog "$ref recurred ($n) — $id"
        # A Sin: it keeps coming back because nothing has broken the cycle. Escalated once,
        # on the crossing, never again — a second page buries the first.
        if [ "$n" -ge "$SIN_AT" ] && ! bdq label list "$id" 2>/dev/null | grep -q '\bsin\b'; then
            bdq label add "$id" sin >/dev/null 2>&1
            [ -x "$ASK" ] && "$ASK" add \
                "$ref has failed $n times and Ops has not broken the cycle — change the fix or mute the alert?" \
                --default "read $id, then either write an SOP that actually fixes it or retire the alert" \
                --why "every recurrence pages you and files nothing new; the alert is now noise" \
                >/dev/null 2>&1
            ilog "$ref is a SIN at $n recurrences — escalated once"
        fi
        printf '%s' "$id"
        return 0
    fi

    # THE TYPE AND THE ACTOR ARE THE CALLER'S, because not every intake is a failure. A
    # crashed unit is a bug and belongs at P1; the watchtower's ten-minute health sweep is
    # routine work, and filing it as a `bug` owned by whoever ran the timer put a chore in
    # the operator's queue looking like a defect he had been assigned. Defaults unchanged, so
    # the systemd path files exactly as it always did.
    id="$(BEADS_ACTOR="${SPIRA_INCIDENT_ACTOR:-${BEADS_ACTOR:-}}" \
          bdq create "$title" --type "${SPIRA_INCIDENT_TYPE:-bug}" \
            --priority "${SPIRA_INCIDENT_PRIORITY:-1}" \
            --labels "$LABELS" --external-ref "$ref" \
            --body-file "$pf" --silent 2>/dev/null | tr -d '[:space:]')"
    if [ -z "${id:-}" ]; then
        ilog "create FAILED for $ref — stays spooled"
        return 1
    fi
    ilog "filed $id for $ref"
    printf '%s' "$id"
}

# spool_write <ref> <title> <<payload on stdin>> -> path of the spool entry
spool_write() {
    local ref="$1" title="$2" safe stamp path
    # printf, not a herestring: `<<<` appends a newline, tr turns it into another
    # separator character, and the dedupe key quietly grows a trailing underscore.
    safe="$(printf '%s' "$ref" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    path="$SPOOL/$stamp-$safe-$$"
    { printf 'REF: %s\nTITLE: %s\n--\n' "$ref" "$title"; cat; } > "$path"
    printf '%s' "$path"
}

spool_field() { sed -n "s/^$1: //p" "$2" | head -1; }
spool_body()  { sed -n '/^--$/,$p' "$1" | tail -n +2; }

drain_one() {            # drain_one <spool-path>
    local sp="$1" ref title body id
    ref="$(spool_field REF "$sp")"; title="$(spool_field TITLE "$sp")"
    [ -n "$ref" ] || { ilog "spool entry with no REF: $sp — moved aside"; mv "$sp" "$sp.bad"; return 0; }
    body="$(mktemp)"; spool_body "$sp" > "$body"
    # An empty payload is a broken probe, not an incident with no detail — and `bd create`
    # refuses an empty --body-file outright, so filing would fail and the event would sit in
    # the spool forever looking like an outage. Say what could not be gathered, in the bead,
    # where whoever picks it up will see it (a failed probe renders `?`, never 0).
    if [ ! -s "$body" ]; then
        printf 'The intake gathered NO payload for %s.\nsystemctl/journalctl produced nothing — suspect the unit name or a journal this user cannot read.\n' \
               "$ref" > "$body"
    fi
    # SERIALISED, BECAUSE THE DEDUPE IS A CHECK FOLLOWED BY AN ACT. file_one asks whether an
    # open incident already carries this ref and creates one if not; two callers that ask
    # before either answers both get "no" and both file. That is not theoretical — the
    # watchtower's timer and a hand-run of the same unit produced sp-aapz and sp-uvfq at
    # 22:30:15 on 2026-09-07, same second, same ref, two beads, and each one costs a separate
    # Ops session working an identical snapshot.
    #
    # ONE LOCK FOR THE WHOLE INTAKE, not one per ref. The critical section is a database read
    # and a write measured in hundreds of milliseconds, incidents do not arrive in floods, and
    # a per-ref lock would leave two DIFFERENT refs racing on `bd create` anyway. The wait is
    # bounded and a timeout leaves the entry spooled — which is the write-ahead behaving
    # exactly as designed rather than a loss.
    mkdir -p "$(dirname "$SPOOL")" 2>/dev/null
    local lock="${SPIRA_INCIDENT_LOCK:-$SPIRA_RUN/incident.lock}"
    exec 8>"$lock" || { ilog "cannot open the intake lock at $lock — $ref stays spooled"; rm -f "$body"; return 1; }
    if ! flock -w "${SPIRA_INCIDENT_LOCK_WAIT:-30}" 8; then
        ilog "another intake held $lock for 30s — $ref stays spooled, drain will retry"
        exec 8>&-; rm -f "$body"; return 1
    fi
    if id="$(file_one "$ref" "$title" "$body")" && [ -n "$id" ]; then
        exec 8>&-
        rm -f "$sp" "$body"; printf '%s\n' "$id"; return 0
    fi
    exec 8>&-
    rm -f "$body"; return 1
}

case "${1:-}" in

systemd)
    unit="${2:?usage: incident.sh systemd <unit>}"
    ref="incident:$unit"
    # The evidence, gathered while it is still fresh. `systemctl show` first because the
    # exit status and the result reason are what distinguish "the command failed" from
    # "the unit timed out" from "the box killed it", and the journal alone does not always
    # say which. 40 lines of journal, because a bead body nobody can read is a payload
    # nobody reads.
    payload="$( {
        printf 'unit: %s\nhost: %s\nwhen: %s\n\n' \
               "$unit" "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '## systemctl\n'
        systemctl --user show "$unit" \
            -p Result -p ExecMainStatus -p ExecMainCode -p NRestarts \
            -p ActiveState -p SubState -p InvocationID -p ExecMainStartTimestamp \
            2>/dev/null || echo '(systemctl unavailable)'
        printf '\n## journal (last 40)\n'
        journalctl --user -u "$unit" -n 40 --no-pager 2>/dev/null || echo '(journal unavailable)'
    } )"
    sp="$(printf '%s' "$payload" | spool_write "$ref" "incident: $unit failed")"
    drain_one "$sp" || { ilog "spooled $ref at $sp"; exit 1; }
    ;;

file)
    title="${2:?usage: incident.sh file <title> [-|<file>]}"
    src="${3:--}"
    # THE REF IS THE DEDUPE KEY AND THE CALLER MAY STATE IT. Derived from the title only
    # because most callers have nothing better; a title is prose, it is truncated at 60
    # characters here, and two genuinely different findings that happen to share a wording
    # would then dedupe into one bead and the second would be lost as a recurrence of the
    # first. A caller that knows the identity of what it found — a suite plus the fingerprint
    # of its failure — passes that instead, and gets the dedupe the comment on open_incident
    # promises: keyed on an identifier, not on words somebody will eventually reword.
    ref="${SPIRA_INCIDENT_REF:-}"
    [ -n "$ref" ] || ref="incident:$(printf '%s' "$title" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60)"
    case "$src" in
        -) sp="$(spool_write "$ref" "$title")" ;;
        *) sp="$(spool_write "$ref" "$title" < "$src")" ;;
    esac
    drain_one "$sp" || { ilog "spooled $ref at $sp"; exit 1; }
    ;;

drain)
    n=0; stuck=0
    for sp in "$SPOOL"/*; do
        [ -f "$sp" ] || continue
        case "$sp" in *.bad) continue ;; esac
        if drain_one "$sp" >/dev/null; then n=$((n+1)); else stuck=$((stuck+1)); fi
    done
    # Report both numbers, always. A drain that prints only its successes is a probe that
    # renders a broken check as all-clear.
    printf 'drained %d, still spooled %d\n' "$n" "$stuck"
    [ "$stuck" -eq 0 ]
    ;;

list)
    bdq list --status open,in_progress --limit 0 --label "$LABELS" 2>/dev/null \
        | grep -vE '^💡|^warning|^  Fix|^  Or'
    n="$(find "$SPOOL" -maxdepth 1 -type f ! -name '*.bad' 2>/dev/null | wc -l)"
    [ "$n" -gt 0 ] && printf '\n%s event(s) still in the spool — run: incident.sh drain\n' "$n"
    b="$(find "$SPOOL" -maxdepth 1 -type f -name '*.bad' 2>/dev/null | wc -l)"
    [ "$b" -gt 0 ] && printf '%s malformed spool entr(ies) in %s\n' "$b" "$SPOOL"
    exit 0
    ;;

*) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
