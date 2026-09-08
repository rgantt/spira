#!/usr/bin/env bash
#
# test-watchtower.sh — the pipeline's detector can read the far end of its own queue.
#
#   ./test-watchtower.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# The watchtower is the mechanism law-detection-outranks-rejection put in FRONT of the gate:
# it exists so a queue that has stopped moving is seen. Its headline field — minutes since
# the last landing — was structurally unreadable from the day it shipped, and rendered
# `?  (last: none recorded)` on every sweep ever filed, including passes where six beads had
# landed in the previous twelve minutes. Three Ops sessions were woken by it and all three
# closed with the same verdict: the pipeline is moving, the instrument lied.
#
# That is the failure mode a detector has and a gate does not. A gate that breaks refuses
# good work, loudly. A detector that breaks reports the stall and the healthy case
# IDENTICALLY, and the reassuring reading is the one it gives — which is why a suite for it
# earns its place beside the pipeline checks despite being neither a fence nor a soak.
#
# THE FIXTURE IS WRITTEN BY THE REAL WRITER (law-prefer-the-real-dependency). `land_mark` is
# lifted out of landing.sh and run, rather than its output being imitated here, because the
# whole defect lived in the seam between two programs' idea of the record format: the writer
# emits no trailing newline on purpose, and `read` reports EOF-without-delimiter as failure
# EVEN THOUGH IT HAS POPULATED EVERY VARIABLE. A hand-written fixture would reproduce
# whichever half of that seam the test author remembered.
#
# THE POSITIVE CONTROL COMES FIRST AND EVERYTHING AFTER IT IS READ THROUGH IT
# (law-absence-needs-a-positive-control). Before any claim that the reader works, this suite
# proves that the fixture still has the shape that broke it — that the record really ends
# without a newline, and that the OLD `read ... || continue` idiom really does discard it.
# Without that control, a writer someone "fixed" to append a newline would make every
# assertion below pass while the reader silently went back to being wrong on the real files.
#
# SPIRA_RUN AND SPIRA_WATCH_GATE_WINDOW ARE PINNED TO NON-DEFAULTS, and the program is run in
# an empty environment (law-gates-run-in-a-clean-environment). A suite that inherited a real
# spira.conf would assert against one box's landstate directory, and asserting against the
# shipped six-hour window would pass just as well if the code had the literal written in,
# which is the thing the key exists to prevent.
#
# covers: spira/watchtower.sh spira/landing.sh spira/cockpit.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-watchtower.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW="$(date +%s)"
GATE_WINDOW=3600         # deliberately not the shipped 21600

# The program under test, in an environment holding nothing but what it needs. `--show`
# gathers and prints and touches nothing, so nothing here can reach a database or file a bead.
wt() {                   # wt [VAR=val ...] -> the snapshot
    env -i PATH="$PATH" HOME="$TMP" \
        SPIRA_CONF=/nonexistent SPIRA_RUN="$TMP/run" \
        SPIRA_WATCH_GATE_WINDOW="$GATE_WINDOW" \
        "$@" bash "$HERE/watchtower.sh" --show 2>/dev/null
}
# THE LABEL IS MATCHED LITERALLY, never with a `.*`. The value is separated from the label
# by run of spaces, so a greedy wildcard in the label happily swallows the value too and
# every assertion below then reads the branch name and reports the wait as missing.
field() {                # field <snapshot> <label> -> the rest of that line
    printf '%s\n' "$1" | sed -n "s/^  $2  *//p" | head -1
}
gate_field() {           # gate_field <snapshot> [<window label>]
    field "$1" "longest gate wait, ${2:-last 1h}"
}
fresh() { rm -rf "$TMP/run"; mkdir -p "$TMP/run/landstate"; }

# ======================================================================================
echo
echo "the positive control — the fixture still has the shape that broke the reader:"
# ======================================================================================
# THE WRITER ITSELF, not a copy of what it emits. If landing.sh renames or reshapes
# `land_mark`, the extraction below finds nothing and this control fails — which is the
# report that is wanted, because every assertion after it would then be about a format no
# program writes any more.
fresh
LANDSTATE="$TMP/run/landstate"
eval "$(sed -n '/^land_mark() *{/,/^}/p' "$HERE/landing.sh")" 2>/dev/null
[ "$(type -t land_mark 2>/dev/null)" = function ] \
    && ok "landing.sh's land_mark could be lifted out and run" \
    || bad "landing.sh's land_mark could be lifted out and run" "no such function — the record format has moved"

if [ "$(type -t land_mark 2>/dev/null)" = function ]; then
    land_mark sp-ctl LANDED deadbeef spira
    is "the real writer produced a record" 1 "$(ls "$LANDSTATE" | wc -l)"

    # THE SEAM, STATED AS BYTES, and read through `od` rather than through a command
    # substitution: `$(...)` strips trailing newlines, so comparing its output is a test
    # that cannot tell the two cases apart — it passes either way, which is how the first
    # version of this control asserted the exact opposite of what it meant to.
    lastb="$(tail -c1 "$LANDSTATE/sp-ctl" | od -An -tx1 | tr -d ' \n')"
    [ "$lastb" != 0a ] && ok "the record ends WITHOUT a newline" \
        || bad "the record ends WITHOUT a newline" "the writer now terminates it — this fixture no longer reproduces the defect"

    # THE DEFECT, REPRODUCED. This is the idiom watchtower.sh used to carry, run verbatim
    # over the file the real writer just produced. It must find nothing — and if a later
    # change to the writer makes it find something, the control fails and says so rather
    # than letting the reader's tolerance go quietly untested.
    seen=0
    while IFS= read -r f; do
        read -r st _t _a _w < "$f" 2>/dev/null || continue
        [ "$st" = LANDED ] || continue
        seen=$((seen+1))
    done < <(find "$LANDSTATE" -maxdepth 1 -type f)
    is "the OLD 'read ... || continue' discards it" 0 "$seen"

    # And the same read, without the `|| continue`, has in fact populated every variable —
    # which is why tolerating the status is safe rather than reckless.
    st=""; at=""
    read -r st _t at _w < "$LANDSTATE/sp-ctl" 2>/dev/null || true
    is "the failed read had populated the state" LANDED "$st"
    case "$at" in ''|*[!0-9]*) bad "the failed read had populated the timestamp" "got [$at]" ;;
                  *) ok "the failed read had populated the timestamp" ;; esac
fi

# ======================================================================================
echo
echo "the landing field reads a real LANDED record:"
# ======================================================================================
fresh
land_mark sp-land LANDED cafe1 spira
touch -d "@$(( NOW - 600 ))" "$LANDSTATE/sp-land" 2>/dev/null
# 10 minutes ago, written through the real writer with a real timestamp: land_mark stamps
# `date +%s` itself, so the age asserted here is the age the program computes, not one the
# fixture chose.
snap="$(wt)"
line="$(field "$snap" 'minutes since the last landing')"
nowant "a LANDED record renders a number, not ?" "?" "$line"
want   "and names the bead that landed" "sp-land" "$line"

# ======================================================================================
echo
echo "a directory holding only RED records still renders ?, never 0:"
# ======================================================================================
# THE WHOLE POINT OF THE FIELD. "Nothing has landed" and "nothing landed in the last zero
# minutes" are opposite facts, and the second is the reassuring one.
fresh
land_mark sp-red1 RED cafe2 gate
land_mark sp-red2 RED cafe3 no-rebase
line="$(field "$(wt)" 'minutes since the last landing')"
want   "only RED renders ?" "?" "$line"
want   "and says so in words" "none recorded" "$line"
nowant "and does not name a RED bead" "sp-red1" "$line"

# ======================================================================================
echo
echo "an empty or malformed record is rejected without corrupting the running max:"
# ======================================================================================
# THE CONTAMINATION CASE. Because the reader no longer aborts the iteration on a failed
# `read`, the four variables must be reset before each one — otherwise an unreadable file is
# judged on the PREVIOUS file's state and one bead's landing is attributed to another. A
# directory is a set, so this plants enough offenders that find must hand at least one of
# them over after the good record whatever order it walks in.
fresh
land_mark sp-good LANDED cafe4 spira
: > "$LANDSTATE/sp-empty"
printf 'garbage' > "$LANDSTATE/sp-junk"
printf 'LANDED\n'  > "$LANDSTATE/sp-short"      # a state and nothing else
printf 'LANDED tip notanumber x' > "$LANDSTATE/sp-nan"
line="$(field "$(wt)" 'minutes since the last landing')"
want   "the good record is still found" "sp-good" "$line"
for junk in sp-empty sp-junk sp-short sp-nan; do
    nowant "$junk is not credited with a landing" "$junk" "$line"
done

fresh
: > "$LANDSTATE/sp-empty"
printf 'garbage' > "$LANDSTATE/sp-junk"
line="$(field "$(wt)" 'minutes since the last landing')"
want "a directory of nothing but junk renders ?" "?" "$line"

# ======================================================================================
echo
echo "the gate-wait field is bounded by TIME, not by a row count:"
# ======================================================================================
# WHY THIS IS NOT `tail -50`. gate.log holds one row per gate run, so on a quiet day fifty
# rows are a week and "recent" silently means "ever". The field spent a day reporting 1584s
# from a wait produced by a locking topology the gate rebuild had already deleted, while
# every row written since read `waited=0s`.
row() {                  # row <seconds-ago> <branch> <waited>
    printf '%s spira %s waited=%ss ran=1s rc=0\n' \
        "$(date -u -d "@$(( NOW - $1 ))" +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3"
}
fresh
{ row 90000 spira/sp-ancient 1584; row 600 spira/sp-recent 7; } > "$TMP/run/gate.log"
snap="$(wt)"
line="$(gate_field "$snap")"
want   "a row inside the window is reported" "7s" "$line"
want   "and names its branch" "sp-recent" "$line"
nowant "a row outside the window is not" "1584" "$line"
nowant "nor is its branch" "sp-ancient" "$line"
want   "the window is named in the field, not called 'recent'" "longest gate wait, last 1h" "$snap"

# THE MAX, not the last, among the rows that do qualify.
fresh
{ row 300 spira/sp-a 12; row 200 spira/sp-b 40; row 100 spira/sp-c 3; } > "$TMP/run/gate.log"
line="$(gate_field "$(wt)")"
want "the worst wait inside the window wins" "40s" "$line"
want "and it names that branch" "sp-b" "$line"

# NOTHING INSIDE THE WINDOW IS `?`, NOT 0. "No gate has waited recently" and "no gate has RUN
# recently" are opposite facts; the second is what a stalled pipeline looks like from here.
fresh
{ row 90000 spira/sp-ancient 1584; row 80000 spira/sp-older 900; } > "$TMP/run/gate.log"
line="$(gate_field "$(wt)")"
is     "no row inside the window renders ?" "?" "${line%% *}"
nowant "and never a bare zero" "0s" "$line"

# The window is genuinely read from configuration: the SAME log, a wider window, a different
# answer. Asserting only against one setting passes just as well if the bound is hardcoded.
line="$(gate_field "$(GATE_WINDOW=172800 wt SPIRA_WATCH_GATE_WINDOW=172800)" 'last 48h')"
want "a wider window reaches the older row" "1584s" "$line"

# A malformed first field is outside every window rather than inside all of them.
fresh
printf 'not-a-timestamp spira spira/sp-bad waited=999s ran=1s rc=0\n' > "$TMP/run/gate.log"
line="$(gate_field "$(wt)")"
is     "a row with no ISO timestamp is ignored" "?" "${line%% *}"
nowant "and its wait is not reported" "999" "$line"

# No log at all is unreadable, not quiet.
fresh
line="$(gate_field "$(wt)")"
is "a missing gate.log renders ?" "?" "${line%% *}"

# ======================================================================================
echo
echo "the strand ledger is reported by class, not by size:"
# ======================================================================================
# strands.json holds EVERY disposition strand.sh classifies — ghost, empty, starved, stuck,
# cycle — and only `ghost` is the labelled failure of a claimed bead whose holder is gone.
# The watchtower rendered the ledger's SIZE under that name, so a childless epic reported as
# a dead worker and a sweep spent four commands hunting for a holder that never existed.
#
# THE FIXTURE GOES THROUGH THE REAL COLLECTOR (law-prefer-the-real-dependency). The classifier
# under test is `cockpit.sh strands`, the same function probe calls, and its output IS the
# snapshot the renderer then reads — so the seam between the two programs is exercised rather
# than imagined. Writing a cockpit.env by hand here would assert against whichever key names
# the test author remembered, which is exactly the drift the split was made to stop.
ledger() {               # ledger <json> -> the collector's keys for that ledger
    mkdir -p "$TMP/run"
    printf '%s' "$1" > "$TMP/run/strands.json"
    env -i PATH="$PATH" HOME="$TMP" SPIRA_CONF=/nonexistent SPIRA_RUN="$TMP/run" \
        bash "$HERE/cockpit.sh" strands 2>/dev/null
}
key() {                  # key <keys> <name> -> its value
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}
render() {               # render <json> -> the watchtower snapshot over that ledger
    local keys; keys="$(ledger "$1")"
    printf '%s\n' "$keys" > "$TMP/run/cockpit.env"
    wt
}

# THE POSITIVE CONTROL FIRST: a ghost really is counted as a ghost, and reaches the pane. If
# this ever goes quiet, every assertion below is a matcher that finds nothing being read as
# a system with nothing wrong (law-absence-needs-a-positive-control).
k="$(ledger '{"spira,plan:ghost:sp-a":{},"spira,plan:ghost:sp-b":{}}')"
is "two ghosts count as two"        "2" "$(key "$k" SP_STRAND_GHOST)"
is "and nothing else is reported"   "none" "$(key "$k" SP_STRAND_OTHER)"
want "and the pane says so" "stranded (claimed, nobody home)     2" \
     "$(render '{"spira,plan:ghost:sp-a":{},"spira,plan:ghost:sp-b":{}}')"

# THE INCIDENT ITSELF. One childless epic: nobody claimed it, no lease expired, no worker
# died. The ledger has one entry and the ghost count is zero, and it is the zero that is the
# whole point — reverting the renderer to the ledger size fails here and nowhere else.
INCIDENT='{"spira,plan:empty:sp-jj88":{"first":1788811865,"acted":0,"escalated":1788812834}}'
k="$(ledger "$INCIDENT")"
is "an empty epic is not a ghost"   "0" "$(key "$k" SP_STRAND_GHOST)"
is "it is reported as its own class" "empty=1" "$(key "$k" SP_STRAND_OTHER)"
is "the ledger still has one entry"  "1" "$(key "$k" SP_STRANDS)"
snap="$(render "$INCIDENT")"
want "the pane reports no dead holder" "stranded (claimed, nobody home)     0" "$snap"
want "and names the class it does hold" "strand ledger, other classes        empty=1" "$snap"

# Every class is named and counted, ghost kept apart from the rest.
k="$(ledger '{"p:ghost:sp-a":{},"p:empty:sp-b":{},"p:empty:sp-c":{},"p:stuck:sp-d":{}}')"
is "ghosts are counted alone"       "1" "$(key "$k" SP_STRAND_GHOST)"
is "the other classes are itemised" "empty=2,stuck=1" "$(key "$k" SP_STRAND_OTHER)"

# THE KEY IS SPLIT FROM THE RIGHT. A partition is a label list and may carry a colon; an id
# may not. Splitting from the left reads the partition as the kind, and does it on precisely
# the entries hardest to reason about.
k="$(ledger '{"spira:plan,extra:ghost:sp-a":{}}')"
is "a partition containing a colon still classifies" "1" "$(key "$k" SP_STRAND_GHOST)"

# AN UNREADABLE ENTRY IS `?`, NEVER 0. The key that could not be classified may itself be a
# ghost, and a confident zero is the reading that stops anybody looking.
k="$(ledger '{"bogus":{},"p:ghost:sp-a":{}}')"
is   "an unclassifiable key makes the ghost count unknown" "?" "$(key "$k" SP_STRAND_GHOST)"
want "and is itself reported, not dropped" "unclassified=1" "$(key "$k" SP_STRAND_OTHER)"
is   "while the ledger size is still known" "2" "$(key "$k" SP_STRANDS)"

# A ledger that will not parse, and no ledger at all, are both unread rather than empty:
# strand.sh writes the file on its first pass, so its absence means the detector has not run.
k="$(ledger 'not json at all')"
is "an unparsable ledger renders ?" "?" "$(key "$k" SP_STRAND_GHOST)"
rm -f "$TMP/run/strands.json"
k="$(env -i PATH="$PATH" HOME="$TMP" SPIRA_CONF=/nonexistent SPIRA_RUN="$TMP/run" \
        bash "$HERE/cockpit.sh" strands 2>/dev/null)"
is "a missing ledger renders ?"     "?" "$(key "$k" SP_STRAND_GHOST)"

# A SNAPSHOT FROM A COLLECTOR PREDATING THE SPLIT RENDERS `?`. The two halves are briefly
# skewed during any rollout, and the pane must say it could not read the field rather than
# report a zero nobody measured.
fresh
printf "SP_STRANDS=7\n" > "$TMP/run/cockpit.env"
snap="$(wt)"
want "an old snapshot is unread, not clear" "stranded (claimed, nobody home)     ?" "$snap"
nowant "and its total is not shown as ghosts" "nobody home)     7" "$snap"
fresh

# ======================================================================================
echo
echo "the snapshot still renders as a whole:"
# ======================================================================================
# A CHEAP END-TO-END, because every assertion above reads one line out of a document that a
# `set -u` failure would truncate silently — leaving a `sed` that matches nothing and a
# handful of assertions that never ran.
fresh
land_mark sp-whole LANDED cafe5 spira
snap="$(wt)"
for section in 'The far end' 'The workers' 'The graph' 'The menu' 'Can this snapshot be believed'; do
    want "the snapshot still carries: $section" "$section" "$snap"
done
want "and still warns that ? is not a zero" "never treat it as a zero" "$snap"

# ======================================================================================
echo
echo "the sweep NAMES the scans rather than running them:"
# ======================================================================================
# THE DIVISION IS THE POINT AND IT IS LOAD-BEARING. A several-minute suite run inside this
# program would make the detector the thing that is down during an outage, and would push a
# ten-minute cadence past the interval that produces it. So the sweep carries the scan's NAME
# and the cheap figures that say whether it is worth a pass, and the Ops session spends its
# own budget on it. The name is asserted because a menu naming nothing is a scan that runs
# nowhere, which is the defect the runner was written to end.
want "the sweep names the timed suite run"      "suites.sh run" "$snap"
want "and says what the runner covers"          "the landing gate does NOT run" "$snap"
want "and carries its cheap figures, not its output" "suites in the tree" "$snap"
# It must not have RUN anything: `--show` touches nothing, and a suite executed here would
# have written a result under the scratch runtime directory.
is "and the sweep ran no suite of its own" "0" \
   "$(find "$TMP/run" -name '*.result' 2>/dev/null | wc -l)"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
