#!/usr/bin/env bash
#
# capacity.sh — the account's five-hour window: is it shut, and which attempts did it cost?
#
#   capacity.sh status              is a pause in force, and until when
#   capacity.sh scan                every session log whose session the account refused
#   capacity.sh reclassify          what would be given back (changes nothing)
#   capacity.sh reclassify --apply  give it back
#   capacity.sh pause <seconds>     shut the window by hand, for a drill or a known outage
#   capacity.sh resume              lift a pause early
#
# WHY RECLASSIFY IS EVIDENCE-DRIVEN AND NOT A LIST OF IDS
# ------------------------------------------------------
# An attempt charged for an outage is a false attempt and should be given back. The obvious
# way to do that is to name the beads that look worst and subtract — and it is wrong, because
# nothing in the count says WHY it was charged. This bead was filed naming six beads and
# ~177 attempts as capacity-caused on the strength of a `grep` for `429` and `503` in their
# logs; those strings are in the logs, in five-digit token counts (`cache_read_input_tokens`
# ending 429), and not one of them is an HTTP status. Subtracting on that reading would have
# handed attempts back to beads that genuinely failed, and un-poisoned work that is poisoned
# for good reason.
#
# So this reclassifies exactly what it can still SEE: a bead whose surviving session log
# ends in an account refusal gets one attempt back. It refuses to reason about the rest, and
# `scan` prints the same evidence so the refusal is checkable rather than asserted.
#
# THE HORIZON IS ONE ATTEMPT DEEP, and that is a property of the harness rather than of this
# script: aeon.sh truncates `$SPIRA_RUN/<id>.log` on every attempt, so only the last one
# survives. History before that attempt is gone and no amount of care here recovers it —
# which is why the fix that matters is the one in aeon.sh that stops charging the attempt in
# the first place, and this is only the cleanup behind it.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

CMD="${1:-status}"; shift 2>/dev/null || true
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

# Every bead whose surviving log shows the account refusing its session, with the epoch the
# window was said to reopen. Printed as "<id> <epoch>" so callers do not re-parse prose.
scan() {
    local f id at
    for f in "$SPIRA_RUN"/*.log; do
        [ -e "$f" ] || continue
        id="$(basename "$f" .log)"
        # The ledger and the harness's own logs live in this directory too and are not
        # session traces. A bead id is what aeon.sh names its log after; anything else here
        # belongs to some other writer.
        case "$id" in aeon-*|sentinel|landing|reflect|collector|beadtable|strands) continue ;; esac
        at="$(capacity_reset_at "$f")" || continue
        printf '%s %s\n' "$id" "$at"
    done
}

case "$CMD" in
status)
    if capacity_paused; then
        printf 'PAUSED  the account is out for another %ss (until %s), because of %s\n' \
            "$SPIRA_CAPACITY_LEFT" \
            "$(date -d "@$(capacity_pause_until)" +%H:%M 2>/dev/null)" \
            "$(capacity_pause_why 2>/dev/null || echo 'an unrecorded session')"
        exit 0
    fi
    printf 'OPEN    no capacity pause is in force\n'
    ;;

scan)
    n=0
    while read -r id at; do
        [ -n "${id:-}" ] || continue
        n=$((n+1))
        printf '%-22s refused, window reopened %s, attempts now %s\n' \
            "$id" "$(date -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" \
            "$(attempts_of "$id" 2>/dev/null || echo 0)"
    done <<< "$(scan)"
    # ZERO IS A CLAIM AND IT NEEDS A CONTROL. An empty scan and a scan pointed at the wrong
    # directory print the same nothing, so say which directory was read and how many session
    # logs were in it (law-absence-needs-a-positive-control).
    printf -- '--- %s session log(s) read from %s, %s refused\n' \
        "$(ls -1 "$SPIRA_RUN"/*.log 2>/dev/null | wc -l)" "$SPIRA_RUN" "$n"
    ;;

reclassify)
    n=0
    while read -r id at; do
        [ -n "${id:-}" ] || continue
        cur="$(attempts_of "$id")"; cur="${cur:-0}"
        [ "$cur" -gt 0 ] || continue
        n=$((n+1))
        if [ "$APPLY" = 1 ]; then
            # Remove the HIGHEST attempt label, because attempts_of reads the maximum: the
            # count is the top of the ladder, not the number of rungs, so taking the top rung
            # away is exactly what "one attempt back" means.
            bdq label remove "$id" "sp-attempt-$cur" >/dev/null 2>&1
            bdq note "$id" "Attempt $cur withdrawn: its session was refused by the account for want of capacity, not by anything about this work. Evidence: $SPIRA_RUN/$id.log ends in a rejected rate_limit_event." >/dev/null 2>&1
            # A bead poisoned only by that attempt is no longer poisoned. Its label goes with
            # it — leaving it would keep the bead out of every fayth's predicate for a
            # failure that was withdrawn, which is the whole harm this is undoing.
            if [ "$(( cur - 1 ))" -lt "${SPIRA_POISON_AT:-3}" ] \
               && bdq label list "$id" 2>/dev/null | grep -q spira-poison; then
                bdq label remove "$id" spira-poison >/dev/null 2>&1
                printf 'RESTORED %-20s attempt %s withdrawn, poison lifted\n' "$id" "$cur"
            else
                printf 'RESTORED %-20s attempt %s withdrawn\n' "$id" "$cur"
            fi
        else
            printf 'would restore %-20s attempt %s -> %s%s\n' "$id" "$cur" "$(( cur - 1 ))" \
                "$( [ "$(( cur - 1 ))" -lt "${SPIRA_POISON_AT:-3}" ] \
                    && bdq label list "$id" 2>/dev/null | grep -q spira-poison \
                    && printf ', poison would lift' )"
        fi
    done <<< "$(scan)"
    [ "$n" = 0 ] && printf 'nothing to reclassify — no surviving session log ends in an account refusal\n'
    [ "$APPLY" = 1 ] || printf -- '--- dry run; pass --apply to make these changes\n'
    ;;

pause)
    secs="${1:-900}"
    capacity_pause_set "$(( $(date +%s) + secs ))" "a pause set by hand"
    ;;

resume)
    rm -f "$SPIRA_CAPACITY_PAUSE"
    printf 'the pause is lifted\n'
    ;;

*) printf 'usage: capacity.sh [status|scan|reclassify [--apply]|pause <seconds>|resume]\n' >&2; exit 1 ;;
esac
