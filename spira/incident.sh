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
# THE OPEN-BEAD LOOKUP MUST EXCLUDE FILER-SPECIFIC LABELS. The authoritative dedupe key is
# external_ref, compared client-side; the --label filter is only a cheap prefilter to keep
# the result set small. A label that varies between filers of the same event (e.g. repo:)
# must be excluded from that filter: including it silently partitions the candidate set so
# two callers declaring different repos never find each other's open incident (sp-jvlrs).
LABELS="${SPIRA_INCIDENT_LABELS:-spira,incident}"

# THE REPOSITORY THIS INCIDENT BELONGS TO. Without a repo: label a bead is worked in the
# home-repo fallback (brain), which has not contained the harness since sp-9tal. Callers
# declare it via SPIRA_INCIDENT_REPO; a caller that already embeds repo: in
# SPIRA_INCIDENT_LABELS is treated as having declared it. Where nothing is declared the
# bead is marked needs-repo-triage and escalated so the wrong repo is not
# indistinguishable from the right one (sp-io5e, law-a-split-repoints-nothing).
case "$LABELS" in
    *repo:*) INCIDENT_REPO_DECLARED=1 ;;
    *)
        _irepo="${SPIRA_INCIDENT_REPO:-}"
        if [ -n "$_irepo" ]; then
            LABELS="${LABELS},repo:${_irepo}"
            INCIDENT_REPO_DECLARED=1
        else
            INCIDENT_REPO_DECLARED=0
        fi
        ;;
esac

SPOOL="${SPIRA_SPOOL:-$SPIRA_RUN/incident-spool}"
ILOG="${SPIRA_INCIDENT_LOG:-$SPIRA_RUN/incident.log}"
SIN_AT="${SPIRA_SIN_AT:-5}"
# HOW FAR BACK THE DEDUP LOOKS FOR CLOSED BEADS. A failure whose bead was closed and then
# recurred is a recurrence, not a new event — reopening keeps the count and timeline on one
# record and prevents the close-then-refile loop that produced 38 duplicates in 2 days
# (sp-srgr6). The window is in whole days; the default of 7 days covers the week-scale
# flaps seen in timed-suite failures while leaving clearly old closures as "done".
DEDUP_LOOKBACK_DAYS="${SPIRA_INCIDENT_DEDUP_LOOKBACK:-7}"
# A CALLER MAY DECLARE ITSELF EXEMPT FROM THE SIN ESCALATION. The recurrence counter and the
# notes still increment — the signal stays where it belongs, on the bead and in the ops pane —
# but the counter cannot cross the SIN threshold and page the operator. The watchtower sweep
# is the canonical case: it fires on a ten-minute timer, so N counts intervals in which nobody
# closed a routine health report, not unremediated failures. Fifty minutes of quiet is five
# recurrences and a page, and closing the bead re-arms the cycle. $18/day of aeon cost to
# re-derive "the pipeline is fine" (measured sp-kufh).
SIN_EXEMPT="${SPIRA_SIN_EXEMPT:-0}"
ASK="${SPIRA_ASK:-$SPIRA_NOTIFY}"
mkdir -p "$SPOOL" "$(dirname "$ILOG")"

ilog() { printf '%s incident: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$ILOG"; }

# --------------------------------------------------------------------------------------
# Dedupe key for an incident ref. Prints "open <id> <n>", "closed <id> <n>", or nothing.
# <n> is the current highest sp-recur-N count, extracted from the bead's labels so the
# caller can skip a separate bdq label list call.
# --------------------------------------------------------------------------------------
# TWO PASSES, NOT ONE. Pass 1 queries open/in_progress; pass 2 (only when pass 1 finds
# nothing) queries recently-closed. They cannot be merged into one call because
# --closed-after filters on the closed_at field: open beads carry no closed_at and are
# silently excluded when --closed-after is present, making the combined query always return
# empty for the common recurrence case.
#
# CLIENT-SIDE FILTER ON external_ref (not --external-ref). bd list --external-ref is a
# server-side filter that only the dev build supports; bd-embedded silently ignores it,
# making every call look like "no open incident" and creating one fresh bead per filing
# instead of bumping recurrences. The JSON payload carries external_ref on every version,
# so filtering in Python works everywhere. The label filter keeps the candidate set small.
#
# DEDUPE LABELS EXCLUDE repo: — a repo: label identifies the filer, not the event.
# Two callers declaring different repos must still find each other's open incident;
# including repo: in the filter silently partitions dedup so they cannot (sp-jvlrs).
#
# RECURRENCE COUNT FROM LABELS. bd list --json includes the full labels array; extracting
# sp-recur-N here avoids a separate bdq label list call on every recurrence (one fewer
# bd process spawn per filing on the common recurrence path).
#
# DATE ARITHMETIC IS GNU date(1). The -v flag is a BSD/macOS fallback. An empty since
# skips the closed-bead search rather than scanning with an unbounded window.
# REOPENING IS THE CHOSEN STRATEGY, not linking: a closed bead within the lookback is
# the same incident returning. One bead that says "red 6 times over 2 days" lets Ops
# see the pattern; a chain of six single-occurrence beads does not (sp-srgr6).
# --------------------------------------------------------------------------------------
_dedup_incident() {      # _dedup_incident <ref> -> "open <id> <n>" | "closed <id> <n>" | nothing
    local ref="$1" _dedupe_labels _since _result
    _dedupe_labels="$(printf '%s' "$LABELS" | tr ',' '\n' | grep -v '^repo:' | paste -sd, -)"

    # PASS 1 — open / in_progress. No --closed-after: open beads have no closed_at and would
    # be silently excluded by that filter, making every recurrence look like a new filing.
    _result="$(bdjson list --status open,in_progress --limit 0 --label "$_dedupe_labels" \
        2>/dev/null \
      | python3 -c '
import sys, json, re
target = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
rows = d if isinstance(d, list) else [d]
for i in rows:
    if i.get("external_ref") == target and i.get("status") in ("open", "in_progress"):
        ns = [int(m.group(1)) for lbl in (i.get("labels") or [])
              for m in [re.match(r"^sp-recur-(\d+)$", lbl)] if m]
        print("open", i["id"], max(ns) if ns else 0); sys.exit(0)
' "$ref" 2>/dev/null)"
    if [ -n "$_result" ]; then
        printf '%s' "$_result"
        return
    fi

    # PASS 2 — recently-closed. Only reached when no open bead matched.
    _since="$(date -u -d "-${DEDUP_LOOKBACK_DAYS} days" '+%Y-%m-%d' 2>/dev/null \
           || date -u -v "-${DEDUP_LOOKBACK_DAYS}d" '+%Y-%m-%d' 2>/dev/null || true)"
    [ -z "$_since" ] && return

    bdjson list --status closed --closed-after "$_since" --limit 0 --label "$_dedupe_labels" \
        2>/dev/null \
      | python3 -c '
import sys, json, re
target = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
rows = d if isinstance(d, list) else [d]
for i in rows:
    if i.get("external_ref") == target and i.get("status") == "closed":
        ns = [int(m.group(1)) for lbl in (i.get("labels") or [])
              for m in [re.match(r"^sp-recur-(\d+)$", lbl)] if m]
        print("closed", i["id"], max(ns) if ns else 0); sys.exit(0)
' "$ref" 2>/dev/null
}

# --------------------------------------------------------------------------------------
# file_one <ref> <title> <payload-file> — create or dedupe. Prints the bead id.
# Returns non-zero WITHOUT consuming the spool entry if the database could not be reached,
# so a transient failure costs a retry rather than the event.
# --------------------------------------------------------------------------------------
file_one() {
    local ref="$1" title="$2" pf="$3" id n _was_closed _reopen_note _log_suffix _hit _rest _recur_n

    # DEDUP QUERY — two passes (open first, closed second if needed). If the database is
    # unreachable, _dedup_incident prints nothing; id stays empty and the probe below catches
    # it. The probe is skipped on the recurrence path because a result from _dedup_incident
    # proves the database is reachable. The recurrence count comes from the JSON labels,
    # so no separate bdq label list call is needed on the common recurrence path.
    _hit="$(_dedup_incident "$ref")"
    id="" _was_closed=0 _recur_n=0
    case "$_hit" in
        "open "*)   _rest="${_hit#open }";   id="${_rest%% *}"; _recur_n="${_rest##* }" ;;
        "closed "*) _rest="${_hit#closed }"; id="${_rest%% *}"; _recur_n="${_rest##* }"; _was_closed=1 ;;
    esac
    if [ -n "${id:-}" ]; then
        n=$((_recur_n + 1))
        if [ "$_was_closed" = 1 ]; then
            bead_reopen "$id" "Recurrence $n at $(date -u +%Y-%m-%dT%H:%M:%SZ) — same failure fingerprint, dedup within ${DEDUP_LOOKBACK_DAYS}-day window"
        fi
        bdq label add "$id" "sp-recur-$n" >/dev/null 2>&1
        _reopen_note="" _log_suffix=""
        if [ "$_was_closed" = 1 ]; then
            _reopen_note="
Reopened by dedup — same external ref seen again within ${DEDUP_LOOKBACK_DAYS} days of close."
            _log_suffix=" (reopened from closed)"
        fi
        bdq note "$id" "Recurrence $n at $(date -u +%Y-%m-%dT%H:%M:%SZ).${_reopen_note}
$(head -c 2000 "$pf")" >/dev/null 2>&1
        ilog "$ref recurred ($n) — $id${_log_suffix}"
        # A Sin: it keeps coming back because nothing has broken the cycle. Escalated once,
        # on the crossing, never again — a second page buries the first.
        # AN EXEMPT REF NEVER REACHES THIS BLOCK. The recurrence counter and the notes have
        # already been written above, so the signal is preserved; what is removed is its ability
        # to raise an ask against the operator. The log still says the threshold was crossed.
        if [ "$SIN_EXEMPT" = 1 ] && [ "$n" -ge "$SIN_AT" ]; then
            ilog "$ref crossed SIN_AT=$SIN_AT ($n recurrences) but is exempt — no escalation"
        elif [ "$n" -ge "$SIN_AT" ] && ! bdq label list "$id" 2>/dev/null | grep -q '\bsin\b'; then
            bdq label add "$id" sin >/dev/null 2>&1
            # THE ASK IS BUILT FROM THE BEAD, NEVER FROM $ref. $ref is a dedupe slug
            # ("incident:Spira-sweep-----is-the-pipeline-moving-"), so an ask titled with it
            # reaches the operator as a mangled identifier with no subject. He answers in a
            # tmux pane and cannot open a bead from it, so a default of "go read $id" asks
            # him to do the work the escalation existed to do
            # (law-escalations-carry-their-evidence, law-escalations-lead-with-the-bead).
            local age evf first secs
            # Elapsed beats a bare count: "5 times" says nothing about whether that is an
            # hour of noise or a fortnight of it. Guarded, because a date this cannot parse
            # must cost the phrase and not the ask.
            age=""
            first="$(bdq show "$id" --json 2>/dev/null \
                | grep -m1 -oE '"created"[^,]*' \
                | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:]+' || true)"
            if [ -n "$first" ]; then
                secs=$(( $(date -u +%s) - $(date -u -d "$first" +%s 2>/dev/null || echo 0) ))
                [ "$secs" -gt 0 ] && age=" over $(( secs / 3600 ))h $(( (secs % 3600) / 60 ))m"
            fi
            # The vital signs are at the HEAD of the payload and --evidence-file keeps the
            # TAIL, so hand it a head-trimmed copy rather than the whole body.
            evf="$(mktemp)"; head -c 2000 "$pf" > "$evf" 2>/dev/null || true
            [ -x "$ASK" ] && "$ASK" add \
                "$title — recurred $n times$age with no fix holding. Mute it, or keep paging?" \
                --default "mute this alert and leave $id open for Ops to work unpaged; keep paging only if you want a decision on every recurrence" \
                --why "$id is \"$title\". It has fired $n times$age and each recurrence pages you while filing nothing new. Its current vital signs are below — if they show nothing you must act on, muting is the right answer." \
                --evidence-file "$evf" \
                >/dev/null 2>&1
            rm -f "$evf"
            ilog "$ref is a SIN at $n recurrences — escalated once"
        fi
        printf '%s' "$id"
        return 0
    fi

    # No existing bead found. Distinguish "no open incident" from "database unreachable":
    # _dedup_incident returned empty in both cases, but the right response differs.
    # A bd that cannot answer must not be treated as "no open incident" — that reading is
    # how one outage becomes one bead per alert.
    if ! bdq list --limit 1 >/dev/null 2>&1; then
        ilog "database unreachable — $ref stays spooled"
        return 1
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
    # AN UNDECLARED REPO STAYS VISIBLE. Filed but labelled needs-repo-triage so an aeon
    # that would claim it in the home-repo fallback is stopped by its own confusion rather
    # than silently working in the wrong checkout. Escalated once so the operator can
    # correct the label before any aeon touches it (sp-io5e, law-a-split-repoints-nothing).
    if [ "${INCIDENT_REPO_DECLARED:-1}" = 0 ]; then
        bdq label add "$id" "needs-repo-triage" >/dev/null 2>&1
        bdq note "$id" "Repository not declared — SPIRA_INCIDENT_REPO was not set and LABELS carried no repo: label. An aeon claiming this bead works it in the home-repo fallback, which may be the wrong checkout. Add repo:<name> before claiming." >/dev/null 2>&1
        if [ "${SIN_EXEMPT:-0}" != 1 ]; then
            # DEDUPE: the ref is the stable key — not the title, which embeds the incident bead
            # id in some code paths and would produce a distinct ask per incident of the same
            # test file. Two concurrent filers reaching this point are already serialised by
            # drain_one's flock, so the check-and-create pair is atomic.
            _ask_subj="undeclared repo: $(printf '%s' "$ref" | cut -c1-72)"
            _ask_db="${COCKPIT_DB:-$SPIRA_DB}"
            _ask_open="$(bd -C "$_ask_db" list --status open \
                --label "${SPIRA_ASK_LABEL:-needs-operator}" --limit 0 --json 2>/dev/null \
              | json_only \
              | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
rows = d if isinstance(d, list) else [d]
want = sys.argv[1]
for r in rows:
    if want in (r.get("title") or ""):
        print(r["id"]); break
' "$_ask_subj" 2>/dev/null)"
            if [ -n "${_ask_open:-}" ]; then
                bd -C "$_ask_db" comments add "$_ask_open" \
                    "Seen again at $(date -u +%Y-%m-%dT%H:%M:%SZ): $id ($ref). Add a repo: label before an aeon claims it." \
                    >/dev/null 2>&1
                ilog "$ref undeclared-repo ask already open as $_ask_open — noted recurrence"
            elif [ -x "$ASK" ]; then
                # THE PREDICATE EXITS 0 WHEN THE INCIDENT BEAD GETS A repo: LABEL OR IS CLOSED.
                # $id is expanded NOW (the ask records the specific bead to watch); $COCKPIT_DB
                # expands at sweep time in moot-sweep.sh. An empty response from bd show signals
                # that the database is unreachable: the predicate exits non-zero and the ask stays
                # open rather than silently reading as cleared
                # (law-absence-needs-a-positive-control).
                local _moot_pred
                _moot_pred=$(cat <<MOOTEOF
_d=\$(bd -C "\$COCKPIT_DB" show $id --json 2>/dev/null); [ -n "\$_d" ] || { echo 'probe: no output from bd show — database may be unreachable'; exit 1; }; printf '%s\n' "\$_d" | python3 -c 'import json,sys; t=sys.stdin.read().strip(); d=(json.loads(t) if t else []); r=(d[0] if isinstance(d,list) and d else (d if isinstance(d,dict) and d else None)); valid=r is not None and "id" in r; s=r.get("status","?") if valid else "?"; ll=(r.get("labels") or []) if valid else []; rp=[x for x in ll if x.startswith("repo:")]; ok=valid and (s!="open" or bool(rp)); msg=("cleared: "+(rp[0] if rp else "bead "+s)) if ok else ("live: status="+s+", no repo: label") if valid else "probe failed: bd show returned error or no valid bead"; print(msg); sys.exit(0 if ok else 1)'
MOOTEOF
)
                "$ASK" add \
                    "$_ask_subj" \
                    --default "add repo:<name> to $id once you know which checkout owns the code this incident is about" \
                    --why "$id was filed without a repo: label. Without one an aeon works it in the home-repo fallback, which has not held the harness since sp-9tal." \
                    --moot-when "$_moot_pred" \
                    >/dev/null 2>&1
            fi
        fi
        ilog "$ref labelled needs-repo-triage — repo undeclared"
    fi
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
