#!/usr/bin/env bash
#
# test-cockpit-db.sh — unanswered.sh ordering and the ask path, against a real bd.
#
#   ./test-cockpit-db.sh
#
# THE FAILURE THIS SUITE EXISTS FOR. unanswered.sh read rows[-1] positionally and never
# sorted. bd comments orders by created_at at second resolution, so two comments written
# in the same second come back in an order nothing defines. The turn marker inverted: a
# thread Ryan spoke last on read as answered and dropped off the "waiting on a reply" list,
# which is the exact failure that page exists to prevent. Observed 2026-09-06 in
# test-cockpit-dbs.sh (later deleted): a fixture that added my reply and his answer
# back-to-back produced identical created_at stamps and unanswered.sh reported "no threads
# are waiting on a reply". The suite worked around it with a sleep 2 — the tell that the
# ordering is the program's to establish and not the test's to arrange around.
#
# covers: cockpit/unanswered.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT="$(cd "$HERE/../cockpit" && pwd -P)"
. "$HERE/testdb.sh"
testdb_require test-cockpit-db
testdb_up cockpitdb || { echo "testdb_up failed"; exit 1; }

pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
eq()     { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

TMP="$(mktemp -d)"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

DB="$SPIRA_DB"
export COCKPIT_DB="$DB"
BD="${TESTDB_BD:-bd}"

bead() {   # bead <id> <labels-csv> <status> <description>
    printf '{"id":"%s","title":"t %s","description":"%s","status":"%s","issue_type":"task","labels":[%s],"updated_at":"2026-09-05T00:00:00Z"}\n' \
      "$1" "$1" "$4" "$3" "$(printf '"%s",' ${2//,/ } | sed 's/,$//')"
}

# ======================================================================================
echo "unanswered.sh — whose turn it is, on an order the program establishes"

# THE STAMPS ARE SEEDED, NOT TAKEN FROM THE CLOCK. `bd comments add` stamps from the clock
# at second resolution, so a same-second thread can only be produced by luck. A test that
# sleeps to avoid it proves the opposite of what is wanted — the ordering is the program's
# to establish, not the fixture's to arrange around. `bd import` carries created_at through
# verbatim, which makes every case below exact.
#
# And the tie really is undefined: seeded claude-then-ryan, `bd comments` returns sp-tie
# ryan-then-claude. Reading the positional last row called that thread answered and dropped
# it off this list, which is the failure this suite exists to catch.
comment() {  # comment <bead> <author> <stamp>
    printf '{"issue_id":"%s","author":"%s","text":"%s said at %s","created_at":"%s"},' \
        "$1" "$2" "$2" "$3" "$3"
}
convo() {    # convo <id> <comment-json...>  -> one import row
    printf '{"id":"%s","title":"t %s","description":"d","status":"open","issue_type":"task",' "$1" "$1"
    printf '"labels":["needs-ryan","overseer"],"updated_at":"2026-09-05T00:00:00Z","comments":[%s]}\n' "${2%,}"
}
testdb_seed <<EOF
$(convo sp-tie   "$(comment sp-tie   claude 2026-09-06T10:00:00Z)$(comment sp-tie   ryan   2026-09-06T10:00:00Z)")
$(convo sp-flip  "$(comment sp-flip  ryan   2026-09-06T10:00:00Z)$(comment sp-flip  claude 2026-09-06T10:00:00Z)")
$(convo sp-rev   "$(comment sp-rev   ryan   2026-09-06T12:00:00Z)$(comment sp-rev   claude 2026-09-06T09:00:00Z)")
$(convo sp-done2 "$(comment sp-done2 ryan   2026-09-06T09:00:00Z)$(comment sp-done2 claude 2026-09-06T12:00:00Z)")
EOF
out="$("$COCKPIT/unanswered.sh" 2>&1)"

# The tie resolves toward "he is owed a reply", in BOTH seeded orders, because neither
# order means anything. A thread wrongly listed costs a glance; a thread wrongly dropped
# is the multi-hour silence this file exists to end.
want "a same-second thread he is in still counts as waiting"        "sp-tie"  "$out"
want "and counts the same with the tie seeded the other way round"  "sp-flip" "$out"
# Sorted rather than positional: his comment is the newest by stamp but not last in the
# seeded array.
want "the newest comment is the newest by STAMP, not by position"   "sp-rev"  "$out"
# THE NEGATIVE CONTROL, and the one that matters most. Without it, "list every thread he
# has ever spoken on" passes all three assertions above — and that check can never read
# all-clear, which is the same reassuring lie in the other direction.
nowant "a thread answered strictly later is NOT waiting"            "sp-done2" "$out"
# stdout only: `--count` answers with a number, and folding stderr into it makes any
# warning from any layer read as a wrong count.
eq "so three of the four are waiting" "3" "$("$COCKPIT/unanswered.sh" --count 2>/dev/null)"

# COCKPIT_HUMAN is the knob that says whose voice counts as the ask. It resolves through
# $HUMAN in the exported environment, so `COCKPIT_HUMAN=claude` makes claude the asker
# and the default (ryan/operator) threads drop off.
out="$(COCKPIT_HUMAN=claude "$COCKPIT/unanswered.sh" 2>&1)"
want "COCKPIT_HUMAN reassigns whose turn it is" "sp-done2" "$out"
nowant "and takes the default's threads off the list" "sp-rev" "$out"

# ======================================================================================
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
