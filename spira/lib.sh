# lib.sh — shared helpers for the Spira harness. Sourced, never executed.
#
# Spira runs personas as AEONS: summoned from a FAYTH (a persona definition), they claim
# one bead with a lease, work it, close or fail it, and exit. Nothing is long-lived except
# the systemd timers, because a session that dies takes its state with it — the scar behind
# cockpit-ensure.timer — while a lease is recovered by whoever runs `bd reclaim` next.

# EVERY PATH COMES FROM conf.sh AND NOTHING IS HARDCODED HERE. It also sets PATH, because
# `bd`, `claude` and `git` live on the LOGIN shell's PATH and everything here is invoked
# from systemd, where that PATH does not exist; bootstrapping in one place is the
# difference between working and failing silently to a log nobody reads.
#
# Sourced by ABSOLUTE path derived from this file, not from the caller's $0: lib.sh is
# sourced by scripts two directories away.
_spira_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# NAME IT WHEN IT IS ABSENT. Several suites copy lib.sh into a scratch directory to run it
# out of its own tree; one that forgets conf.sh would otherwise die with bash's own "No
# such file or directory" naming a path nobody wrote.
[ -f "$_spira_lib_dir/conf.sh" ] || {
    printf 'spira: conf.sh is missing beside lib.sh at %s — the harness cannot resolve any path without it\n' \
        "$_spira_lib_dir" >&2
    return 1 2>/dev/null || exit 1
}
. "$_spira_lib_dir/conf.sh"
unset _spira_lib_dir
export BEADS_NO_AUTO_IMPORT=1
mkdir -p "$SPIRA_RUN"

# Always name the database. This repo has no .beads, so an implicit bd reads the town or
# nothing — never the database meant (law-bd-c-selects-the-database).
# SPIRA_BD is the seam a suite uses for the ONE thing a real bd cannot be asked to do on
# demand — a probe that fails. It is not a place to put a model of bd: the suites run the
# real binary against a throwaway database (`testdb.sh`), because a partial model drifts
# silently and its gaps surface as failures in correct code. It exists as an env var rather
# than a PATH entry because lib.sh overwrites PATH outright, as it must to run under
# systemd, so a directory prepended by a test would be thrown away by the export above.
bdq() { timeout "${BD_TIMEOUT:-180}" "${SPIRA_BD:-bd}" -C "$SPIRA_DB" "$@"; }

# `gh` gets the same treatment and for the same reason. The pull-request landing path is the
# part of this harness that reaches OUTSIDE the box, so it is the part that most needs a
# fixture — and, like bd, a stub cannot be put in front of it by prepending to PATH, because
# the export above throws that away.
ghq() { timeout "${GH_TIMEOUT:-120}" "${SPIRA_GH:-gh}" "$@"; }

log() { printf '%s spira: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL $*" >&2; exit 1; }

# `bd --json` can print warnings on stdout before the payload, so never pipe it straight
# into a parser. This strips anything before the first JSON token.
json_only() { sed -n '/^[[{]/,$p'; }

bdjson() { bdq "$@" --json 2>/dev/null | json_only; }

# ask_already_open <subject> -> 0 when an OPEN operator ask already carries that subject.
#
# THE STRONGEST DEDUPE IS "IS IT ALREADY IN FRONT OF HIM", not a clock and not a stamp file.
# A clock re-asks a question already on his screen — land_escalate was rate limited to once
# an hour, which over one day put NINE identical "Spira is landing nothing" decisions in the
# operator's pane; he closed eight and the ninth arrived anyway. A stamp file is better but
# still answers a question about this box's memory rather than about his queue, and it is
# lost whenever $SPIRA_RUN is cleared.
#
# The database is the queue, so ask the database. An ask he has ALREADY CLOSED does not
# suppress a new one: a closed ask is an answered question, and the condition recurring after
# an answer is new information (law-alerts-must-be-actionable).
ask_already_open() {     # ask_already_open <subject>
    local subject="$1" hits
    [ -n "$subject" ] || return 1
    hits="$(bdjson list --status open --label "${SPIRA_ASK_LABEL:-needs-ryan}" --limit 0 2>/dev/null \
        | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
rows = d if isinstance(d, list) else [d]
want = sys.argv[1]
print(sum(1 for i in rows if want in (i.get("title") or "")))' "$subject" 2>/dev/null)"
    [ "${hits:-0}" -gt 0 ] 2>/dev/null
}

# How many rows a `bd --json` payload carries. Never `| wc -l` and never a grep: the payload
# is one line, and a warning printed before it would be counted as a row.
json_count() {           # stdin: JSON; stdout: an integer, 0 on anything unparseable
    python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
print(len(d if isinstance(d, list) else [d]))' 2>/dev/null || echo 0
}

# --------------------------------------------------------------------------------------
# Liveness. NEVER pgrep -f: the pattern is a substring of any command line that mentions
# it, including the caller's own, so a `pgrep -f 'aeon.sh builder'` inside a script named
# in that pattern reports itself alive. pgrep may nominate; /proc decides, on the actual
# argv of the recorded pid.
# --------------------------------------------------------------------------------------
aeon_alive() {           # aeon_alive <pidfile> -> 0 if the recorded pid is a live aeon
    local pf="$1" pid
    [ -f "$pf" ] || return 1
    pid="$(cat "$pf" 2>/dev/null)"
    [ -n "${pid:-}" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    # argv[0..] must actually be our runner, not a recycled pid. Capture, THEN match:
    # `tr ... | grep -q` under pipefail returns 141 when grep closes the pipe on the first
    # match, so the live case is exactly the one that could read as dead — and a liveness
    # test that false-negatives lets the reaper rob an aeon that is still working
    # (law-no-grep-q-under-pipefail).
    local cmd; cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    grep -qF 'aeon.sh' <<< "$cmd" || return 1
    return 0
}

aeon_count() {           # how many aeons of a fayth are genuinely running
    local fayth="$1" n=0 pf
    for pf in "$SPIRA_RUN"/aeon-"$fayth"-*.pid; do
        [ -e "$pf" ] || continue
        if aeon_alive "$pf"; then n=$((n+1)); else rm -f "$pf"; fi
    done
    printf '%d' "$n"
}

# --------------------------------------------------------------------------------------
# THE CHAMBER. A fayth carries FAYTH_LABELS / FAYTH_EXCLUDE_LABELS precisely so that its
# partition of the graph is ITS OWN, and every question the harness asks about a persona
# must be asked through that persona's own predicate. Asking one predicate on behalf of all
# of them is not a rounding error, it is an unreachable persona: sentinel.sh CHECK 7 gated
# every summon on a single `--label spira,plan` count, so Ops could only ever wake when the
# BUILDER had work — exactly backwards for an on-call role, and ops.fayth shipped complete
# and inert, with a correct predicate nothing ever evaluated.
#
# The list of personas is likewise DISCOVERED, never hardcoded. A default of `builder`
# meant a persona that landed was not a persona that ran, and nothing said so; enumerating
# the chamber makes installing a fayth the whole of installing a persona.
# --------------------------------------------------------------------------------------
fayth_names() {          # every persona defined in the chamber, one per line
    local f n
    for f in "$SPIRA_HOME"/chamber/*.fayth; do
        [ -e "$f" ] || continue
        n="${f##*/}"; printf '%s\n' "${n%.fayth}"
    done
}

spira_fayths() {         # the personas this harness runs, space separated
    # SPIRA_FAYTHS still overrides, because which personas a HOST runs is deployment
    # configuration; the default is now every fayth present rather than one name.
    if [ -n "${SPIRA_FAYTHS:-}" ]; then printf '%s' "$SPIRA_FAYTHS"; return 0; fi
    fayth_names | tr '\n' ' '
}

# A NARROWED ROSTER SAYS SO, EVERY PASS. SPIRA_FAYTHS is a legitimate host override — which
# personas a HOST runs is deployment configuration — but it is also the exact shape of the
# defect this section exists under: a fayth present in the chamber and absent from the roster
# is a persona that landed complete and will never run, and nothing about that looks wrong
# from the outside. It went unnoticed for a day. Name it instead.
roster_warnings() {      # roster_warnings <roster> -> a WARN line per fayth left out
    local roster=" $1 " f
    for f in $(fayth_names); do
        grep -qw -- "$f" <<< "$roster" && continue
        log "WARN $f.fayth is in the chamber but not in SPIRA_FAYTHS — that persona will never be summoned here"
    done
    return 0
}

fayth_get() {            # fayth_get <fayth> <VAR> [default] -> one field of a fayth
    local f="$1" var="$2" def="${3:-}" F="$SPIRA_HOME/chamber/$1.fayth"
    [ -f "$F" ] || { printf '%s' "$def"; return 1; }
    # A SUBSHELL, always. Sourcing a fayth sets FAYTH_* in the caller, so reading two
    # personas in one loop without one leaves the second wearing the first's predicate —
    # the same defect this section exists to close, arriving by a different route.
    # shellcheck disable=SC1090
    ( . "$F" 2>/dev/null; eval "printf '%s' \"\${$var:-\$def}\"" )
}

# ready_count <labels> <exclude-labels> -> how many beads that predicate can claim.
#
# `--limit 0` is not optional. `bd ready` pages at 100 and silently drops the rest, and an
# installation that imported a predecessor's beads sorts thousands of them above every native
# plan bead — the plan read as having no workable step at all until this was found.
ready_count() {
    bdq ready --limit 0 --exclude-type epic --label "$1" --exclude-label "$2" \
        --json 2>/dev/null | json_only | json_count
}

fayth_ready() {          # fayth_ready <fayth> -> claimable beads under ITS OWN predicate
    local f="$1" F="$SPIRA_HOME/chamber/$1.fayth"
    [ -f "$F" ] || { printf '0'; return 1; }
    # shellcheck disable=SC1090
    ( . "$F" 2>/dev/null
      ready_count "${FAYTH_LABELS:-}" "${FAYTH_EXCLUDE_LABELS:-}" )
}

# bead_reopen <id> <note> — hand a bead back to the graph so the NEXT aeon can claim it.
#
# REOPENING IS NOT ENOUGH. `bd reopen` keeps the assignee, and `bd ready --claim` skips any
# bead that has one even though `bd ready` lists it — so a bead reopened by the landing
# pass (a rebase conflict, a red gate) or by the aeon's own closed-without-commit check went
# back into the graph wearing a dead aeon's name and was never claimed again. Seven sat that
# way for four to eight hours at P0 while aeons took P1 work around them, and every one of
# the 23 reopens the landing log holds had the same defect. Clearing the assignee is what
# makes a reopen a reopen; it is done here so no site can forget it.
bead_reopen() {
    local id="$1" note="${2:-}"
    bdq reopen "$id" >/dev/null 2>&1
    bdq update "$id" --assignee "" >/dev/null 2>&1
    [ -n "$note" ] && bdq note "$id" "$note" >/dev/null 2>&1
    return 0
}

fayth_free() {           # fayth_free <fayth> -> free concurrency slots, never negative
    local f="$1" max have budget
    max="$(fayth_get "$f" FAYTH_MAX_CONCURRENT 1)"; max="${max:-1}"
    # THE GOVERNOR WITHHOLDS HERE, at the one chokepoint every summon path goes through.
    # FAYTH_MAX_CONCURRENT is a COUNT, which is a proxy for load rather than a measure of
    # it; governor.sh reads /proc and says what this machine can actually afford right now.
    # It may only LOWER the cap — a fayth's own concurrency stays the ceiling — and its
    # absence means no opinion, so a suite with no budget.env behaves exactly as before.
    # Only `enforce` clamps. In `measure` the budget is recorded and reported and changes
    # nothing, so the history accumulates under real conditions before it decides anything.
    # IT CLAMPS BY HEADROOM — how many MORE the governor says may start — not by a total.
    # The governor's number was always "how many fit in the idle CPU", which is additional
    # aeons since the running ones are already in the load; reading it as a cap and then
    # subtracting the running count again withheld more the more was running.
    local gmode free
    have="$(aeon_count "$f")"
    free=$(( max > have ? max - have : 0 ))
    budget="$(. "$SPIRA_RUN/budget.env" 2>/dev/null; printf '%s' "${SP_HEADROOM:-}")"
    gmode="$(. "$SPIRA_RUN/budget.env" 2>/dev/null; printf '%s' "${SP_GOVERNOR_MODE:-measure}")"
    if [ "$gmode" = enforce ] && [ -n "$budget" ] && [ "$budget" -lt "$free" ] 2>/dev/null; then
        free="$budget"
    fi
    printf '%d' "$free"
}

# fayth_partitions -> every partition this host watches, one "<labels>\t<exclude-labels>" a line.
#
# THE ROSTER ANSWERS "WHOSE WORK IS THERE" FOR EVERY CHECK, not only for summoning. Reaping
# a dead lease, reporting stalled work and verifying that a closed bead actually landed were
# each written against one hardcoded partition — the builder's — which is CHECK 7's defect
# arriving by three more doors. An aeon of any other persona that died left its bead
# in_progress with no reaper looking at it, its stall was never reported as stalled, and its
# bead could close without landing and pass the sweep that exists to catch exactly that. The
# fix is the same one fayth_ready made: ask each persona's OWN predicate.
#
# DEDUPLICATED, because two personas may legitimately share a partition and a sweep run twice
# over the same labels does the same work twice and counts it twice.
#
# EMPTY WHEN THE CHAMBER IS EMPTY, and callers must say so rather than fall back to a
# partition name: a fallback would restore the hardcoded constant by another route, and a
# sweep that silently watches nothing is indistinguishable from one that found nothing
# (law-absence-needs-a-positive-control).
fayth_partitions() {
    local f l seen=""
    for f in $(spira_fayths); do
        l="$(fayth_get "$f" FAYTH_LABELS)"
        [ -n "$l" ] || continue
        case "$seen" in *"|$l|"*) continue ;; esac
        seen="$seen|$l|"
        printf '%s\t%s\n' "$l" "$(fayth_get "$f" FAYTH_EXCLUDE_LABELS)"
    done
    return 0
}

fayths_for_labels() {    # fayths_for_labels <labels> -> personas whose partition IS <labels>
    # For the question "is anything working THESE beads". Counting every live aeon would
    # let a running Ops aeon mask a genuinely starved plan, which is the same
    # one-predicate-for-every-persona defect seen from the other side.
    local want="$1" f
    for f in $(fayth_names); do
        [ "$(fayth_get "$f" FAYTH_LABELS)" = "$want" ] && printf '%s\n' "$f"
    done
    return 0
}

# summon_fayth <fayth> -> 0 if an aeon was started, 1 otherwise.
#
# THE STATUS IS THE ANSWER, not a word on stdout. A caller that captured the output to look
# for "summoned" would swallow the log lines below with it, and the sentinel's stdout IS the
# sentinel log — so the one pass that did something would be the one that explained itself
# least.
summon_fayth() {
    local f="$1" r free
    # THE ACCOUNT BEFORE THE QUEUE. A summon during a capacity outage cannot succeed, and it
    # does not fail for free: the aeon it starts claims a bead, is refused by the API, and
    # the bead pays an attempt to discover a fact the harness already knew. Asked first, and
    # before fayth_ready, because the cheapest question is the one that skips the others.
    if capacity_paused; then
        log "CHECK7 $f: the account is out of capacity for another ${SPIRA_CAPACITY_LEFT}s — not summoning"
        return 1
    fi
    r="$(fayth_ready "$f")" || { log "CHECK7 $f: no fayth in the chamber — skipped"; return 1; }
    if [ "${r:-0}" -eq 0 ]; then log "CHECK7 $f: nothing ready in its partition"; return 1; fi
    free="$(fayth_free "$f")"
    if [ "${free:-0}" -eq 0 ]; then
        # Name the ACTUAL reason. "at concurrency cap" was logged even when the governor
        # was the one withholding, which is a check reporting someone else's decision as
        # its own — the reader then tunes the wrong knob.
        local b gm; b="$(. "$SPIRA_RUN/budget.env" 2>/dev/null; printf '%s' "${SP_HEADROOM:-}")"
        gm="$(. "$SPIRA_RUN/budget.env" 2>/dev/null; printf '%s' "${SP_GOVERNOR_MODE:-measure}")"
        if [ "$gm" = enforce ] && [ -n "$b" ] && [ "$b" -eq 0 ] 2>/dev/null; then
            local why; why="$(. "$SPIRA_RUN/budget.env" 2>/dev/null; printf '%s' "${SP_BUDGET_REASON:-no headroom}")"
            log "CHECK7 $f: $r ready, withheld by the governor — $why"
        else
            log "CHECK7 $f: $r ready, at concurrency cap"
        fi
        return 1
    fi

    # A TRANSIENT UNIT, not a background child. This service is Type=oneshot with the
    # default KillMode=control-group, so systemd tears down the whole cgroup the moment the
    # pass finishes — which killed the first aeon it summoned within the same second, after
    # 1.6s of CPU, leaving an empty log and a sentinel that cheerfully reported "summoned"
    # every two minutes. systemd-run puts the aeon in its own cgroup, quota and journal.
    log "CHECK7 $f: $r ready, $free free — summoning"
    "${SPIRA_SUMMON:-systemd-run}" --user --collect --quiet \
        --unit="spira-aeon-$f-$(date +%s)" \
        --property=CPUQuota=70% --property=Nice=10 \
        --property=TimeoutStartSec="$(fayth_get "$f" FAYTH_TIMEOUT_SECONDS 3600)" \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
        "$SPIRA_HOME/aeon.sh" "$f" 2>/dev/null
}

# ======================================================================================
# API CAPACITY — the account's own five-hour window, and the third unrelated thing in this
# harness called "capacity".
#
# The other two: FAYTH_MAX_CONCURRENT is how many aeons may run at once, and the governor's
# budget is CPU, memory and disk. Neither has anything to do with this one, which is whether
# the API will answer at all. The name collision is why the condition went unhandled for so
# long — `grep capacity` returned confident, irrelevant hits.
#
# WHAT GOES WRONG WITHOUT THIS. aeon.sh takes the session's exit code and any non-zero
# becomes a failed attempt, so a session the API refused to serve is recorded as work that
# could not be done. That is not merely a miscount: attempts poison at a threshold, so an
# outage does not just stop the queue, it DESTROYS it — every bead claimed while the window
# is spent burns an attempt for a condition that has nothing to do with its work, and beads
# leave circulation permanently for a fault that heals itself in minutes. A transient
# condition must not be able to write permanent state.
#
# THE DISCRIMINATING FIELD IS `status`, AND IT IS NOT `overageStatus`. Every session on this
# account emits `"overageStatus":"rejected","overageDisabledReason":"org_level_disabled"` on
# EVERY rate_limit_event, including at 7% utilization, because overage is disabled at the
# organisation level as a standing configuration. Keying on it — which the shape of the
# payload invites — would pause the harness permanently and for ever, at full health. Of 460
# rate_limit_events captured across 40 session logs here, 443 read `status: allowed`, 16
# `allowed_warning`, and exactly ONE `status: rejected` — at `utilization: 1`, ending in a
# synthetic assistant turn reading "You've hit your session limit · resets 12pm (UTC)".
# That one event is the positive
# control this detector is tested against (law-absence-needs-a-positive-control).
#
# AND `429`/`503` ARE NOT IN THESE LOGS AT ALL. A bare grep for them matches four and five
# digit token counts — `"cache_read_input_tokens":142902` contains `429` — which is how one
# log was read as holding "24x 429 and 12x 503" when it holds neither. The stream-json trace
# never carries a bare HTTP status; the refusal arrives as the rate_limit_event above and as
# `is_error` on the terminal `result` record. Match the structure, never the substring.
# ======================================================================================
SPIRA_CAPACITY_PAUSE="${SPIRA_CAPACITY_PAUSE:-$SPIRA_RUN/capacity-pause}"
# Used only when the account refused us without saying when it would stop. resetsAt has been
# present on every rejection observed, so this is the branch that should never run — which is
# exactly why it must not be a long sleep taken on faith. 15 minutes re-asks cheaply.
SPIRA_CAPACITY_BACKOFF="${SPIRA_CAPACITY_BACKOFF:-900}"

# capacity_reset_at <session-log> -> prints the epoch the window reopens; rc 0 if the
# session was ended by the account running out of capacity, rc 1 for anything else.
#
# rc 1 covers "the log does not exist", "the log is unparseable" and "the session failed for
# its own reasons" ALIKE, and that is deliberate: the false direction of this check must be
# the one that preserves today's behaviour. Reading a genuine failure as an outage would stop
# a bead ever being poisoned, which is the one property CHECK 4 exists to hold.
capacity_reset_at() {
    local logf="${1:-}"
    [ -n "$logf" ] && [ -s "$logf" ] || return 1
    # THE LAST ATTEMPT ONLY. The log carries every attempt this bead has had, and a refusal
    # is sticky evidence: attempt 1 dying to a spent window would otherwise make attempt 3
    # look refused too, so a bead that genuinely failed would be handed its attempt back and
    # the harness would pause summoning against a `resetsAt` that has already passed. No cap
    # — this runs once at teardown, and the two records that decide the verdict sit at
    # opposite ends of a session.
    # THE PROGRAM ARRIVES ON FD 3, NOT ON STDIN, because stdin is the trace. `python3 -
    # <<PY` looks right and silently reads the HEREDOC as the data too: the redirect wins,
    # the pipe is discarded unread, and the detector then says "not a refusal" about every
    # log ever handed to it — with a BrokenPipeError from the writer as the only tell.
    attempt_trace "$logf" | python3 /dev/fd/3 3<<'PY'
import json, sys

# The session limit shows up twice in one trace and either alone is enough. The
# rate_limit_event is preferred because it carries resetsAt as an epoch; the terminal
# `result` record is the fallback for a refusal that arrives without one.
LIMIT_TEXT = ("hit your session limit", "usage limit", "rate limit")
reset, hit = 0, False
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue          # a partial last line is normal on a killed session
    if not isinstance(d, dict):
        continue
    if d.get("type") == "rate_limit_event":
        info = d.get("rate_limit_info") or {}
        # `status`, never `overageStatus` — see the header. A value we have never seen
        # is not treated as a refusal: an unknown string must not be able to halt the
        # harness, and a real refusal also lands on the `result` record below.
        if info.get("status") == "rejected":
            hit = True
            try:
                reset = max(reset, int(info.get("resetsAt") or 0))
            except (TypeError, ValueError):
                pass
    elif d.get("type") == "result" and d.get("is_error"):
        # `subtype` is "success" on this record even though is_error is true, so subtype
        # cannot be the test. The text is what distinguishes an account refusal from a
        # session that failed at its own work.
        text = str(d.get("result") or "").lower()
        if any(t in text for t in LIMIT_TEXT):
            hit = True
if not hit:
    raise SystemExit(1)
print(reset)
PY
}

# capacity_pause_set <epoch> <reason> — record that the account is out until <epoch>.
#
# ANNOUNCED HERE AND ONLY HERE. The bead asked for it to be said "once in the ledger rather
# than every pass"; the write is the once. An existing pause is only ever EXTENDED, never
# shortened, so a second aeon dying into the same outage cannot pull the reopening forward
# to its own — older — reading of resetsAt.
capacity_pause_set() {
    local at="${1:-0}" why="${2:-unknown}" now cur
    now="$(date +%s)"
    [ "${at:-0}" -gt "$now" ] 2>/dev/null || at=$(( now + SPIRA_CAPACITY_BACKOFF ))
    cur="$(capacity_pause_until)"
    [ "${cur:-0}" -ge "$at" ] 2>/dev/null && return 0
    mkdir -p "$(dirname "$SPIRA_CAPACITY_PAUSE")" 2>/dev/null
    printf '%s %s %s\n' "$at" "$(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$why" \
        > "$SPIRA_CAPACITY_PAUSE"
    log "CAPACITY: the account is out until $(date -u -d "@$at" +%H:%M 2>/dev/null)Z ($(( at - now ))s) — summoning is paused, $why returned unchanged"
    printf '%s CAPACITY paused until %s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$why" >> "$SPIRA_RUN/aeon-ledger.log"
}

capacity_pause_until() {  # -> the epoch a pause runs to, or 0 if none is recorded
    local at
    [ -f "$SPIRA_CAPACITY_PAUSE" ] || { printf '0'; return; }
    at="$(awk 'NR==1{print $1}' "$SPIRA_CAPACITY_PAUSE" 2>/dev/null)"
    case "${at:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$at" ;; esac
}

# capacity_paused -> rc 0 while the window is still shut, and sets $SPIRA_CAPACITY_LEFT to
# the seconds remaining.
#
# THE ANSWER IS A GLOBAL, NOT STDOUT, because this function also announces the reopening —
# and a caller reading it as `left="$(capacity_paused)"` would capture that announcement into
# a variable it then discards, so the one line saying the harness is moving again would be
# swallowed by the check that resumed it (law-absence-needs-a-positive-control, in the
# direction nobody looks: the all-clear that never printed).
#
# A pause that has run out is REMOVED here rather than merely ignored, so the file itself is
# the answer to "is the harness paused" for anything reading it without this library.
SPIRA_CAPACITY_LEFT=0
capacity_paused() {
    local at now
    at="$(capacity_pause_until)"; now="$(date +%s)"
    if [ "$at" -gt "$now" ] 2>/dev/null; then
        SPIRA_CAPACITY_LEFT=$(( at - now )); return 0
    fi
    SPIRA_CAPACITY_LEFT=0
    if [ -f "$SPIRA_CAPACITY_PAUSE" ]; then
        rm -f "$SPIRA_CAPACITY_PAUSE"
        log "CAPACITY: the window has reopened — summoning resumes"
    fi
    return 1
}

capacity_pause_why() {   # -> what was being worked when the account ran out
    [ -f "$SPIRA_CAPACITY_PAUSE" ] || return 1
    awk 'NR==1{$1="";$2="";sub(/^  */,"");print}' "$SPIRA_CAPACITY_PAUSE" 2>/dev/null
}

# --------------------------------------------------------------------------------------
# THE WITHDRAWAL LEDGER — which refusal has already been paid back.
#
# Giving an attempt back is driven by evidence that stays on disk: a session log ending in
# an account refusal. Evidence that stays is evidence that can be read twice, so a cleanup
# with no memory of itself withdraws a second attempt from the same log on its second run,
# a third on its third, and attempt counts walk to zero — after which nothing can ever
# poison, however genuinely it keeps failing. Nothing calls that cleanup automatically,
# which is not a defence: a hand-run command invites being run again.
#
# THE MARK IS KEYED ON THE LOG'S CONTENT, not on the bead and not on a date. The horizon is
# one attempt deep by construction — aeon.sh truncates `$SPIRA_RUN/<id>.log` on every
# attempt — so "has this refusal already been paid back" is exactly "is this the same log I
# paid back last time". A NEW refusal rewrites the file, the fingerprint moves, and the next
# withdrawal is made. A bead keyed mark would refuse the second outage; a dated one would
# turn the erosion back on after however long it waited.
#
# Losing the ledger costs one duplicate withdrawal per refused log and nothing worse, which
# is why it lives under SPIRA_RUN beside the logs it describes rather than in the database.
# It needs no config key for the same reason the traces do not: the harness put it there.
# --------------------------------------------------------------------------------------
SPIRA_CAPACITY_WITHDRAWN="${SPIRA_CAPACITY_WITHDRAWN:-$SPIRA_RUN/capacity-withdrawn}"

# capacity_log_fingerprint <log> -> a string that moves when the log's content does; rc 1
# if there is no readable content to fingerprint.
#
# Content and not `stat`: size and mtime make an unchanged log look new whenever anything
# copies, restores or re-syncs the runtime directory, and every one of those false readings
# spends an attempt that was never charged.
capacity_log_fingerprint() {
    local f="${1:-}" h
    [ -n "$f" ] && [ -s "$f" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        h="$(sha256sum < "$f" 2>/dev/null | awk '{print $1}')"
    else
        # cksum is POSIX and always there. It is weaker, and it does not need to be strong:
        # this distinguishes one session trace from the next, not from an adversary's.
        h="$(cksum < "$f" 2>/dev/null | tr -s ' ' -)"
    fi
    [ -n "$h" ] || return 1
    printf '%s' "$h"
}

capacity_withdrawn_fp() {   # capacity_withdrawn_fp <id> -> the fingerprint already paid back, or nothing
    local id="${1:-}"
    [ -n "$id" ] || return 1
    awk 'NR==1{print $1}' "$SPIRA_CAPACITY_WITHDRAWN/$id" 2>/dev/null
}

# capacity_withdrawn_mark <id> <fingerprint> <attempt> — record that this exact log has been
# paid back. Written whole rather than appended: one line per bead is the entire question,
# and a file that only ever grows is one more thing to prune.
capacity_withdrawn_mark() {
    local id="${1:-}" fp="${2:-}" att="${3:-0}"
    [ -n "$id" ] && [ -n "$fp" ] || return 1
    mkdir -p "$SPIRA_CAPACITY_WITHDRAWN" 2>/dev/null || return 1
    printf '%s %s %s\n' "$fp" "$att" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$SPIRA_CAPACITY_WITHDRAWN/$id"
}

# --------------------------------------------------------------------------------------
# Attempt counting. Kept as labels rather than metadata because a label is visible in
# every listing and filterable by the same --exclude-label surface claiming uses, so the
# poison threshold is enforced at SELECTION time rather than after a wasted claim.
# --------------------------------------------------------------------------------------
attempts_of() {          # attempts_of <id> -> integer
    bdq label list "$1" 2>/dev/null | grep -oE 'sp-attempt-[0-9]+' | grep -oE '[0-9]+$' \
        | sort -n | tail -1 || true
}

bump_attempt() {         # bump_attempt <id> -> new count
    local id="$1" n; n="$(attempts_of "$id")"; n="${n:-0}"; n=$((n+1))
    bdq label add "$id" "sp-attempt-$n" >/dev/null 2>&1
    printf '%d' "$n"
}

# --------------------------------------------------------------------------------------
# Landing verification. CLOSED is not landed: a bead is only done when its work is in the
# commit graph. Every aeon is required to name its bead id in the commit subject, which is
# what makes this checkable by a program instead of by reading a diff.
# --------------------------------------------------------------------------------------
# --------------------------------------------------------------------------------------
# THE CONTEXT AN ESCALATION MUST CARRY. (the operator, verbatim: "i don't know what this bead
# is, i need a description of the actual goal/problem/bead when you give me a decision to
# make about it." — said after a first fix that added a log tail but not the bead itself.)
#
# A log tail answers "what went wrong". It does not answer "what was this trying to do",
# which is the question you must answer FIRST to decide anything. So: title, status, age,
# labels, and the whole description — the problem statement in the bead's own words.
# --------------------------------------------------------------------------------------
# --------------------------------------------------------------------------------------
# AN AEON HAS A NAME. Every instance used to be `aeon-builder`, so two of them were
# indistinguishable in the pane, in `bd` history and in the commit graph — you could see
# that AN aeon closed a bead and never which one, which made "what is it doing" an
# unanswerable question (the operator, verbatim: "i really want to know what the aeon is
# doing (it should have an identity)").
#
# Named for the aeons of Spira, which is the whole reason the system carries that name.
# The prefix stays `aeon-` so every existing count that greps for it still works.
# --------------------------------------------------------------------------------------
SPIRA_AEON_NAMES="valefor ifrit ixion shiva bahamut yojimbo anima cindy sandy mindy"

aeon_name_take() {       # aeon_name_take <fayth> -> a name not currently in use
    local f="$1" n live
    live=" $(for pf in "$SPIRA_RUN"/aeon-*.name; do [ -e "$pf" ] || continue
                 p="${pf%.name}"; [ -f "$p.pid" ] && aeon_alive "$p.pid" && cat "$pf"; done | tr '\n' ' ') "
    # DO NOT REUSE THE NAME THE LAST AEON HAD. Picking the first free name meant two
    # consecutive sessions were both "valefor", so the pane looked like one agent switching
    # beads when it was one dying and another starting — which hid the fact that a bead had
    # been dropped with work in flight. A cursor makes consecutive aeons distinguishable.
    local last cursor=0
    last="$(cat "$SPIRA_RUN/.aeon-name-cursor" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    local total=0; for n in $SPIRA_AEON_NAMES; do total=$((total+1)); done
    local tries=0
    while [ "$tries" -lt "$total" ]; do
        cursor=$(( (last + 1 + tries) % total ))
        local idx=0
        for n in $SPIRA_AEON_NAMES; do
            if [ "$idx" -eq "$cursor" ]; then
                case "$live" in *" $n "*) ;; *)
                    printf '%s' "$cursor" > "$SPIRA_RUN/.aeon-name-cursor"
                    printf '%s' "$n"; return 0 ;;
                esac
            fi
            idx=$((idx+1))
        done
        tries=$((tries+1))
    done
    # More concurrent aeons than names is not an error, just unusual; fall back to a
    # numbered one rather than reusing a name and making two of them indistinguishable.
    printf 'aeon%s' "$(date +%s | tail -c 4)"
}

aeon_named() {           # aeon_named <pidfile> -> the name held by that aeon, if any
    local pf="$1"; [ -f "${pf%.pid}.name" ] && cat "${pf%.pid}.name" 2>/dev/null || printf '?'
}

# --------------------------------------------------------------------------------------
# ONE SESSION LOG PER BEAD, APPENDED TO, WITH ONE SEGMENT PER ATTEMPT.
#
# aeon.sh used to open the log with `>`, so an attempt erased its predecessor and only the
# last one of a bead had a trace at all. On a day when a capacity outage killed 121 sessions
# in three to seven seconds each, three traces survived; every other one had been overwritten
# by the next attempt on the same bead, and with them the only record of why the session
# died. The operator, verbatim: "I don't want to miss any insights from here on."
#
# Appending rather than one file per attempt is deliberate. The heartbeat decides whether a
# session is alive by watching `stat -c %s` on this path grow, and that check reads a fixed
# name — a new filename per attempt leaves it watching a file nobody is writing, which is
# indistinguishable from a wedged session and costs the bead its lease. Appending keeps the
# growth signal exactly as it was.
#
# What appending DOES change is that the file now holds events from sessions that are over,
# so every reader that asks "what is happening" must read the LAST segment and not the whole
# file: a `result` record from attempt 1 taken for attempt 3's would pause the harness for a
# capacity outage that ended hours ago, or report a finished session's last tool call as a
# live one's. attempt_trace is that boundary, and it is the only place the mark is parsed.
#
# The mark is a constant rather than a configuration key because it is a FORMAT, not a path:
# an operator who changed it would make every log already on disk unreadable by the code that
# writes the next line of it. It is defined once here and written by aeon.sh through
# spira_trace_mark, so the writer and the readers cannot drift.
#
# It is not JSON and does not start with `{`, which is what makes it inert: every consumer of
# this trace already skips any line that is not a JSON object, so the mark passes through
# trace_last, trace_tail, capacity_reset_at and tokens.sh without special handling.
# --------------------------------------------------------------------------------------
SPIRA_TRACE_MARK='=== spira attempt'

# spira_trace_mark <logfile> <aeon> -> the separator line that opens a new attempt.
#
# THE ORDINAL COUNTS MARKS ALREADY IN THE FILE, not the bead's `sp-attempt-N` labels. An
# attempt is only CHARGED when a session fails, and a session refused by the account is
# deliberately charged nothing — so the label count answers "how many failures were blamed on
# this work", which is a different question from "which session am I reading" and was off by
# every successful and every refused run. Here the file is its own authority.
#
# `kept=` IS THE METER, and it is here because nothing prunes these logs. Appending trades
# bounded disk for a complete history, and the quantity given away is exactly the bytes
# already retained for this bead — so it is recorded at the head of every attempt rather than
# left to be discovered when a volume fills (law-take-the-simple-fix-with-a-meter). A bead
# whose mark lines show `kept=` climbing into the hundreds of megabytes is the signal that
# this simple choice has stopped being adequate.
spira_trace_mark() {
    local f="${1:-}" who="${2:-?}" kept n
    kept="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    # BOTH READS ARE ALLOWED TO FAIL, and both say so. The first attempt on a bead finds no
    # file at all and a fresh one finds no mark, so `stat` exits 1 and `grep -c` exits 1
    # having printed `0` — ordinary answers, not errors. Under a caller running `set -e` a
    # bare assignment from either would abort the shell at the exact line that opens the
    # log, which is the one place a failure costs the whole attempt.
    n="$(grep -c "^$SPIRA_TRACE_MARK " "$f" 2>/dev/null || true)"
    printf '%s %s aeon=%s at=%s kept=%s\n' \
        "$SPIRA_TRACE_MARK" "$(( ${n:-0} + 1 ))" "$who" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${kept:-0}"
}

# attempt_trace <logfile> [cap] -> the LAST attempt's segment, at most <cap> trailing bytes
# (0 or absent means all of it). A log with no mark in it is emitted whole, because that is
# what every log written before this change looks like and one attempt is all it ever held.
attempt_trace() {
    local f="${1:-}" cap="${2:-0}"
    [ -r "$f" ] || return 0
    python3 - "$f" "$cap" "$SPIRA_TRACE_MARK" <<'PY'
import os, sys

path, cap, mark = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode()
try:
    fh = open(path, "rb")
except OSError:
    raise SystemExit(0)
with fh:
    size = os.fstat(fh.fileno()).st_size
    # BACKWARDS IN CHUNKS, never a read of the whole file. This runs on every heartbeat of
    # every live aeon, and the file it reads is the one thing here that grows without bound;
    # a forward scan would make the cost of watching a session rise with how long the bead
    # has been worked, which is the wrong way round.
    CH, keep = 1 << 16, len(mark) + 1
    start, pos, carry = 0, size, b""
    while pos > 0:
        step = min(CH, pos)
        pos -= step
        fh.seek(pos)
        buf = fh.read(step) + carry
        i = buf.rfind(b"\n" + mark)
        if i >= 0:
            start = pos + i + 1
            break
        if pos == 0 and buf.startswith(mark):
            start = 0
            break
        # A mark straddling a chunk boundary belongs to neither half alone.
        carry = buf[:keep]
    fh.seek(max(start, size - cap) if cap > 0 else start)
    sys.stdout.buffer.write(fh.read())
PY
}

# --------------------------------------------------------------------------------------
# trace_last <logfile> -> the last thing the session actually did, one line.
# --------------------------------------------------------------------------------------
trace_last() {
    local f="$1"
    [ -r "$f" ] || { printf ''; return 0; }
    # THE LAST ATTEMPT'S SEGMENT, not the file's tail. The log is appended to across
    # attempts, so a fresh attempt that has not yet written an event would otherwise report
    # the PREVIOUS session's last tool call as what this one is doing — and the heartbeat
    # grants a stalled aeon a reprieve on exactly that answer.
    attempt_trace "$f" 100000 2>/dev/null | python3 -c '
import sys, json
last = ""
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"): continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("type") != "assistant": continue
    for c in (e.get("message", {}) or {}).get("content", []) or []:
        if c.get("type") == "tool_use":
            inp = c.get("input", {}) or {}
            last = "%s %s" % (c.get("name", "?"), str(inp.get("command") or inp.get("file_path") or "")[:200])
        elif c.get("type") == "text" and c.get("text", "").strip():
            last = c["text"].strip().replace("\n", " ")[:200]
# SAFE FOR A KEY=value FILE, AT THE SOURCE. This is arbitrary text from an agent — a shell
# command, a code fragment — and the cockpit snapshot is sourced by the pane. A newline in
# it injects extra lines and an "=" makes a bogus key; the pane rendered rustfmt help text
# where the ops summary belongs before this was clamped. An allowlist, not a blocklist:
# guessing which characters are dangerous is how the blocklist misses one.
import re
sys.stdout.write(re.sub(r"\s+", " ", re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", last)).strip()[:96])
' 2>/dev/null
}

# --------------------------------------------------------------------------------------
# still_waiting <logfile> -> 0 if the silence is a legitimate wait, 1 if it is a stall.
#
# (the operator, verbatim: "before you kill an aeon for being idle ... do a quick inference
# check to see whether the last log message indicates that it's WAITING for something that
# might take longer than 10 minutes and extend the deadline accordingly".)
#
# Two tiers, cheapest first — the same rule the sentinel follows. A session blocked on
# `gh run watch` emits no trace for the whole of a CI run and is the likeliest long silence
# here; recognising that by pattern costs nothing. Inference is reached only when the last
# action is not a known wait, which is precisely the case where there is no rule to apply.
# --------------------------------------------------------------------------------------
still_waiting() {
    local f="$1" last verdict
    last="$(trace_last "$f")"
    [ -n "$last" ] || return 1          # nothing to judge: treat as stalled

    # TIER 1 — known long waits, by pattern. No model, no cost, no latency.
    case "$last" in
        *"gh run watch"*|*"gh pr checks"*|*"gh run view"*|*"--watch"*) return 0 ;;
        *"cargo build"*|*"cargo test"*|*"npm test"*|*"npm run build"*|*"make "*) return 0 ;;
        *"sleep "*|*"until "*|*"while "*|*"docker build"*|*"podman build"*) return 0 ;;
        *"git clone"*|*"git fetch"*|*"bd import"*|*"dolt "*) return 0 ;;
    esac

    # TIER 2 — judgement, only because tier 1 had no answer. Small model, tight question,
    # short ceiling: this runs while a lease is on the line and must not itself hang.
    command -v claude >/dev/null 2>&1 || return 1
    verdict="$(printf 'A background agent has produced no output for several minutes. Its last action was:\n\n%s\n\nIs it plausibly WAITING on something that legitimately takes more than ten minutes (a CI run, a build, a large clone, a long test suite, a rate limit), or is it STUCK? Answer with exactly one word: WAITING or STUCK.' "$last" \
        | timeout 90 claude -p --model claude-haiku-4-5-20251001 2>/dev/null | tr -d "[:space:]" | tr "[:lower:]" "[:upper:]")"
    case "$verdict" in *WAITING*) return 0 ;; esac
    return 1
}


# --------------------------------------------------------------------------------------
# trace_tail <logfile> [n] -> the last n human-readable moments of a session.
#
# The session log is stream-json now, which is the right format for a machine watching for
# progress and the wrong one to put in front of the operator: an escalation carrying 25 lines of
# raw JSON satisfies law-escalations-carry-their-evidence in letter and defeats it in
# substance. This renders the trace as what the agent SAID and DID.
# --------------------------------------------------------------------------------------
trace_tail() {
    local f="$1" n="${2:-25}"
    [ -r "$f" ] || { printf '(no session log)'; return 0; }
    attempt_trace "$f" 200000 2>/dev/null | python3 -c '
import sys, json
out = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try: e = json.loads(line)
    except Exception: continue
    t = e.get("type")
    if t == "assistant":
        for c in (e.get("message", {}) or {}).get("content", []) or []:
            if c.get("type") == "text" and c.get("text", "").strip():
                out.append("  " + c["text"].strip().replace("\n", " ")[:200])
            elif c.get("type") == "tool_use":
                inp = c.get("input", {}) or {}
                arg = inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                out.append("  $ %s %s" % (c.get("name", "?"), str(arg)[:150]))
    elif t == "user":
        for c in (e.get("message", {}) or {}).get("content", []) or []:
            if c.get("type") == "tool_result":
                body = c.get("content")
                if isinstance(body, list):
                    body = " ".join(x.get("text", "") for x in body if isinstance(x, dict))
                body = str(body or "").strip().replace("\n", " ")
                if body:
                    out.append("    -> " + body[:160])
    elif t == "result":
        out.append("  [session ended: %s]" % e.get("subtype", "?"))
sys.stdout.write("\n".join(out[-int(sys.argv[1]):]) if out else "(trace had no readable events)")
' "$n" 2>/dev/null || printf '(could not render the trace)'
}

bead_context() {         # bead_context <id> -> a human-readable block
    local id="$1"
    [ -n "$id" ] && [ "$id" != "-" ] || { printf '(no single bead — this is about the plan as a whole)'; return 0; }
    bdjson show "$id" 2>/dev/null | python3 -c '
import sys, json, datetime
try:
    d = json.load(sys.stdin)
    i = (d if isinstance(d, list) else [d])[0]
except Exception:
    print("(could not read the bead — say so rather than pretend)"); raise SystemExit
def age(ts):
    try:
        t = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        h = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 3600
        return "%dh" % h if h < 48 else "%dd" % (h / 24)
    except Exception:
        return "?"
print("BEAD    %s  [%s, P%s, open %s]" % (i.get("id"), i.get("status"), i.get("priority"), age(i.get("created_at"))))
print("TITLE   %s" % (i.get("title") or "(none)"))
labs = ", ".join(i.get("labels") or []) or "(none)"
print("LABELS  %s" % labs)
print("")
print("WHAT THIS BEAD IS FOR")
print((i.get("description") or "(no description — that is itself the problem)").strip())
# `notes` is a STRING on these beads, not a list — iterating it yielded one character
# per "note" and printed "- c", "- h". Normalise before slicing anything.
notes = i.get("notes")
if isinstance(notes, str):
    notes = [n for n in notes.split("\n") if n.strip()]
elif isinstance(notes, list):
    notes = [(n.get("text") if isinstance(n, dict) else str(n)) for n in notes]
else:
    notes = []
if notes:
    print("")
    print("MOST RECENT NOTES")
    for n in notes[-3:]:
        print("  - %s" % str(n).strip()[:400])
' 2>/dev/null || printf '(could not read %s)' "$id"
}

# landed <id> <repo> -> 0 landed, 1 not landed, 2 CANNOT TELL.
#
# THREE OUTCOMES, NOT TWO. A caller that reads "cannot tell" as "not landed" reopens finished
# work, and the state where the answer is unavailable — a repository whose land ref does not
# resolve — is exactly the state this whole change is about. 2 is distinct so it cannot be
# mistaken for a verdict.
#
# THE BASE IS NOT ALWAYS `main`. Some repositories are `master`, and this hardcoded
# main — so sp-pd-ci-green's work merged to master, its PR closed, all four polecat PRs
# closed, and this still reported "no commit on main names it" and reopened the bead four
# times. It reached attempt 4 against a poison threshold of 3: the harness was one pass from
# escalating a finished, merged deliverable as a failure.
landed() {
    local id="$1" repo="${2:-$(repo_root)}" subjects refs
    # THE REPOSITORY'S OWN LAND REF, not `main`, and its local counterpart alongside it. The
    # sentinel lands by pushing from the .landing worktree straight to the remote, and
    # nothing in the harness ever pulls the shared checkout, so the local ref there is
    # however stale the last human left it. That was survivable only while a landed branch
    # was never deleted and CHECK 5 could fall back to "the work exists on spira/<id>"; the
    # reaper removes that branch, so this ref list is now the only thing standing between a
    # landed bead and being reopened. spira_landrefs keeps only refs that resolve, so a
    # repository with no local copy of its base still works.
    refs="$(spira_landrefs "$repo")" || return 2
    # Capture, then match. `git log | grep -q` under pipefail returns 141 (SIGPIPE) on a
    # MATCH, because grep -q closes the pipe first — so the check inverts exactly when it
    # succeeds. It reopened finished work once before this was understood.
    # shellcheck disable=SC2086
    subjects="$(git -C "$repo" log --format='%s%n%b' -n 400 $refs 2>/dev/null)"
    grep -qF "$id" <<< "$subjects"
}

# content_landed <repo> <branch> <baseref> -> 0 if <baseref> already contains every change
# <branch> makes, 1 if it does not.
#
# ANCESTRY IS NOT THE ONLY WAY WORK LANDS, AND ON A SQUASHING REPOSITORY IT IS NEVER THE WAY.
# A squash merge replays the branch's whole diff as ONE NEW COMMIT with a new SHA and a
# parentage the branch does not appear in, so the branch's own commits are not ancestors of
# the base and never will be. Every SHA-based test therefore answers "not landed" about work
# that is demonstrably on the base — and then the rebase that follows CONFLICTS, precisely
# because the base already holds those changes. The harness read that pair as a branch in
# trouble and reopened a finished bead with "does not rebase onto <base>", which was true and
# meant the opposite of what it was taken to mean. It repeats forever, because nothing about
# the situation changes between passes.
#
# So ask the question that actually matters: would merging this branch into the base change
# anything? `merge-tree --write-tree` performs the three-way merge in memory and prints the
# resulting tree; when that tree IS the base's own tree, the merge is a no-op and the content
# is already there. This is deliberately not the rebase's question — a rebase replays commit
# by commit and can conflict on an intermediate patch whose end state is fine, which is
# exactly the false alarm.
#
# It answers NO when the merge conflicts (non-zero exit) and NO when the merged tree differs,
# both of which mean the branch really does carry something the base lacks. That is what makes
# it safe for a caller that DELETES on the answer: it cannot say "landed" about a branch with
# work outstanding. `landed()` above is a different question — whether a commit on the base
# names the BEAD — and is not a substitute here, because a branch may carry commits beyond the
# one that landed.
#
# NO PIPE. `git ... | head -1` under pipefail returns 141 when head closes the pipe first, so
# the check would fail exactly when merge-tree succeeded (law-no-grep-q-under-pipefail).
# Capture whole, then trim.
content_landed() {
    local repo="$1" br="$2" base="$3" merged basetree
    git -C "$repo" merge-base --is-ancestor "$br" "$base" 2>/dev/null && return 0
    merged="$(git -C "$repo" merge-tree --write-tree "$base" "$br" 2>/dev/null)" || return 1
    merged="${merged%%$'\n'*}"
    [ -n "$merged" ] || return 1
    basetree="$(git -C "$repo" rev-parse "$base^{tree}" 2>/dev/null)" || return 1
    [ "$merged" = "$basetree" ]
}

# pr_merged <repo> <branch> -> 0 if a pull request whose head is <branch> is MERGED.
#
# The second reading of "already landed", and the one that survives what content_landed
# cannot: a squash that merged and was then amended on the base. The content differs, so the
# merge test says no, and re-landing the branch would revert whoever amended it.
#
# THIS IS EVIDENCE FOR NOT REOPENING, NEVER EVIDENCE FOR DELETING. A merged pull request says
# the work was accepted; it does not say the ref holds nothing else. A caller about to destroy
# a branch must use content_landed, which is exact and local. This one reaches the network, so
# it belongs behind a cheap check that has already failed — never on the common path.
pr_merged() {
    local repo="$1" br="$2" state
    state="$( cd "$repo" 2>/dev/null && ghq pr view "$br" --json state -q .state 2>/dev/null )" || return 1
    [ "$state" = "MERGED" ]
}

# --------------------------------------------------------------------------------------
# Memory delivery. An aeon has no SessionStart hook, so this is how it reads the law — and
# now also how Ops reads its runbooks, since a statute and an SOP are the same mechanism
# under two prefixes (law- and sop-).
#
# TWO DEFECTS THIS REPLACES. `bd memories` is a LISTING: it truncates every body at ~110
# characters with an ellipsis, so every aeon so far has been reading half-sentences —
# "check YOUR OWN LAST ACTION befo..." teaches nothing, and a statute nobody can finish
# reading is not in force. And the caller then cut the listing with `head -400`, which
# silently drops whichever statutes sort last. Read the JSON, print it whole, and when a
# budget really is exceeded say so in the output rather than trimming in the dark.
#
# The prefix filter is what keeps the two books apart. Without it every builder aeon pays
# for every runbook it will never execute, and the runbooks push the law off the end.
# --------------------------------------------------------------------------------------
render_memories() {      # render_memories <prefix-csv> [char-budget]
    local prefixes="${1:-law-}" budget="${2:-120000}"
    bdjson memories 2>/dev/null | python3 -c '
import sys, json
prefixes = [p for p in sys.argv[1].split(",") if p]
budget = int(sys.argv[2])
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
mem = {k: v.strip() for k, v in sorted(d.items())
       if isinstance(v, str) and any(k.startswith(p) for p in prefixes)}
out, used, dropped = [], 0, []
for k, v in mem.items():
    block = f"## {k}\n\n{v}\n"
    if used + len(block) > budget:
        dropped.append(k); continue
    out.append(block); used += len(block)
print("\n".join(out))
if dropped:
    print(f"\n<!-- {len(dropped)} memories omitted for budget: {", ".join(dropped)} -->")
' "$prefixes" "$budget" 2>/dev/null
}

goal_open_children() {   # beads under the goal epic that are not closed
    bdjson children "$SPIRA_GOAL" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
d = d if isinstance(d, list) else [d]
for i in d:
    if i.get("id") != "'"$SPIRA_GOAL"'" and i.get("status") != "closed":
        print(i["id"])
' 2>/dev/null
}

# --------------------------------------------------------------------------------------
# THE REPOSITORY REGISTRY. Which repository a bead is worked in comes from THE BEAD — a
# `repo:<name>` label, the same partition every imported Gas Town bead already carries —
# and `repo-map` says what that name means on this disk.
#
# It used to come from the fayth, as FAYTH_REPO, which is a constant per persona: every
# fayth in the chamber pointed at the home checkout, so Spira could not touch any other
# repository on the box. Collapsing the per-repository databases into one made the cross-repo
# DEPENDENCY expressible and left the cross-repo WORK impossible, which is most of what the
# collapse was for. It surfaced the day the operator endorsed fixing ~37 grep -q
# pipelines in another repository and there was no aeon that could open the file.
#
# UNKNOWN NAMES FAIL CLOSED. Every lookup here returns non-zero for a name the map does not
# carry, and every caller must treat that as a refusal rather than reach for a default. A
# default of the home checkout is precisely how another repository's bead gets "fixed" in the
# home repo, and the aeon would report success — it committed, on a branch, naming its bead.
# `repo:town` is deliberately unmapped for the same reason it is deliberately unfenced: Gas
# Town is still serving and new dispatch into it is frozen.
# --------------------------------------------------------------------------------------
# SPIRA_REPO_MAP is resolved in conf.sh, which falls back to repo-map.example so a
# clean clone has a map at all. This line is the guard for a lib.sh sourced without it.
SPIRA_REPO_MAP="${SPIRA_REPO_MAP:-$SPIRA_HOME/repo-map}"

# The name is DERIVED from the checkout the harness is installed in (conf.sh: basename of
# SPIRA_REPO) and overridable in spira.conf. It used to be the literal `brain`, which is one
# operator's repository written into the mechanism.
spira_home_repo() {      # the repo name a bead means when it names none
    printf '%s' "${SPIRA_HOME_REPO:-$(basename "${SPIRA_REPO:-$SPIRA_HOME}")}"
}

# COLUMNS ARE NAMED, NEVER NUMBERED. This function took an index until `base` was added
# between `land` and `format`, at which point every existing call site silently meant a
# different column — the gate command would have been read as a branch name and a branch
# name run as a gate. A name cannot shift under a new column.
#
# THE ROW SHAPE DECIDES WHERE THE OPTIONAL COLUMNS LIVE, and every read is symmetric about
# it: six fields is the current form, five is the form before `base` existed, four predates
# the formatter too.
#
# Reading any of them from a fixed position is how a format change fails silently, in both
# directions at once. Position 4 in a five-field row holds a FORMATTER, a single token that
# looks exactly like a ref until git is asked — so no heuristic over the field CONTENT can
# tell a formatter from a base, only NF can. And a gate read from a fixed field 6 of a
# five-field row comes back EMPTY, which this file defines as "syntax was the whole trial":
# gate-brain.sh would quietly stop running and every branch would land ungated. That is the
# worse half, because it fails OPEN — and it is reachable in deployment rather than
# hypothetical, since the harness is installed in a checkout and read by systemd
# timers, so lib.sh and repo-map can be read out of step for one pass.
#
# NOTE: no apostrophes inside the awk program below. It is single-quoted, so one in a comment
# closes the string and the shell reports a syntax error pointing at the following line.
repo_field() {           # repo_field <name> <path|land|base|format|gate> -> the field
    local name="$1" col="$2"
    [ -f "$SPIRA_REPO_MAP" ] || return 1
    awk -v want="$name" -v col="$col" '
        BEGIN { FS = "|" }
        /^[ \t]*#/ { next }
        {
            n = $1; gsub(/^[ \t]+|[ \t]+$/, "", n)
            if (n == "" || NF < 2 || n != want) next
            # The gate is everything from the last fixed column on, rejoined: of the two
            # command columns only one can be last, and the gate is the one with any
            # business containing a pipe. The formatter is therefore a single field, which
            # is why repo-map says so.
            #
            # WHICH position that is comes from NF, never from a constant. A six-field row
            # is the current shape; a five-field row is the shape before `base` existed, so
            # it has a formatter and no base; anything narrower predates both.
            if      (col == "gate")   { s = (NF >= 6 ? 6 : (NF == 5 ? 5 : 4)); v = ""
                                        for (i = s; i <= NF; i++) v = v (i > s ? "|" : "") $i }
            else if (col == "path")   v = $2
            else if (col == "land")   v = $3
            else if (col == "base")   v = (NF >= 6 ? $4 : "")
            else if (col == "format") v = (NF >= 6 ? $5 : (NF == 5 ? $4 : ""))
            else                      v = ""
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            print v; exit
        }' "$SPIRA_REPO_MAP" 2>/dev/null
}

repo_names() {           # every repo name in the map, one per line
    [ -f "$SPIRA_REPO_MAP" ] || return 0
    awk 'BEGIN { FS = "|" } /^[ \t]*#/ { next }
         { n = $1; gsub(/^[ \t]+|[ \t]+$/, "", n); if (n != "" && NF > 1) print n }' \
        "$SPIRA_REPO_MAP" 2>/dev/null
}

# repo_root <name> -> the checkout, or non-zero if the map does not carry that name.
#
# SPIRA_REPO still names the HOME repository, because that is the seam every existing suite
# drives a fixture through: a test sets SPIRA_REPO and its beads carry no `repo:` label at
# all. Widening it into a map rather than replacing it is what keeps those suites honest.
repo_root() {
    local name="${1:-}" p
    [ -n "$name" ] || name="$(spira_home_repo)"
    # ONLY WHEN IT IS AN OVERRIDE. conf.sh derives SPIRA_REPO from where the harness sits, so
    # it is now always set — and taking it unconditionally made every home-repository lookup
    # bypass the map. It counts as an override exactly when it differs from that derived
    # value, which is what "somebody set this on purpose" means here.
    if [ "$name" = "$(spira_home_repo)" ] && [ -n "${SPIRA_REPO:-}" ] \
       && [ "$SPIRA_REPO" != "${SPIRA_REPO_DERIVED:-}" ]; then
        printf '%s' "$SPIRA_REPO"; return 0
    fi
    p="$(repo_field "$name" path)"
    [ -n "$p" ] || return 1
    printf '%s' "$p"
}

# spira_same_repo <a> <b> -> 0 if those two paths are the same repository.
#
# BY OBJECT STORE, NEVER BY PATH STRING. A worktree and the checkout it was cut from are one
# repository under two paths, and this harness runs from both — every aeon works in a
# worktree and the landing gate extracts one. A string comparison therefore calls the copy in
# force "some other repository", so a fence keyed on it fires on every branch, and a check
# keyed on it reports a second copy that does not exist.
#
# `--git-common-dir` and not `--git-dir`: a worktree has a private git dir and a shared common
# one, and only the shared one identifies the repository. Resolved by `cd` + `pwd -P` rather
# than `--path-format=absolute`, which is newer than the git a colleague may be running, and
# because the answer is relative when the command is run from inside the repository.
spira_same_repo() {      # spira_same_repo <path-a> <path-b>
    local a b
    a="$(_spira_gitstore "${1:-}")" || return 1
    b="$(_spira_gitstore "${2:-}")" || return 1
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]
}

_spira_gitstore() {      # _spira_gitstore <path> -> its shared git directory, absolute
    local d
    d="$( cd "${1:-/nonexistent}" 2>/dev/null \
          && d="$(git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$d" ] \
          && cd "$d" 2>/dev/null && pwd -P )" || return 1
    [ -n "$d" ] || return 1
    printf '%s' "$d"
}

repo_land() {            # repo_land <name> -> push | pr | hold
    local m; m="$(repo_field "${1:-}" land)"
    printf '%s' "${m:-push}"
}

# --------------------------------------------------------------------------------------
# THE CI PARK, AND THE TWO WAYS IT BECOMES A LIE.
#
# An aeon parks a bead on `$SPIRA_CI_LABEL` once its pull request is open, so nothing pays an
# Opus session to sit and watch a test suite. The label is excluded from every fayth's
# predicate AND from the stalled-work report, which is what stops parked work looking
# abandoned — and is exactly what makes a park applied where no run exists permanent and
# invisible: not claimable, not reported, and displayed as "in CI", the one description that
# stops anybody looking for the real cause. A bead reached 22 reclaims that way, not one of
# them a work failure.
#
#   no-ci    the repository does not land through pull requests, so there is no run and never
#            will be one. Only `pr` mode opens one: `push` merges the branch itself and `hold`
#            leaves it for a human, and for both of those the landing gate IS the gate, so
#            once it passes there is nothing further to wait for. An UNMAPPED repository
#            answers here too, and should — a repository the map cannot resolve cannot land
#            at all, so a park on it is waiting for something that has no mechanism.
#            This is also the case a check made at the moment of parking could not catch: a
#            bead that MOVED repository while parked was parked correctly and is not now.
#   expired  whatever the repository, a park older than the longest plausible run is not
#            parked, it is lost. Expiring it hands the bead back to the report that would
#            have found it (law-absence-needs-a-positive-control).
#   watch    a pull-request repository, inside the deadline. Leave it alone.
#
# RC 2 MEANS THE PARK COULD NOT BE AGED — a missing or unparseable timestamp. It prints
# `watch` with it, because the two callers want different things from that and neither wants
# a guess: the sweep must not strip a label on the strength of a clock it could not read,
# while the pane must not paint an unreadable check as normal. A broken check that renders as
# all-clear displaces the suspicion that would have prompted a look.
#
# Pure decision — no database, no network, no writes — so the sweep and the pane share one
# answer instead of two that can disagree, and a suite can drive every branch of it.
# --------------------------------------------------------------------------------------
spira_ci_park_state() {  # spira_ci_park_state <repo-name> <updated-at> -> watch|no-ci|expired
    local name="${1:-}" ts="${2:-}" max t now
    [ "$(repo_land "$name")" = pr ] || { printf 'no-ci'; return 0; }
    max="${SPIRA_CI_PARK_MAX:-5400}"
    case "$max" in ''|*[!0-9]*) max=5400 ;; esac
    [ "$max" -gt 0 ] || { printf 'watch'; return 0; }   # 0 disables the deadline, deliberately
    # THE EMPTY TIMESTAMP IS REFUSED BEFORE `date` SEES IT. `date -d ""` does not fail — it
    # answers midnight today — so an absent updated_at read as a park several hours old and
    # expired itself, silently, on a field the caller never had. A missing input must reach
    # the caller as "could not age this", never as a verdict.
    [ -n "$ts" ] || { printf 'watch'; return 2; }
    # `date -d` and not python: this is called once per parked bead from a pane that repaints,
    # and an interpreter start per bead is the cost that makes a dashboard shell out and freeze.
    t="$(date -u -d "$ts" +%s 2>/dev/null)" || t=""
    [ -n "$t" ] || { printf 'watch'; return 2; }
    now="$(date -u +%s)"
    if [ "$(( now - t ))" -gt "$max" ]; then printf 'expired'; else printf 'watch'; fi
}

repo_gate() {            # repo_gate <name> -> the repo's own gate command, possibly empty
    repo_field "${1:-}" gate
}

# repo_format <name> -> the repo's own formatter, or nothing. ABSENCE MEANS DO NOTHING, and
# that is a decision rather than a gap: running a formatter a repository has not asked for
# turns one bead's rebase into a thousand-line diff nobody requested, and on a repository
# whose base is already unformatted — another, measured once — it rewrites the whole
# tree out from under the work.
repo_format() {
    repo_field "${1:-}" format
}

# repo_base <name> -> the repo's declared base ref, or nothing if the row leaves it to
# spira_landref to resolve. Callers want spira_landref, not this: it is the raw column.
repo_base() {
    repo_field "${1:-}" base
}

# repo_name_at <path> -> the map name for a checkout path, or non-zero.
#
# The reverse of repo_root, and it exists because rebase_branch is addressed by PATH — that
# is the seam test-rebase.sh and test-repo.sh both drive — while the formatter is declared
# per NAME. Paths are unique by construction: two repositories cannot share a directory,
# which is the same property the per-repository scratch worktree is named for. A caller
# that already holds the name should pass it rather than make this guess.
repo_name_at() {
    local p="${1:-}" home n
    [ -n "$p" ] || return 1
    home="$(spira_home_repo)"
    # SPIRA_REPO overrides the map for the home repo, so it must be consulted first or a
    # fixture — which has no map entry at all — resolves to nothing.
    if [ -n "${SPIRA_REPO:-}" ] && [ "$SPIRA_REPO" != "${SPIRA_REPO_DERIVED:-}" ] \
       && [ "$p" = "$SPIRA_REPO" ]; then printf '%s' "$home"; return 0; fi
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        if [ "$(repo_field "$n" path)" = "$p" ]; then printf '%s' "$n"; return 0; fi
    done <<< "$(repo_names)"
    return 1
}

# spira_repos -> every repository this harness manages, one name per line.
#
# The home repo is ALWAYS first and always present, map or no map. A fixture that copies
# lib.sh next to nothing else has no repo-map, and a sentinel that then iterated zero
# repositories would land nothing while reporting a clean pass — the exact false-clean this
# whole file is written against.
spira_repos() {
    local home; home="$(spira_home_repo)"
    printf '%s\n' "$home"
    repo_names | grep -vx -- "$home" || true
}

# repo_of_labels <label...> -> the `repo:` name carried by a label list, or nothing.
# Reads from labels already in hand rather than issuing a query, because the caller that
# matters — aeon.sh — is holding the JSON `bd ready --claim` just handed it.
repo_of_labels() {
    local l
    for l in "$@"; do
        case "$l" in repo:*) printf '%s' "${l#repo:}"; return 0 ;; esac
    done
    return 1
}

bead_branch() {          # bead_branch <id> -> its recorded branch, or the derived default
    # The recorded affinity, read back. Falls through to the derived name so a bead filed
    # before branches were recorded still resolves (law-branch-affinity-is-recorded).
    local id="$1" br
    br="$(bdq label list "$id" 2>/dev/null | sed -n 's/^ *- branch:\(.*\)$/\1/p' | head -1)"
    printf '%s' "${br:-spira/$id}"
}

bead_repo() {            # bead_repo <id> -> its repo name, or the home repo if it names none
    local id="$1" name
    name="$(bdjson show "$id" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
d = d if isinstance(d, list) else [d]
for l in (d[0].get("labels") or []) if d else []:
    if l.startswith("repo:"):
        print(l[5:]); break' 2>/dev/null)"
    printf '%s' "${name:-$(spira_home_repo)}"
}

# --------------------------------------------------------------------------------------
# THE BASE. Every branch this harness creates, and every branch it lands, is measured
# against the REMOTE-TRACKING ref of its repository's default branch — never the local one.
#
# Nothing in the harness ever advances the shared checkout's default branch. The sentinel
# lands by pushing `landing:<branch>` to the remote from the .landing worktree and never
# pulls the shared checkout, so the local ref there is however stale the last human left it. Every
# Spira bead edits the same handful of files under .claude/spira, and the queue is
# serialised at one aeon, so a branch cut from that stale ref collides with whatever landed
# while the previous aeon worked — by construction, every single time. Measured:
# sp-poison-retry based at 8ed6cca with main already at 5da8438, conflicting in sentinel.sh,
# lib.sh, gate.sh and log.md, none of which it had touched.
#
# THE DEFAULT BRANCH IS NOT `main`, AND ASSUMING IT IS BREAKS THREE THINGS AT ONCE. Measured
# across seven rows of a real repo-map: two had no ref named `main` anywhere, remote or local
# — their default is `master` — and a third had no remote named `origin` at all. For those
# three the old answer named a branch
# that does not exist, so `git worktree add -b spira/<id> "$WORK" "$BASE"` failed and no aeon
# could get a workspace in them at all; CHECK 6's rebase failed and REOPENED finished work
# with "does not rebase onto main"; and `gh pr create --base main` opened against nothing.
#
# So the answer is RESOLVED per repository, in this order, and a repository whose answer
# cannot be established is refused rather than guessed — the same way an unmapped `repo:`
# name is refused. `main` is a guess, and a guess here rebases somebody's work onto a branch
# nobody chose.
#
#   1. repo-map's `base` column. Declared beats derived: the two automatic sources below are
#      both local caches that can be stale, absent, or pointing at whatever branch a human
#      last checked out.
#   2. refs/remotes/origin/HEAD — what the remote said its default was, cached at clone time.
#   3. `git remote set-head <remote> --auto`, which ASKS the remote and caches the answer in
#      exactly the ref rung 2 reads, so it costs one round trip ever rather than one a pass.
#      Only reached when the map is silent and the cache is empty.
#   4. a repository with NO remote at all: its own current branch. Nothing can be stale
#      against a remote that does not exist, so HEAD is the only truth there is. This is the
#      test fixture's case.
#
# THE CHECKOUT'S CURRENT BRANCH IS NEVER CONSULTED FOR A REPOSITORY THAT HAS A REMOTE, and
# that restriction is load-bearing rather than fastidious: measured the same day, two of them
# sat on a DETACHED HEAD, one on a topic branch and another on
# `chore/keep-cf-access-probe`. Deriving the land ref from HEAD would have answered
# the remote form of that topic branch — a worse answer than the bug it replaced,
# because it names a ref that exists.
# --------------------------------------------------------------------------------------
spira_landref() {        # spira_landref [repo-path-or-name] -> the base ref, or non-zero
    local arg="${1:-}" name="" repo="" ref remote remotes
    case "$arg" in
        "")   name="$(spira_home_repo)" ;;
        */*)  repo="$arg" ;;
        *)    name="$arg" ;;
    esac
    if [ -z "$repo" ]; then repo="$(repo_root "$name")" || return 1; fi
    [ -n "$name" ] || name="$(repo_name_at "$repo" 2>/dev/null)" || name=""
    [ -e "$repo/.git" ] || return 1

    # 1 - declared. Verified to exist: a `base` naming a ref this checkout does not have is
    # the very defect being fixed, and shipping it would only move the guess into the map.
    #
    # A row with no base column at all answers empty here and falls through to resolution -
    # repo_field decides that on the row shape, which is the only thing that can tell a
    # missing column from a declared one.
    if [ -n "$name" ]; then
        ref="$(repo_field "$name" base 2>/dev/null)"
        if [ -n "$ref" ]; then
            git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 || return 1
            printf '%s' "$ref"; return 0
        fi
    fi

    # 2 - the remote's own declared default, as cached locally.
    ref="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
    if [ -n "$ref" ] && git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1; then
        printf '%s' "$ref"; return 0
    fi

    remotes="$(git -C "$repo" remote 2>/dev/null)"

    # 3 - ask the remote once. `origin` if there is one, otherwise the single remote there
    # is; two unnamed remotes is a genuine ambiguity and is refused. set-head writes the ref
    # rung 2 reads, so this happens once per repository and not once per pass.
    if [ -n "$remotes" ]; then
        if grep -qx origin <<< "$remotes"; then remote=origin
        elif [ "$(wc -l <<< "$remotes")" = 1 ]; then remote="$remotes"
        else remote=""; fi
        if [ -n "$remote" ] \
           && git -C "$repo" remote set-head "$remote" --auto >/dev/null 2>&1; then
            ref="$(git -C "$repo" symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null)"
            if [ -n "$ref" ] && git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1; then
                printf '%s' "$ref"; return 0
            fi
        fi
        return 1
    fi

    # 4 - no remote at all: the repository's own current branch. Nothing can be stale
    # against a remote that does not exist, so HEAD is the only truth there is. This is the
    # test fixture's case, and the ONLY rung that consults a checkout's HEAD.
    ref="$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)"
    if [ -n "$ref" ] && git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1; then
        printf '%s' "$ref"; return 0
    fi
    return 1
}

# Splitting a land ref into its two halves. `origin/master` is what a branch is MEASURED
# against; `master` is what a push targets and what `gh pr create --base` wants; `origin` is
# what a fetch names. Every call site did these two strips by hand as ${base#origin/} and a
# literal `origin`, both of which are assumptions about a remote's name, and a remote need
# not be called that. String operations, not lookups, so a caller holding a ref never re-resolves it.
ref_remote() {           # ref_remote <ref> -> its remote, or non-zero if the ref is local
    case "${1:-}" in */*) printf '%s' "${1%%/*}" ;; *) return 1 ;; esac
}
ref_branch() {           # ref_branch <ref> -> the branch name, without any remote
    printf '%s' "${1#*/}"
}

# spira_landrefs <repo> -> the land ref, plus its local counterpart when that exists.
# The commit graph is read across BOTH, because a commit can be on the local branch and not
# yet pushed, or pushed and never pulled into this checkout. Two call sites asked this
# question with a literal `main` appended, which for a `master`-based repository added a ref that is not
# there and for a `master` repository omitted the only one that is. The strip is ${base#*/}
# and not ${base#origin/}: a remote need not be called `origin`, so stripping that literal
# leaves a ref like `upstream/master` unchanged and the local ref is silently never consulted.
spira_landrefs() {
    local repo="$1" base lo
    base="$(spira_landref "$repo")" || return 1
    printf '%s' "$base"
    lo="${base#*/}"
    if [ "$lo" != "$base" ] && git -C "$repo" rev-parse --verify -q "$lo" >/dev/null 2>&1; then
        printf ' %s' "$lo"
    fi
}

# --------------------------------------------------------------------------------------
# worktree_of <branch> [repo] -> the registered worktree path holding it, or empty.
# Read from `git worktree list --porcelain` rather than guessed from the bead id, so a
# worktree someone put somewhere else is still found.
# --------------------------------------------------------------------------------------
worktree_of() {
    local br="$1" repo="${2:-$(repo_root)}"
    git -C "$repo" worktree list --porcelain 2>/dev/null | python3 -c '
import sys
want = "refs/heads/" + sys.argv[1]
path = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "): path = line[9:]
    elif line.startswith("branch ") and line[7:] == want and path:
        print(path); break
' "$br" 2>/dev/null
}

# --------------------------------------------------------------------------------------
# holder_alive <id> -> 0 if an aeon process is working this bead. The pidfile is the only
# witness that answers in the seconds between `bd ready --claim` and the aeon writing it,
# and it is the witness that matters before anything DESTRUCTIVE: rewriting a branch under
# a running aeon destroys work that exists nowhere else.
# --------------------------------------------------------------------------------------
holder_alive() {
    local id="$1" pf
    for pf in "$SPIRA_RUN"/aeon-*-"$id".pid; do
        [ -e "$pf" ] || continue
        aeon_alive "$pf" && return 0
    done
    return 1
}

# ======================================================================================
# DESTRUCTION. Every removal of a bead's worktree or branch goes through this section, and
# nothing outside it may call `git worktree remove`, `git branch -D` or `rm -rf` on a tree.
#
# WHY IT IS ONE SITE. A bead's worktree and branch were both destroyed while its aeon was
# mid-edit and its lease was live, taking forty minutes of uncommitted work, writing no
# salvage, and NAMING THE BEAD IN NO LOG — the Sending's own passes bracket the deletion and
# report the tree HELD on one side and 0 reaped on the other, so the actor was some other
# process entirely. It had happened twenty times to the same bead, every note reading
# "Reclaimed by strand.sh", which is the signature an aeon leaves when its workspace vanishes
# underneath it: twenty aeons spent re-deriving work the harness then ate.
#
# The lesson is not "fix that caller". Deletion was SPREAD ACROSS SIX SITES, each with its own
# guard or none, reachable by anything that sources this file with the default environment —
# including a test suite run from the installed tree, which is how an operator's real
# checkouts were once swept (see test-sending.sh's own header). A rule enforced at six sites
# is a rule enforced at whichever of them the next caller does not use. So the rule lives at
# one site, it is unconditional, and it does not care who is calling.
#
# WHAT IT REFUSES, and why each is not optional:
#
#   • A path outside `$SPIRA_RUN/worktree/`. A deleter handed anything else has been
#     misconfigured — a fixture that forgot to set SPIRA_RUN, a repo-map naming a real
#     checkout — and misconfiguration must not be able to reach `rm -rf`.
#   • TWO liveness witnesses, not one. `holder_alive` reads a pidfile that is absent for the
#     seconds between `bd ready --claim` and the aeon writing it; the bead's status is stale
#     for as long as it takes a killed aeon's lease to be reclaimed. Either alone has a blind
#     spot the other covers, so BOTH must say nobody is home.
#   • A status witness that could not be examined at all. An unreachable database answers
#     "not in_progress" exactly as a genuinely open bead does, and the wrong one of those
#     reads as permission (law-absence-needs-a-positive-control). The probe is proved able to
#     answer once per process before any absence is believed.
#   • A salvage that did not succeed. Salvage runs BEFORE the removal, and its failure aborts
#     the removal rather than being stepped over.
#
# And it LOGS EVERY DECISION, naming the bead and the calling program, to $SPIRA_REAPLOG —
# so the next occurrence is one `grep` rather than four hours of correlating timestamps.
# ======================================================================================
SPIRA_REAPLOG="${SPIRA_REAPLOG:-$SPIRA_RUN/reap.log}"

# The program that reached the chokepoint, read from /proc rather than matched against a
# command line: a pattern matches the searcher's own argv, which is how `pgrep -f` reported
# a collector healthy by finding the shell that was killing it. Walks the ancestor chain,
# because the interesting name is rarely the immediate one — `sending.sh` tells you nothing,
# `test-repo.sh -> sending.sh` tells you everything.
spira_caller() {
    local pid=$$ n=0 out="" cmd first
    while [ "$n" -lt 6 ] && [ "$pid" != 1 ] && [ -r "/proc/$pid/cmdline" ]; do
        cmd="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -v '^-' | head -3 | tr '\n' ' ')"
        first="$(printf '%s' "$cmd" | tr ' ' '\n' | grep -E '\.(sh|py)$' | head -1)"
        [ -n "$first" ] && out="$(basename "$first")${out:+ -> $out}"
        pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)" || break
        [ -n "${pid:-}" ] || break
        n=$((n+1))
    done
    printf '%s' "${out:-unknown}"
}

spira_reaplog() {        # spira_reaplog <verb> <id> <detail>
    mkdir -p "$(dirname "$SPIRA_REAPLOG")" 2>/dev/null
    printf '%s %-9s %-22s %s [by %s]\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:-}" "$(spira_caller)" \
        >> "$SPIRA_REAPLOG" 2>/dev/null || true
}

# The status witness, and the seam a suite drives it through. `--status-from` is the honest
# manual entry point too: it says exactly what the caller believes about each bead.
declare -A SPIRA_STATUS_MAP=()
SPIRA_STATUS_SEAM=0
spira_status_seam() {    # spira_status_seam <file|-> — load the map once
    local sid sst
    while IFS=$'\t' read -r sid sst; do
        [ -n "${sid:-}" ] && SPIRA_STATUS_MAP["$sid"]="${sst:-}"
    done < <(if [ "$1" = - ]; then cat; else cat "$1"; fi)
    SPIRA_STATUS_SEAM=1
}

spira_bead_status() {    # <id> -> open|in_progress|blocked|closed|"" (unknown)
    if [ "$SPIRA_STATUS_SEAM" = 1 ]; then printf '%s' "${SPIRA_STATUS_MAP[$1]:-}"; return; fi
    bdjson show "$1" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
d = d if isinstance(d, list) else [d]
print(d[0].get("status", "") if d else "")' 2>/dev/null
}

# THE POSITIVE CONTROL for the status witness. An empty answer means "this bead is not in
# progress" only if the probe could have said otherwise; from a database that is down, every
# bead reads as free. Proved once per process against a bead known to exist — the goal bead,
# which is the one row this harness cannot run without — and cached, because it gates a loop
# that runs every two minutes over seven repositories.
SPIRA_DB_OK=""
spira_db_reachable() {
    [ "$SPIRA_STATUS_SEAM" = 1 ] && return 0
    if [ -z "$SPIRA_DB_OK" ]; then
        if [ -n "$(bdjson show "$SPIRA_GOAL" 2>/dev/null | json_only | head -c 1)" ]; then
            SPIRA_DB_OK=1
        else
            SPIRA_DB_OK=0
        fi
    fi
    [ "$SPIRA_DB_OK" = 1 ]
}

# spira_holder_witnesses <id> -> 0 and prints WHY somebody may be home; 1 if nobody is.
spira_holder_witnesses() {
    local id="$1" st
    if holder_alive "$id"; then
        printf 'a live aeon holds it'; return 0
    fi
    if ! spira_db_reachable; then
        printf 'the bead database did not answer, so the status witness proves nothing'; return 0
    fi
    st="$(spira_bead_status "$id")"
    if [ "$st" = in_progress ]; then
        printf 'in_progress — the lease has not been released'; return 0
    fi
    return 1
}

# --------------------------------------------------------------------------------------
# Salvage before destroying, and REFUSE TO DESTROY IF IT FAILS. Anything uncommitted in a
# dead aeon's worktree is usually scratch — the aeon's real work is committed, which is what
# made the branch eligible — but "usually" is not a licence, and it has cost real work: the
# uncommitted state WAS the work, forty minutes of it, four times over.
#
# UNTRACKED FILES ARE CARRIED BY CONTENT, not by name. `git diff HEAD` cannot see them, so
# the old salvage listed them and let them go — and a new file is exactly what an aeon
# building something has most of, so the patch was emptiest precisely when it mattered most.
# They go into a tar beside the patch, filtered by `--exclude-standard` so a build directory
# does not turn a salvage into a gigabyte.
#
# THE FILENAME CARRIES A TIMESTAMP because the old one did not. Every reap of a bead wrote
# `<id>.patch`, so twenty reaps of one bead left exactly one patch: nineteen salvages destroyed
# by the salvage machinery itself, silently, each one reported as a success.
# --------------------------------------------------------------------------------------
SALVAGED=""
salvage() {              # salvage <label> <worktree-path> -> 0 saved or nothing to save
    local id="$1" w="$2" dirty out="$SPIRA_RUN/reaped" stamp base rc=0 untracked
    SALVAGED=""
    # A worktree whose status cannot be read is not a clean one; it is a question. Fail
    # closed — the caller aborts its removal.
    if ! dirty="$(git -C "$w" status --porcelain 2>/dev/null)"; then
        spira_reaplog SALVAGE "$id" "cannot read the status of $w — refusing to call it clean"
        return 1
    fi
    [ -n "$dirty" ] || return 0
    mkdir -p "$out" || { spira_reaplog SALVAGE "$id" "cannot create $out"; return 1; }
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    base="$out/$id.$stamp"
    # `|| true` on the diff, and the verdict taken from the FILE rather than the group. A
    # worktree whose branch ref was deleted underneath it has an unborn HEAD, so `git diff
    # HEAD` legitimately fails there — and that is the orphan case, the one where salvage
    # matters most. Letting its exit status stand as the group's turned every orphan salvage
    # into a refusal. What is actually being asked is "did the bytes get written".
    {
        printf '# %s — uncommitted at reap time, %s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# tracked changes are below; untracked file CONTENT is in %s\n' "$(basename "$base").untracked.tar"
        printf '%s\n\n' "$dirty"
        git -C "$w" diff HEAD 2>/dev/null || true
    } > "$base.patch" 2>/dev/null
    [ -s "$base.patch" ] || rc=1

    untracked="$(git -C "$w" ls-files --others --exclude-standard 2>/dev/null)"
    if [ -n "$untracked" ]; then
        git -C "$w" ls-files --others --exclude-standard -z 2>/dev/null \
            | tar -C "$w" --null -T - -cf "$base.untracked.tar" 2>/dev/null || rc=1
        [ -s "$base.untracked.tar" ] || rc=1
    fi

    if [ "$rc" -ne 0 ]; then
        spira_reaplog SALVAGE "$id" "FAILED to write $base.patch — the removal must not proceed"
        return 1
    fi
    SALVAGED="$base.patch"
    spira_reaplog SALVAGE "$id" "wrote $base.patch${untracked:+ and $base.untracked.tar}"
    printf '  salvaged uncommitted changes to %s\n' "$base.patch"
    return 0
}

# --------------------------------------------------------------------------------------
# spira_destroy_worktree <id> <path> <repo> <why> -> 0 removed or nothing to remove
# --------------------------------------------------------------------------------------
spira_destroy_worktree() {
    local id="$1" w="$2" repo="$3" why="${4:-}" held
    [ -n "$w" ] || return 0
    # THE FENCE FIRST, before anything is read off the path or acted on. A deleter handed a
    # path outside the harness's own scratch directory has been misconfigured — a fixture
    # that forgot to set SPIRA_RUN, a repo-map naming a real checkout — and a misconfigured
    # caller must not be able to reach any of what follows, prune included.
    case "$w" in
        "$SPIRA_RUN/worktree/"?*) ;;
        *) spira_reaplog REFUSED "$id" "$w is not under $SPIRA_RUN/worktree — refusing to remove it"
           return 1 ;;
    esac
    if [ ! -e "$w" ]; then
        # The directory has already gone but its REGISTRATION may not have, and a live
        # registration is enough to make `git branch -D` refuse — which is how an interrupted
        # reap leaves a branch that can never be deleted. Nothing here is left to salvage or
        # destroy, so clear the entry (through the prune that repairs rather than orphans)
        # and report success.
        spira_prune_worktrees "$repo" >/dev/null 2>&1
        return 0
    fi
    if held="$(spira_holder_witnesses "$id")"; then
        spira_reaplog REFUSED "$id" "worktree $w — $held"
        return 1
    fi
    if ! salvage "$id" "$w"; then
        spira_reaplog REFUSED "$id" "worktree $w — salvage failed, so the removal is abandoned"
        return 1
    fi
    # Logged BEFORE the act as well as after: a process killed between the two leaves a
    # record that it was about to delete this tree. The absence of that one line turned the
    # incident this section exists for into a four-hour forensic exercise.
    spira_reaplog REMOVING "$id" "worktree $w ($why)"
    git -C "$repo" worktree remove --force "$w" 2>/dev/null \
        || { rm -rf "$w"; spira_prune_worktrees "$repo"; }
    if [ -e "$w" ]; then
        spira_reaplog FAILED "$id" "worktree $w survived removal"
        return 1
    fi
    spira_reaplog REMOVED "$id" "worktree $w"
    return 0
}

# --------------------------------------------------------------------------------------
# spira_destroy_branch <id> <branch> <repo> <why> -> 0 gone, 1 refused or survived.
# The witnesses are re-read rather than inherited from the worktree removal: they are two
# /proc reads and a cached status, and the alternative is a decision made before the act.
# --------------------------------------------------------------------------------------
spira_destroy_branch() {
    local id="$1" br="$2" repo="$3" why="${4:-}" held wt err
    git -C "$repo" show-ref --verify -q "refs/heads/$br" || return 0
    if held="$(spira_holder_witnesses "$id")"; then
        spira_reaplog REFUSED "$id" "branch $br — $held"
        return 1
    fi
    # A branch a worktree still holds is not deletable, and forcing the issue by pruning the
    # registration out from under it is how a live tree becomes an orphan.
    wt="$(worktree_of "$br" "$repo")"
    if [ -n "$wt" ] && [ -e "$wt" ]; then
        spira_reaplog REFUSED "$id" "branch $br is checked out at $wt"
        return 1
    fi
    spira_reaplog REMOVING "$id" "branch $br ($why)"
    err="$(git -C "$repo" branch -D "$br" 2>&1)"
    if git -C "$repo" show-ref --verify -q "refs/heads/$br"; then
        spira_reaplog FAILED "$id" "branch $br survived deletion: $(head -1 <<< "$err")"
        SPIRA_DESTROY_ERR="$(head -1 <<< "$err")"
        return 1
    fi
    spira_reaplog REMOVED "$id" "branch $br"
    return 0
}

# --------------------------------------------------------------------------------------
# spira_prune_worktrees <repo> — `git worktree prune`, with the one case it gets wrong.
#
# Prune is safe on the reading everyone has of it: it drops admin entries for directories
# that are already gone, and one witness is plenty for a directory that does not exist. But
# an entry is ALSO prunable when the worktree's own `.git` file is missing or unreadable
# while the directory is entirely intact and full of work. Pruning that entry frees the
# branch for `git branch -D` and leaves a live tree registered nowhere — the exact state
# PASS 2 of the Sending then classifies as an orphan and removes.
#
# So: anything prune would drop whose DIRECTORY STILL EXISTS is repaired instead, and every
# entry that really is pruned is named in the reap log. `git worktree repair` restores the
# link both ways and is a no-op on a healthy tree.
# --------------------------------------------------------------------------------------
# `prune --dry-run --verbose` reports on STDERR, not stdout. Reading it with a plain `2>/dev/null`
# — the shape every other git call in this harness uses — yields nothing at all, and a guard
# fed an empty list approves everything (law-absence-needs-a-positive-control).
spira_prune_worktrees() {
    local repo="$1" line name path common still=0
    common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 0
    case "$common" in /*) ;; *) common="$repo/$common" ;; esac

    _spira_prunable_path() {   # <entry-name> -> the worktree directory git recorded for it
        local gd; gd="$(cat "$common/worktrees/$1/gitdir" 2>/dev/null)"; printf '%s' "${gd%/.git}"
    }

    while IFS= read -r line; do
        case "$line" in "Removing "*) ;; *) continue ;; esac
        name="${line#Removing }"; name="${name#worktrees/}"; name="${name%%:*}"
        [ -n "$name" ] || continue
        path="$(_spira_prunable_path "$name")"
        if [ -n "$path" ] && [ -d "$path" ]; then
            spira_reaplog REPAIRED "$name" "prune would have dropped a worktree whose directory EXISTS at $path — repairing instead"
            git -C "$repo" worktree repair "$path" >/dev/null 2>&1
        else
            spira_reaplog PRUNED "$name" "$line"
        fi
    done < <(git -C "$repo" worktree prune -n -v 2>&1 >/dev/null)

    # Re-read after the repairs. `git worktree prune` has no way to skip one entry, so if any
    # live directory is STILL prunable the only safe move is not to prune at all: a leaked
    # admin entry is untidy, and unregistering a tree an aeon is working in is not recoverable.
    while IFS= read -r line; do
        case "$line" in "Removing "*) ;; *) continue ;; esac
        name="${line#Removing }"; name="${name#worktrees/}"; name="${name%%:*}"
        path="$(_spira_prunable_path "$name")"
        if [ -n "$path" ] && [ -d "$path" ]; then
            spira_reaplog REFUSED "$name" "still prunable with its directory intact at $path — skipping the prune entirely"
            still=1
        fi
    done < <(git -C "$repo" worktree prune -n -v 2>&1 >/dev/null)
    unset -f _spira_prunable_path
    [ "$still" = 1 ] && return 1

    git -C "$repo" worktree prune 2>/dev/null
    return 0
}

# --------------------------------------------------------------------------------------
# format_rebased <branch> <onto> <worktree> [repo-name] -> 0 always; the rebase stands
# whatever the formatter does.
#
# A REBASE PRODUCES A TREE NOBODY FORMATTED. git replays hunks; it does not re-run anyone's
# formatter on the result, so a rebase that resolves perfectly still hands the required
# check a tree that no human or tool ever laid out. It recurs on exactly the shape a rebase
# is best at — two branches adding names to the same import list, struct literal or match
# arm — where each side is individually well-formed and the union is over the line limit.
# The branch then fails `cargo fmt --all -- --check`, a check it passed before the harness
# touched it, and the failure is charged to the aeon that wrote correct code.
#
# ONLY WHAT THE BRANCH TOUCHED IS COMMITTED. The declared command is repository-wide, because
# that is the writing form of the repository-wide check it must satisfy — but a repository
# whose main is already unformatted would otherwise have its entire tree swept into one
# bead's branch. Against a clean main this restriction changes nothing, since a rebase can
# only disturb the layout of files the branch itself touched; against a dirty one it is the
# difference between a format commit and a rewrite.
#
# A FORMATTER THAT FAILS CHANGES NOTHING. `cargo fmt` exits non-zero on a tree it cannot
# parse, and it may have rewritten half of it first. Discard and let the gate render the
# verdict — a formatter is a convenience, and it must never be able to turn a clean rebase
# into a branch full of partial edits.
# --------------------------------------------------------------------------------------
format_rebased() {
    local br="$1" onto="$2" wt="$3" name="${4:-}" cmd paths f staged=0

    [ -n "$name" ] || name="$(repo_name_at "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)" || return 0
    cmd="$(repo_format "$name" 2>/dev/null)"
    [ -n "$cmd" ] || return 0

    # The formatter sees what a gate command sees and nothing else: an ambient variable that
    # can change a formatter's output changes what lands (law-gates-run-in-a-clean-environment).
    # ~/.cargo/bin for the same reason gate.sh names it — lib.sh's PATH is written for
    # systemd and carries no toolchain.
    if ! ( cd "$wt" && env -i PATH="$HOME/.cargo/bin:$PATH" HOME="$HOME" TERM=dumb \
             timeout "${SPIRA_FORMAT_TIMEOUT:-300}" bash -c "$cmd" ) >/dev/null 2>&1; then
        log "format: $name's formatter failed on $br — leaving the rebase unformatted"
        git -C "$wt" checkout -q -- . 2>/dev/null
        return 0
    fi

    # The branch's own files, read from history rather than from the dirty tree: $onto is an
    # ancestor now, so this diff IS the branch's work. Filtered to paths that still exist,
    # because a path the branch deleted cannot have been reformatted and `git add` on it is
    # an error rather than a no-op.
    paths=()
    while IFS= read -r -d '' f; do
        [ -f "$wt/$f" ] && paths+=("$f")
    done < <(git -C "$wt" diff -z --name-only "$onto" HEAD 2>/dev/null)
    [ "${#paths[@]}" -gt 0 ] && git -C "$wt" add -- "${paths[@]}" 2>/dev/null

    # Everything the formatter touched outside the branch's own work goes back. Staged paths
    # are restored from the index, so this only discards the repository-wide remainder.
    git -C "$wt" checkout -q -- . 2>/dev/null
    git -C "$wt" diff --cached --quiet 2>/dev/null || staged=1
    [ "$staged" = 1 ] || return 0

    # The subject names the bead, because for `spira/<id>` branches ${br##*/} IS the id and
    # that string is the only machine-checkable link between a bead and the commit graph
    # (law-aeon-commits-name-their-bead). Through stdin, never an argument: a formatter
    # command containing backticks or $( ) would otherwise be executed by the very quoting
    # that was meant to quote it (law-commit-messages-via-stdin).
    git -C "$wt" commit -q -F - <<EOF 2>/dev/null
spira: re-format ${br##*/} after rebase onto $onto

The rebase replayed cleanly and nothing re-ran $name's formatter on the result, so
the tree its own check tests was machine-produced. Formatted with: $cmd
EOF
    log "format: re-formatted $br after its rebase onto $onto"
    return 0
}

# --------------------------------------------------------------------------------------
# rebase_branch <branch> <onto> [repo] [repo-name] -> 0 if <branch> now contains <onto>, 1
# if it does not. On failure the branch ref is left EXACTLY as it was and $REBASE_CONFLICTS
# names the paths that collided. On success, and only when commits were actually replayed,
# the repository's own formatter runs on the result and is committed as part of the rebase —
# see format_rebased. The branch tip therefore MOVES on success, and a caller holding a tip
# from before the call is holding a stale one.
#
# THE CALLER MUST HAVE ESTABLISHED THAT NO LIVE AEON HOLDS THE BRANCH. This rewrites
# commits beneath a working tree; doing that under a running aeon destroys work in flight,
# which is the one failure here that is not recoverable. `holder_alive` is the precondition.
#
# WHY THE BRANCH'S OWN WORKTREE. git refuses to move a ref that a worktree has checked out
# — `git branch -f` and `git rebase` both — so when a worktree holds the branch it is the
# only place the rebase can happen. When nothing holds it the rebase still needs SOME
# working tree, and that tree must never be the shared checkout, whose HEAD an interactive
# session is using; a detached scratch worktree costs one checkout.
#
# A rebase is refused by tracked modifications, and those are routine rather than
# exceptional here: wiki/tasks.md is a GENERATED file tracked in git and rewritten by a
# timer, so it is dirty in every worktree within minutes of its creation and would
# otherwise block every rebase for a reason that has nothing to do with the work. Tracked
# changes are salvaged to a patch and discarded; untracked files are left alone, because
# `git diff HEAD` cannot carry their content and discarding them would destroy the one copy.
# --------------------------------------------------------------------------------------
REBASE_CONFLICTS=""
rebase_branch() {
    local br="$1" onto="$2" repo="${3:-$(repo_root)}" name="${4:-}" wt scratch rc=0
    REBASE_CONFLICTS=""
    # The repo NAME, for the formatter that runs on the result. Derived from the path only
    # when the caller did not supply it — both real callers hold it already, having read it
    # off the bead, and a derived value is a convention that breaks the moment two names
    # point at one checkout.
    [ -n "$name" ] || name="$(repo_name_at "$repo" 2>/dev/null)" || name=""

    git -C "$repo" rev-parse --verify -q "$onto" >/dev/null 2>&1 || return 1
    git -C "$repo" show-ref --verify -q "refs/heads/$br" || return 1
    # Already current. This is the common case once branches are cut from the base ref, and
    # it is what makes running the rebase on every landing pass cheap.
    git -C "$repo" merge-base --is-ancestor "$onto" "refs/heads/$br" 2>/dev/null && return 0

    wt="$(worktree_of "$br" "$repo")"
    if [ -z "$wt" ]; then
        # PER REPOSITORY. One shared `.rebase` tree is registered against exactly one
        # repository, so a second repo asking for it gets a checkout of somebody else's
        # history — or, worse, a `git worktree add` that fails because the directory is
        # already a worktree of another repo, and a rebase that silently never happens.
        # Named for the checkout's own directory, which is unique by construction: two
        # repositories cannot share a path.
        scratch="$SPIRA_RUN/worktree/.rebase.$(basename "$repo")"
        if [ ! -e "$scratch/.git" ]; then
            mkdir -p "$(dirname "$scratch")"
            # Through the chokepoint: a bare prune here would silently unregister any tree
            # whose `.git` link is broken, including a live aeon's, and free its branch.
            spira_prune_worktrees "$repo" >/dev/null 2>&1
            git -C "$repo" worktree add -q --detach "$scratch" "$onto" >/dev/null 2>&1 \
                || return 1
        fi
        git -C "$scratch" checkout -q --detach >/dev/null 2>&1
        git -C "$scratch" checkout -q -B "$br" "refs/heads/$br" >/dev/null 2>&1 || return 1
        wt="$scratch"
    fi

    if ! git -C "$wt" diff --quiet HEAD 2>/dev/null; then
        # `reset --hard`, not `checkout -- .`: a file STAGED for addition is not restored by
        # checkout, and `git rebase` refuses outright on "your index contains uncommitted
        # changes". reset --hard clears index and tracked worktree together and leaves
        # untracked files exactly where they are.
        salvage "${br##*/}-prerebase" "$wt" >/dev/null
        git -C "$wt" reset -q --hard HEAD 2>/dev/null
    fi

    if ! git -C "$wt" rebase -q "$onto" >/dev/null 2>&1; then
        # Name the collisions BEFORE aborting; after the abort there is nothing to read.
        REBASE_CONFLICTS="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
        REBASE_CONFLICTS="${REBASE_CONFLICTS% }"
        git -C "$wt" rebase --abort >/dev/null 2>&1
        rc=1
    else
        # THE REBASE ACTUALLY REPLAYED COMMITS, so the tree is machine-produced and nobody
        # formatted it. This is the only path that reaches here: the already-an-ancestor case
        # returned above without touching anything, and a formatter run on a branch nothing
        # rewrote would be a diff the harness invented.
        format_rebased "$br" "$onto" "$wt" "$name"
    fi

    # Let go of the branch. A scratch tree still holding it is not inert: `git branch -D`
    # refuses a branch a worktree has checked out, which is exactly the defect sending.sh
    # exists to fix, and it would arrive here by a new route.
    if [ "$wt" = "${SPIRA_RUN}/worktree/.rebase.$(basename "$repo")" ]; then
        git -C "$wt" checkout -q --detach >/dev/null 2>&1
    fi
    return $rc
}

# --------------------------------------------------------------------------------------
# THE OWNERSHIP FENCE. An installation that imported a predecessor's databases holds
# thousands of beads that predecessor is still writing to. An aeon that claims one of them is
# racing a live worker, and both of them will do the work.
#
# `spira` is the ownership marker: measured, every native bead carried it and no imported one
# did. That makes it the one label a predicate can be
# REQUIRED to have — where `plan` or `incident` are each one persona's partition, `spira`
# is the boundary of the whole system. Until now the boundary held only because two config
# strings happened to be right, and a new fayth written without `spira` in FAYTH_LABELS
# would consume the replica with nothing objecting. Refuse instead.
#
# This is not an embargo that expires at cutover. After cutover an imported bead becomes
# Spira's by being LABELLED `spira`, one bead or one batch at a time and deliberately, so
# the fence goes on meaning "Spira owns this" rather than "not yet".
#
# The herestring is not a pipe: `grep -q` closing it early cannot SIGPIPE a writer, which
# is the trap law-no-grep-q-under-pipefail names.
# --------------------------------------------------------------------------------------
fayth_fenced() {         # fayth_fenced <name> <FAYTH_LABELS> -> 0 if it cannot see the replica
    local name="$1" labels="${2:-}"
    if [ -z "$labels" ]; then
        log "FENCE $name: FAYTH_LABELS is empty — that predicate selects the whole database,"
        log "FENCE $name: including every bead imported from a system still working them."
        return 1
    fi
    grep -qx 'spira' <<< "${labels//,/$'\n'}" && return 0
    log "FENCE $name: FAYTH_LABELS='$labels' does not require 'spira', so this predicate can"
    log "FENCE $name: select work another system still owns. Add 'spira' to it."
    return 1
}
