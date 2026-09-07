#!/usr/bin/env bash
#
# attempts.sh — read and repair the two counters that decide whether a bead is retried.
#
#   attempts.sh audit                  what every claimable bead is carrying, and why
#   attempts.sh reclassify [--apply]   move rungs that name no cause onto the reclaim counter
#
# WHY THIS EXISTS. The attempt counter feeds the poison threshold, and poison takes a bead
# out of circulation permanently. It was default-ALLOW — anything a short list of exemptions
# did not positively excuse was charged as a failure of the WORK — so it recorded worker
# deaths, rate-limit refusals and a worktree deleted under a live aeon as evidence about
# beads nobody had looked at. Counts in the tens accumulated against a threshold of three.
#
# The rule is now default-DENY, and a rung records the outcome that charged it (lib.sh,
# session_outcome / outcome_charges). This tool applies the same rule BACKWARDS: a rung
# carrying no cause predates the requirement to name one, and an unnamed rung is not
# evidence. That is not an amnesty, it is the same statute read in the only direction it can
# be read — UNKNOWN does not charge.
#
# WHAT IT WILL NOT DO IS LIFT A POISON. Clearing a false COUNT is arithmetic and needs
# nobody's permission; re-queueing a bead the operator has an open decision about is a
# different act, and a repair tool must not take it silently. The label is left exactly where
# it is and the audit says so, which is what lets an operator lift it deliberately.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

APPLY=0
CMD="${1:-audit}"; shift 2>/dev/null || true
for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done

# EVERY BEAD A PERSONA COULD CLAIM, not the goal epic's children: fences bind on a partition's
# labels and not on ancestry, which is the asymmetry that let large counts accumulate unseen.
#
# The partitions come from the chamber rather than from a literal here, so this tool and the
# summoner cannot come to disagree about which beads are ours. Their EXCLUSIONS are
# deliberately dropped: a poisoned bead is excluded from dispatch and is exactly the bead
# whose count most needs reading, so filtering it out here would hide the evidence.
#
# `--limit 0` because `bd list` silently truncates at 50, which would restore the very defect
# this set exists to close, with a different boundary.
candidates() {
    local labels exclude
    while IFS=$'\t' read -r labels exclude; do
        [ -n "$labels" ] || continue
        bdjson list --status open,in_progress --limit 0 --label "$labels" 2>/dev/null \
            | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d,list) else [d]): print(i["id"])' 2>/dev/null
    done < <(fayth_partitions)
    return 0
}
uniq_candidates() { candidates | awk 'NF && !seen[$0]++'; }

# Read the labels once and match a herestring: piping into `grep -q` closes the pipe on the
# first match and SIGPIPEs the writer, which pipefail reports as failure — so the test would
# read FALSE exactly when it succeeded (law-no-grep-q-under-pipefail).
poisoned() { local l; l="$(bdq label list "$1" 2>/dev/null)" || l=""; grep -q spira-poison <<<"$l"; }

case "$CMD" in
audit)
    n=0; total=0
    for id in $(uniq_candidates); do
        total=$((total+1))
        a="$(attempts_of "$id")"; a="${a:-0}"
        r="$(reclaims_of "$id")"; r="${r:-0}"
        [ "$a" != 0 ] || [ "$r" != 0 ] || continue
        n=$((n+1))
        printf '%-20s attempts=%-3s reclaims=%-3s %s\n' "$id" "$a" "$r" \
            "$(poisoned "$id" && echo POISONED || echo '')"
        counter_causes "$id" sp-attempt | sed 's/^/    attempt /'
        counter_causes "$id" sp-reclaim | sed 's/^/    reclaim /'
    done
    # ZERO IS A CLAIM AND IT NEEDS A CONTROL. "No bead carries a counter" and "the query
    # returned nothing" print the same nothing, and the second reads as all-clear
    # (law-absence-needs-a-positive-control). The denominator is what tells them apart.
    printf -- '--- %s bead(s) carrying counters, of %s claimable\n' "$n" "$total"
    ;;

reclassify)
    n=0
    for id in $(uniq_candidates); do
        keep=""; drop=0
        while read -r rung cause; do
            [ -n "${rung:-}" ] || continue
            if [ "$cause" = unrecorded ]; then drop=$((drop+1)); else keep="$keep $cause"; fi
        done <<< "$(counter_causes "$id" sp-attempt)"
        [ "$drop" -gt 0 ] || continue
        n=$((n+1))
        was="$(attempts_of "$id")"; was="${was:-0}"
        now="$(printf '%s' "$keep" | wc -w)"
        if [ "$APPLY" != 1 ]; then
            printf 'would reclassify %-20s attempts %s -> %s, %s rung(s) onto the reclaim counter%s\n' \
                "$id" "$was" "$now" "$drop" \
                "$(poisoned "$id" && printf ' (POISONED — the label is left alone)')"
            continue
        fi
        # THE LADDER IS ITS TOP RUNG, NOT ITS RUNG COUNT: attempts_of reads the maximum, so
        # removing a rung from the middle would leave a gap that still reads as the old
        # number and the withdrawal would be invisible in the one number the threshold
        # consults. Every attempt rung comes off and the survivors go back on renumbered.
        while read -r rung cause; do
            [ -n "${rung:-}" ] || continue
            lbl="$(counter_label "$id" sp-attempt "$rung")" || lbl="sp-attempt-$rung"
            bdq label remove "$id" "$lbl" >/dev/null 2>&1
        done <<< "$(counter_causes "$id" sp-attempt)"
        i=0
        for cause in $keep; do i=$((i+1)); bdq label add "$id" "sp-attempt-$i-$cause" >/dev/null 2>&1; done
        j=0
        while [ "$j" -lt "$drop" ]; do j=$((j+1)); bump_reclaim "$id" unrecorded >/dev/null; done
        bdq note "$id" "Attempt counter reclassified: $drop of $was rung(s) named no outcome, so they were moved onto the reclaim counter and no longer feed poison. A rung that does not say what the work did wrong is not evidence that the work is wrong — it predates the rule that a charge must name its cause, and the large counts on this board were accumulated by dead heartbeats, rate-limit refusals and worktrees deleted under live aeons. Attempts now $now." >/dev/null 2>&1
        printf 'RECLASSIFIED %-20s attempts %s -> %s, %s onto reclaim%s\n' "$id" "$was" "$now" "$drop" \
            "$(poisoned "$id" && printf ' (still POISONED — the label is the operator'\''s to lift)')"
    done
    [ "$n" = 0 ] && printf 'nothing to reclassify — every attempt rung on the board names its cause\n'
    [ "$APPLY" = 1 ] || printf -- '--- dry run; pass --apply to make these changes\n'
    ;;

*) die "usage: attempts.sh audit | reclassify [--apply]" ;;
esac
