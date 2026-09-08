#!/usr/bin/env bash
#
# test-pilgrimage.sh — a completed pilgrimage announces itself as an EVENT.
#
#   ./test-pilgrimage.sh
#
# The announcement leg had no suite at all, which is how it spent a day writing the wrong
# kind of bead: `PILGRIMAGE COMPLETE — <id>: <title>` went out as `ask.sh insight`, and two
# of the eleven beads in the insights queue were outcomes wearing an insight's label
# (sp-94h, hq-5enm). An insight is what an agent LEARNED and might become law; an outcome is
# what HAPPENED. They are read by different people for different reasons and they now have
# different bins.
#
# So this is not a test of pilgrimage detection — `bd epic status` already answers that. It
# is a test of what the notice IS, end to end through the real ask.sh onto a real bd, and of
# the two properties that make it safe to emit at all: it is created CLOSED, and it carries
# no labels, so it can never be claimed by an aeon as work.
#
# EVERY CASE HAS ITS NEGATIVE. An epic with an open child must emit NOTHING, and the suite
# proves the check could have seen something by running the positive first — an assertion of
# absence from a probe that was never pointed at anything is indistinguishable from a pass
# (law-absence-needs-a-positive-control).
# covers: spira/pilgrimage.sh cockpit/ask.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
eq()     { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

. "$HERE/testdb.sh"
testdb_require test-pilgrimage
TMP="$(mktemp -d)"
testdb_up pilgrimage || { echo "testdb_up failed"; exit 1; }
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

DB="$SPIRA_DB"
BD="${TESTDB_BD:-bd}"
# COCKPIT_DB IS EXPORTED EXPLICITLY, never left to conf.sh's default. The operator's
# spira.conf may name COCKPIT_DB, and the environment is the only source that outranks it —
# without this line a suite on his box writes its fixtures into the live database.
export COCKPIT_DB="$DB"
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"

child() {   # child <id> <status> <parent>
    printf '{"id":"%s","title":"child %s","description":"d","status":"%s","issue_type":"task","labels":["spira","plan"],"dependencies":[{"issue_id":"%s","depends_on_id":"%s","type":"parent-child"}]}\n' \
        "$1" "$1" "$2" "$1" "$3"
}
events() { "$BD" -C "$DB" list --all --limit 0 -t event --json 2>/dev/null | sed -n '/^[[{]/,$p'; }
field()  { events | python3 -c 'import json,sys;r=json.load(sys.stdin);print((r[0] if r else {}).get(sys.argv[1]) or "")' "$1"; }
n_events() { events | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }
status_of() { "$BD" -C "$DB" show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d[0] if isinstance(d,list) else d).get("status") or "")'; }

run() { SPIRA_DB="$DB" SPIRA_NOTIFY="$HERE/../cockpit/ask.sh" "$HERE/pilgrimage.sh" check 2>&1; }

# ======================================================================================
echo "a complete pilgrimage — the notice is an event"

testdb_seed <<JSONL
{"id":"sp-done","title":"a finished pilgrimage","description":"d","status":"open","issue_type":"epic","labels":["spira","plan"]}
$(child sp-d1 closed sp-done)
$(child sp-d2 closed sp-done)
JSONL

out="$(run)"
want "the run announces it"        "PILGRIMAGE COMPLETE" "$out"
eq   "and wrote exactly one event" "1" "$(n_events)"
eq   "of kind pilgrimage.complete" "pilgrimage.complete" "$(field event_kind)"
# The epic id lives in `event_target`, not only spelled into the title, so a reader can
# filter the stream on the thing the outcome happened TO.
eq   "targeted at the epic"        "sp-done" "$(field target)"
want "titled with what happened"   "PILGRIMAGE COMPLETE — sp-done" "$(field title)"
want "and carrying which children closed" "sp-d1" "$(field description)"

# THE TWO PROPERTIES THAT MAKE IT SAFE TO EMIT. An OPEN event carrying the plan's labels is
# claimable by an aeon, which would put a completion notice in front of a worker as work.
eq "it is created closed" "closed" "$(field status)"
eq "carrying no labels at all" "[]" \
   "$(events | python3 -c 'import json,sys;r=json.load(sys.stdin);print(json.dumps((r[0] if r else {}).get("labels") or []))')"
labels="$(events | python3 -c 'import json,sys;r=json.load(sys.stdin);print(",".join((r[0] if r else {}).get("labels") or []))')"
# Not a grep over the row: `created_by` is `overseer` on everything this harness writes.
nowant "never labelled insight — that queue is for what was LEARNED" "insight" ",$labels,"
nowant "never labelled overseer — that label is what DECISIONS matches" "overseer" ",$labels,"

ready="$("$BD" -C "$DB" ready --limit 0 --exclude-type epic --label spira,plan \
          --exclude-label spira-poison,needs-ryan --json 2>/dev/null | sed -n '/^[[{]/,$p')"
nowant "the sentinel's ready predicate cannot see it" "$(field id)" "${ready:-[]}"

eq "and the epic itself is closed once the notice is out" "closed" "$(status_of sp-done)"

out="$(run)"
nowant "a second pass announces nothing — the marker holds" "PILGRIMAGE COMPLETE" "$out"
eq    "and writes no second event" "1" "$(n_events)"

# ======================================================================================
echo
echo "an unfinished pilgrimage — silence, from a check that just proved it can speak"

testdb_reset
testdb_seed <<JSONL
{"id":"sp-part","title":"still going","description":"d","status":"open","issue_type":"epic","labels":["spira","plan"]}
$(child sp-p1 closed sp-part)
$(child sp-p2 open   sp-part)
JSONL

out="$(run)"
nowant "no notice while a child is open" "PILGRIMAGE COMPLETE" "$out"
eq     "and no event"                    "0" "$(n_events)"
eq     "the epic stays open"             "open" "$(status_of sp-part)"

# ======================================================================================
echo
echo "an epic outside Spira's partition is not ours to announce"

testdb_reset
testdb_seed <<JSONL
{"id":"sp-alien","title":"someone else's epic","description":"d","status":"open","issue_type":"epic","labels":["repo:town"]}
$(child sp-a1 closed sp-alien)
JSONL
out="$(run)"
nowant "an epic without the spira label is skipped" "PILGRIMAGE COMPLETE" "$out"
eq     "and nothing is written about it"            "0" "$(n_events)"
eq     "it is left open for whoever owns it"        "open" "$(status_of sp-alien)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
