#!/usr/bin/env bash
#
# test-cockpit.sh — the cockpit's Spira metrics, seen firing against fixtures.
#
#   ./test-cockpit.sh
#
# A meter nobody has watched move is a hypothesis. Every case here is a log shape that
# actually occurred, or its negative — and the negatives carry the weight, because the
# expensive failure for a dashboard is not a missed number but a confident wrong one: a
# false-ACT counter that fires on healthy repetition trains everyone to ignore the panel,
# which is the same defect as a pager that cries wolf.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
METRICS="$HERE/cockpit-metrics.py"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"

# Emit one pass: a state line, then an ACT line per argument.
spass() {
    printf '%s spira: state: goal=sp-spira open=1 ready=0 in_progress=0 aeons=0\n' "$NOW"
    local a; for a in "$@"; do printf '%s spira: ACT %s\n' "$NOW" "$a"; done
}

# check <name> <key> <expected> -- <sentinel-log-text> <ledger-text>
check() {
    local name="$1" key="$2" want="$3"; shift 4
    printf '%s' "$1" > "$TMP/sentinel.log"
    printf '%s' "$2" > "$TMP/ledger.log"
    local got
    got="$(python3 "$METRICS" "$TMP/sentinel.log" "$TMP/ledger.log" 24 \
           | sed -n "s/^$key=//p")"
    if [ "$got" = "$want" ]; then
        pass=$((pass+1)); printf '  ok    %s\n' "$name"
    else
        fail=$((fail+1)); printf '  FAIL  %s: %s expected [%s] got [%s]\n' "$name" "$key" "$want" "$got"
    fi
}

echo "false ACTs — an action that had to be taken again two minutes later"

# The one that blinded CHECK 8: `git branch -D` cannot delete a branch a worktree holds,
# the error went to /dev/null, and the same branch was re-landed on the next pass.
check "re-landed branch is false" SP_FALSE_ACTS 1 -- \
    "$(spass 'landed spira/sp-stranded'; spass 'landed spira/sp-stranded')" ""

# The first version counted lines containing "reclaim", which also matched the idle
# message "No stale leases to reclaim in the filtered scope".
check "repeated reclaim is false" SP_FALSE_ACTS 1 -- \
    "$(spass 'reclaimed 1 stale lease(s)'; spass 'reclaimed 1 stale lease(s)')" ""

# NEGATIVES. Each of these is the system working, and counting it would make the meter
# useless in exactly the state it exists to describe.
check "distinct actions are not false" SP_FALSE_ACTS 0 -- \
    "$(spass 'landed spira/sp-a'; spass 'landed spira/sp-b')" ""

check "summoning every pass is not false" SP_FALSE_ACTS 0 -- \
    "$(spass 'summoned a builder aeon'; spass 'summoned a builder aeon')" ""

# A bead reopened, worked again by an aeon for an hour, and reopened again is two real
# actions. Only CONSECUTIVE repetition is evidence the first one did not take.
check "non-adjacent repeat is not false" SP_FALSE_ACTS 0 -- \
    "$(spass 'reopened sp-x — failed the gate'; spass; spass 'reopened sp-x — failed the gate')" ""

check "single pass cannot be false" SP_FALSE_ACTS 0 -- \
    "$(spass 'landed spira/sp-a')" ""

echo
echo "passes and the judgement tier"

check "passes counted by state lines" SP_PASSES 3 -- "$(spass; spass; spass)" ""

# CHECK 7 exits immediately after summoning and never logs `pass complete`, so a pass
# counter keyed on completion would undercount precisely the busy passes.
check "a pass that exited early still counts" SP_PASSES 2 -- \
    "$(spass 'summoned a builder aeon'; spass 'summoned a builder aeon')" ""

# Never fired with nothing ever starved is "n/a", not a count: the count read as a fault
# that was not there. A starved pass with no judgement is the alarm, and says NEVER.
check "never fired and never needed says n/a" SP_SINCE_JUDGEMENT 'n/a' -- "$(spass; spass)" ""
check "judgement fired two passes ago" SP_SINCE_JUDGEMENT 2 -- \
    "$(spass 'invoked reflection'; spass; spass)" ""
check "judgement fired this pass" SP_SINCE_JUDGEMENT 0 -- \
    "$(spass; spass 'invoked reflection')" ""

# Anything older than the window is not merely skipped: it must not leave a pass open for
# an in-window ACT to be compared against, or the boundary manufactures a false ACT.
check "out-of-window passes are excluded" SP_PASSES 1 -- \
    "$(printf '%s spira: state: x\n%s spira: ACT landed spira/sp-a\n' "$OLD" "$OLD"; spass 'landed spira/sp-a')" ""
check "out-of-window ACT is not a repeat" SP_FALSE_ACTS 0 -- \
    "$(printf '%s spira: state: x\n%s spira: ACT landed spira/sp-a\n' "$OLD" "$OLD"; spass 'landed spira/sp-a')" ""

echo
echo "aeons — born versus survived their first second"

# The scar: the sentinel's first aeon was killed inside the same second by the oneshot's
# cgroup teardown, after 1.6s of CPU, leaving an empty log while the sentinel reported
# "summoned" every two minutes. Born and not awake is that failure and no other.
check "born but never awake is stillborn" SP_AEON_STILLBORN 1 -- "" \
    "$(printf '%s born builder 123\n' "$NOW")"
check "born and awake is not stillborn" SP_AEON_STILLBORN 0 -- "" \
    "$(printf '%s born builder 123\n%s awake builder sp-x\n' "$NOW" "$NOW")"
check "an idle aeon lived but did not work" SP_AEON_WORKED 0 -- "" \
    "$(printf '%s born ops 1\n%s awake ops idle\n' "$NOW" "$NOW")"
check "an idle aeon still counts as lived" SP_AEON_LIVED 1 -- "" \
    "$(printf '%s born ops 1\n%s awake ops idle\n' "$NOW" "$NOW")"
check "a claim counts as worked" SP_AEON_WORKED 1 -- "" \
    "$(printf '%s born builder 1\n%s awake builder sp-x\n' "$NOW" "$NOW")"
check "stale ledger entries fall out of the window" SP_AEON_BORN 0 -- "" \
    "$(printf '%s born builder 1\n' "$OLD")"

echo
echo "a failed probe renders ? — never 0"

# The town collector's first version returned 0 from its exception handler, so a broken
# parser displayed as "no parked beads". A panel that reports a broken check as all-clear
# displaces the suspicion that would have prompted a look.
missing="$(python3 "$METRICS" "$TMP/nope.log" "$TMP/nope2.log" 24)"
for k in SP_PASSES SP_FALSE_ACTS SP_SINCE_JUDGEMENT SP_AEON_BORN SP_AEON_STILLBORN; do
    if [ "$(sed -n "s/^$k=//p" <<< "$missing")" = "?" ]; then
        pass=$((pass+1)); printf '  ok    missing input renders ? for %s\n' "$k"
    else
        fail=$((fail+1)); printf '  FAIL  missing input for %s: got [%s]\n' "$k" "$(sed -n "s/^$k=//p" <<< "$missing")"
    fi
done

# One half broken must not take the other half down with it.
printf '%s' "$(spass 'landed spira/sp-a')" > "$TMP/sentinel.log"
half="$(python3 "$METRICS" "$TMP/sentinel.log" "$TMP/nope2.log" 24)"
if [ "$(sed -n 's/^SP_PASSES=//p' <<< "$half")" = "1" ] \
   && [ "$(sed -n 's/^SP_AEON_BORN=//p' <<< "$half")" = "?" ]; then
    pass=$((pass+1)); printf '  ok    a broken ledger does not blank the sentinel metrics\n'
else
    fail=$((fail+1)); printf '  FAIL  one broken input took the other down\n'
fi

echo
echo 'every value is safe to source — the renderers have no parser'

# SCARRED: `SCHED_CAP=direct dispatch (scheduler.max_polecats=-1)` is a syntax error that
# aborts the source, so every key AFTER it silently read as unset and the whole panel
# rendered "?" while the collector looked healthy.
env_out="$(python3 "$METRICS" "$TMP/sentinel.log" "$TMP/nope2.log" 24)"
if ( set -u; eval "$(sed 's/=\(.*\)$/="\1"/' <<< "$env_out")" ) 2>/dev/null; then
    pass=$((pass+1)); printf '  ok    metrics output sources cleanly\n'
else
    fail=$((fail+1)); printf '  FAIL  metrics output cannot be sourced\n'
fi

echo
echo "the pane reads files and nothing else"

# A FENCE, not a behaviour. The pane repaints every two seconds; one `bd` or `gt` call in
# the render path freezes it for the several seconds that call takes, on every tick, and the
# only symptom is a dashboard that feels sluggish — which nobody files. It is one token to
# reintroduce and it fails quietly, so it is checked the same way test-rebase.sh checks that
# no program cuts a worktree from `main`.
#
# Comments are stripped first: this file's own prose names every command it forbids, and a
# fence that cannot survive being described is a fence nobody can document.
PANE="$HERE/../cockpit/health.sh"
if [ -f "$PANE" ]; then
    offenders="$(sed 's/#.*//' "$PANE" \
        | grep -nE '(^|[;|&]|\$\(|\(\ )[[:space:]]*(bd|gt|git|gh|systemctl)[[:space:]]' || true)"
    if [ -z "$offenders" ]; then
        pass=$((pass+1)); printf '  ok    health.sh shells out to no data source\n'
    else
        fail=$((fail+1)); printf '  FAIL  health.sh calls a data source directly:\n%s\n' "$offenders"
    fi
else
    fail=$((fail+1)); printf '  FAIL  cannot find the pane at %s\n' "$PANE"
fi

# And the fence must be able to fail. A guard nobody has watched refuse anything is a
# hypothesis; this is the same reasoning as the SEEN-RED rule for bug reproductions.
probe="$TMP/pane-probe.sh"
printf 'x=$(bd list --json)\n' > "$probe"
if sed 's/#.*//' "$probe" | grep -qE '(^|[;|&]|\$\(|\(\ )[[:space:]]*(bd|gt|git|gh|systemctl)[[:space:]]'; then
    pass=$((pass+1)); printf '  ok    the fence refuses a pane that calls bd\n'
else
    fail=$((fail+1)); printf '  FAIL  the fence does not catch a direct bd call\n'
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
