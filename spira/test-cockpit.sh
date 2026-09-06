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
# An aeon that declined because the ACCOUNT was out of capacity did not work, exactly as one
# that declined at the concurrency cap did not. Two unrelated conditions sharing the word
# "capacity" is most of why the account one went unhandled; counting `paused` as work would
# make the panel report peak throughput for the whole of an outage.
check "an aeon paused on the account did not work" SP_AEON_WORKED 0 -- "" \
    "$(printf '%s born builder 1\n%s awake builder paused\n' "$NOW" "$NOW")"
check "but it did live" SP_AEON_LIVED 1 -- "" \
    "$(printf '%s born builder 1\n%s awake builder paused\n' "$NOW" "$NOW")"
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
echo "the sections are sized to the pane, and none of them can be starved"

# THE PANE IS A FULL-HEIGHT COLUMN NOW, so the four sections that have more to say than fits
# — NOW, NEXT, RECENT, CI — are allocated rows rather than cut to one each. The expensive
# failure is not a missing row but a section that vanishes entirely while the pane still
# looks full: CI is the only place a run parked since yesterday appears, and it is the last
# section in the order, so a greedy allocator starves exactly the one nothing else reports.
PANE="$HERE/../cockpit/health.sh"
PD="$TMP/pane"; mkdir -p "$PD/repo/.runtime/spira" "$PD/home"
SNAPF="$PD/repo/.runtime/spira/cockpit.env"

# Written the way the collector writes it: every value SINGLE-QUOTED. `SP_NEXT0=P1 sp-a A
# title` unquoted is not an assignment, it is an assignment followed by a command, and the
# value arrives as one word with the rest run as a program.
snap() {
    python3 -c '
import sys
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    k, _, v = line.partition("=")
    print("%s=%s" % (k, "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27"))
' > "$SNAPF"
}

# An explicit minimal environment, and SPIRA_CONF pointed at a file that does not exist so
# no operator's spira.conf can decide a verdict here (law-gates-run-in-a-clean-environment).
# LC_ALL IS PASSED THROUGH, because the assertions count CHARACTERS and half the frame is
# multibyte. Without it the suite would measure bytes and disagree with the pane about what
# fits — and the pane would be right.
pane() {                 # pane <rows> [cols] -> the frame, ANSI stripped
    env -i PATH="$PATH" HOME="$PD/home" TERM=dumb LC_ALL=C.UTF-8 \
        SPIRA_CONF="$PD/no.conf" SPIRA_REPO="$PD/repo" SPIRA_RUN="$PD/repo/.runtime/spira" \
        bash "$PANE" once "$1" "${2:-0}" 2>/dev/null | sed 's/\x1b\[[?0-9;]*[a-zA-Z]//g'
}
rows_of() { printf '%s\n' "$1" | awk -v l=" $2" 'index($0,l)==1{n=1;next} n && /^ [A-Z]/{exit} n{n++} END{print n+0}'; }

if [ ! -f "$PANE" ]; then
    fail=$((fail+1)); printf '  FAIL  cannot find the pane at %s\n' "$PANE"
else
{
    printf 'SP_AEON_N=3\n'
    for i in 0 1 2; do
        printf 'SP_AEON%d_NAME=aeon%d\nSP_AEON%d_FAYTH=builder\nSP_AEON%d_BEAD=sp-w%d\n' "$i" "$i" "$i" "$i" "$i"
        printf 'SP_AEON%d_MIN=5\nSP_AEON%d_ACT=doing a thing\nSP_AEON%d_TITLE=A worked bead\n' "$i" "$i" "$i"
    done
    printf 'SP_NEXT_N=25\n'
    for i in $(seq 0 19); do printf 'SP_NEXT%d=P1 sp-n%d A queued bead\n' "$i" "$i"; done
    for i in $(seq 0 19); do printf 'SP_EVENT%d=%dm ago landed spira/sp-e%d\n' "$i" "$i" "$i"; done
    printf 'SP_AWAITING_N=20\nSP_AWAITING_OLDEST=sp-c0\nSP_AWAITING_AGE=9h\n'
    for i in $(seq 0 19); do printf 'SP_AWAITING%d=sp-c%d 9h A parked bead\n' "$i" "$i"; done
} | snap

# THE POSITIVE CONTROL FOR THE ONE BELOW IT. NOW can show nine rows here and must not be
# given all nine at this height — if it were, there would be no contention and "CI survived"
# would be passing for the wrong reason.
busy="$(pane 20)"
n_now="$(rows_of "$busy" NOW)"
if [ "$n_now" -ge 1 ] && [ "$n_now" -lt 9 ]; then
    pass=$((pass+1)); printf '  ok    a nine-row NOW is held to %s rows in a 20-row pane\n' "$n_now"
else
    fail=$((fail+1)); printf '  FAIL  NOW took %s of its 9 rows — nothing was rationed\n' "$n_now"
fi
if grep -q '^ CI ' <<< "$busy"; then
    pass=$((pass+1)); printf '  ok    and CI still has its row\n'
else
    fail=$((fail+1)); printf '  FAIL  CI was starved out of a 20-row pane:\n%s\n' "$busy"
fi
is_n() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL  %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
is_n "a 20-row pane is filled to exactly 20 rows" 20 "$(printf '%s\n' "$busy" | wc -l)"

# EVERY SECTION KEEPS ITS FIRST ROW. Four sections and nine standing lines do not fit in
# thirteen once the header is counted, and what must NOT happen is a section being allocated
# zero rows: that is a section vanishing with nothing on screen saying it did.
tight="$(pane 13)"
missing=""
for l in NOW NEXT RECENT CI; do grep -q "^ $l " <<< "$tight" || missing="$missing $l"; done
is_n "every section survives a 13-row pane" "" "$missing"

# ...and in a pane too short even for that, the overflow is MARKED. A dashboard that hides
# its own content without saying so is the failure it exists to prevent.
short="$(pane 5)"
is_n "a 5-row pane shows 5 rows" 5 "$(printf '%s\n' "$short" | wc -l)"
case "$short" in *▾*) pass=$((pass+1)); printf '  ok    and marks the dropped lines on the header\n' ;;
    *) fail=$((fail+1)); printf '  FAIL  5-row pane dropped lines silently:\n%s\n' "$short" ;; esac

# GROWTH IS CAPPED, AND THE CAP IS IN LINES. A section that keeps growing stops being a
# glance and becomes a list, which is what `bd ready` is for. Twenty lines of NEXT is its
# own header plus nineteen beads — the header is a line like any other.
tall="$(pane 200)"
is_n "NEXT grows to its cap and no further" 20 "$(rows_of "$tall" NEXT)"
case "$tall" in *"sp-n18"*) pass=$((pass+1)); printf '  ok    a tall pane shows far more than the old single row\n' ;;
    *) fail=$((fail+1)); printf '  FAIL  a tall pane still shows only the head of the queue\n' ;; esac
# And the cap must be SEEN biting, or "20" is a number nobody has watched refuse anything.
case "$tall" in *"sp-n19"*) fail=$((fail+1)); printf '  FAIL  the 20-line cap did not hold\n' ;;
    *) pass=$((pass+1)); printf '  ok    and stops there — the 21st line is refused\n' ;; esac

# THE COLUMN IS NARROWER THAN THE QUADRANT IT REPLACED — a third of the window rather than
# half — so fitting the pane is a question about width as well as height. Autowrap is off,
# which means the terminal CUTS a long line rather than folding it, and the terminal's cut is
# silent: exactly the failure the dropped-row marker on the header exists to prevent, arriving
# by the other axis.
{
    printf 'SP_AEON_N=0\nSP_NEXT_N=3\n'
    printf 'SP_NEXT0=P1 sp-longtitle %s\n' "$(printf 'x%.0s' $(seq 1 120))"
    printf 'SP_NEXT1=P1 sp-short A short one\n'
    printf 'SP_EVENT0=2m ago %s\n' "$(printf 'y%.0s' $(seq 1 120))"
    printf 'SP_AWAITING_N=1\nSP_AWAITING_OLDEST=sp-p\nSP_AWAITING_AGE=1h\n'
    printf 'SP_AWAITING0=sp-p 1h %s\n' "$(printf 'z%.0s' $(seq 1 120))"
} | snap
# MEASURED IN CHARACTERS, WITH PYTHON, NOT WITH awk. The frame is full of multibyte
# characters and a suite run from a gate inherits the C locale, where awk counts BYTES — the
# ellipsis this very case is checking for is three bytes and one column, so the assertion
# would fail by exactly two on every line it cut, and blame the pane.
cols_of() { python3 -c '
import sys
print(max([len(l) for l in sys.stdin.read().splitlines()] or [0]))'; }
find_len() { python3 -c '
import sys
for l in sys.stdin.read().splitlines():
    if sys.argv[1] in l:
        print(len(l)); break
else:
    print(0)' "$1"; }

narrow="$(pane 40 70)"
widest="$(printf '%s\n' "$narrow" | cols_of)"
if [ "$widest" -le 70 ]; then
    pass=$((pass+1)); printf '  ok    nothing overflows a 70-column pane (widest %s)\n' "$widest"
else
    fail=$((fail+1)); printf '  FAIL  a row ran to %s columns in a 70-column pane\n' "$widest"
fi
case "$narrow" in *…*) pass=$((pass+1)); printf '  ok    and a cut line is marked with an ellipsis\n' ;;
    *) fail=$((fail+1)); printf '  FAIL  a 120-character title was cut silently:\n%s\n' "$narrow" ;; esac
# THE POSITIVE CONTROL. A frame wide enough for everything must carry NO marker, or the one
# above proves nothing — an ellipsis that is always present says nothing about the cut.
wide="$(pane 40 200)"
case "$wide" in *…*) fail=$((fail+1)); printf '  FAIL  a 200-column pane still marked a cut:\n%s\n' "$wide" ;;
    *) pass=$((pass+1)); printf '  ok    and a pane wide enough for the row marks nothing\n' ;; esac
# The width must come from the pane, not from a number written into the renderer: the same
# row has to be longer when there is more room for it.
w70="$(printf '%s\n' "$narrow" | find_len sp-longtitle)"
w200="$(printf '%s\n' "$wide" | find_len sp-longtitle)"
if [ "${w70:-0}" -gt 0 ] && [ "${w200:-0}" -gt "${w70:-0}" ]; then
    pass=$((pass+1)); printf '  ok    the same row is %s columns at 70 and %s at 200\n' "$w70" "$w200"
else
    fail=$((fail+1)); printf '  FAIL  the row did not grow with the pane: 70->[%s] 200->[%s]\n' "$w70" "$w200"
fi

# ABSENCE AND A FAILED READ ARE NOT THE SAME PIXELS (law-absence-needs-a-positive-control).
# These two snapshots differ by three values, and rendering the second as the first is the
# all-clear a broken check must never be able to produce.
printf 'SP_AEON_N=0\nSP_NEXT_N=0\nSP_AWAITING_N=0\n' | snap
idle="$(pane 0)"
for want in 'no aeon working' 'nothing to claim' 'nothing parked on CI'; do
    if grep -qF "$want" <<< "$idle"; then
        pass=$((pass+1)); printf '  ok    idle says "%s"\n' "$want"
    else
        fail=$((fail+1)); printf '  FAIL  idle did not say "%s":\n%s\n' "$want" "$idle"
    fi
done
printf 'SP_AEON_N=?\nSP_NEXT_N=?\nSP_AWAITING_N=?\n' | snap
broke="$(pane 0)"
for l in NOW NEXT CI; do
    if grep -qE "^ $l +\? " <<< "$broke"; then
        pass=$((pass+1)); printf '  ok    a failed probe renders %s as ? and not as idle\n' "$l"
    else
        fail=$((fail+1)); printf '  FAIL  %s reported a broken read as all-clear:\n%s\n' "$l" "$broke"
    fi
done
# The same absence with no snapshot AT ALL — the case the file's own existence answers.
rm -f "$SNAPF"
none="$(pane 0)"
if grep -qE '^ RECENT +\? ' <<< "$none"; then
    pass=$((pass+1)); printf '  ok    a missing snapshot renders RECENT as ?, not as an empty log\n'
else
    fail=$((fail+1)); printf '  FAIL  a missing snapshot read as "nothing happened":\n%s\n' "$none"
fi
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
