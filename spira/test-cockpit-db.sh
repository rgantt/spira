#!/usr/bin/env bash
#
# test-cockpit-db.sh — the ask path against ONE database, on a real `bd`.
#
#   ./test-cockpit-db.sh
#
# It replaces test-cockpit-dbs.sh, which was 34 assertions about precedence between two
# databases: which one wins when both hold an id, that a town ask closes in the town, that
# the Spira replica is dropped. There is one database now (the operator's call), so every
# one of those questions is unaskable and the suite failed 12 of 34 by design — blocking
# every brain branch that touched .claude/cockpit/ or .claude/spira/, because gate-brain.sh
# runs every test-*.sh in this directory.
#
# What replaces them is not the same question with one database. It is the two properties a
# single database still has to hold, and neither is trivially true:
#
#   IT REFUSES RATHER THAN GUESSES. The failure mode of the old walk was never "no database
#   found" — it was addressing the WRONG one and exiting 0. So a missing `.beads` must stop
#   the tool, and must not fall back to the town.
#
#   UNREACHABLE IS NOT EMPTY. With a walk, one dead database left the others; with one, a
#   Dolt hiccup is the whole queue. A caller that renders "nothing is waiting" because the
#   fetch failed is a panel reporting a broken check as all-clear, which displaces the
#   suspicion that would have prompted a look (law-alerts-must-be-actionable).
#
# And a fence, because the deleted machinery is cheap to reintroduce one line at a time: no
# cockpit program may name a second beads database, and no row may carry a `_db` tag.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT="$HERE/../cockpit"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
eq()     { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ======================================================================================
# THE FENCE runs first and without a database, so a reintroduced walk is reported even on a
# box where Dolt is down and everything below skips.
# ======================================================================================
echo "the fence — one database, named in one place"

# THE FENCE IS AGAINST A LITERAL PATH, not against one particular database. It used to name
# the predecessor town, which meant it could only catch the one wrong database anybody had
# thought of — and it named a path that exists on exactly one box. Any absolute path written
# into a `bd -C` is the defect: the database is COCKPIT_DB and comes from the configuration.
#
# Comments are stripped: this file and db.sh both describe the machinery they forbid, and a
# fence that cannot survive being documented is a fence nobody documents.
LITERAL_DB='bd .*-C[[:space:]]*/'
offenders="$(for f in "$COCKPIT"/*.sh "$HERE/../tasks.sh"; do
    [ -f "$f" ] || continue
    sed 's/#.*//' "$f" | grep -nH --label="$(basename "$f")" -E "$LITERAL_DB" || true
done)"
[ -z "$offenders" ] && ok "no cockpit shell tool names a database by literal path" \
                    || bad "a cockpit shell tool names a database by literal path" "$offenders"

offenders="$(grep -rn -e cockpit_dbs -e cockpit_beads_json -e cockpit_db_for -e merge-beads \
    "$COCKPIT" "$HERE/../tasks.sh" 2>/dev/null || true)"
[ -z "$offenders" ] && ok "the multi-database API is gone, not merely unused" \
                    || bad "the multi-database API survives" "$offenders"

# `_db` was the row tag that let a merged fetch remember which database a bead came from. It
# is the tell that a walk is back: nothing else needs it, in a program or in a fixture. The
# pattern carries its closing quote because the tag is always a JSON key — `_db` alone also
# matches `cockpit_db`, which is the function that replaced the walk.
offenders="$(grep -rn '_db"' "$COCKPIT" "$HERE/../tasks.sh" 2>/dev/null || true)"
[ -z "$offenders" ] && ok "no row carries a _db tag" || bad "a _db tag survives" "$offenders"

# AND EACH FENCE MUST BE ABLE TO REFUSE. A guard nobody has watched turn anything away is a
# hypothesis — the same reasoning as the SEEN-RED rule for bug reproductions, and the reason
# these three are the cheapest checks here to get subtly wrong: `_db` alone matches
# `cockpit_db`, and a walk restored one line at a time reads as ordinary code.
PROBE="$(mktemp -d)"
printf 'x=$(bd -C /some/other/db list --json)\n' > "$PROBE/walk.sh"
printf 'db=$(cockpit_dbs); r["_db"] = db\n'      > "$PROBE/tag.py"
sed 's/#.*//' "$PROBE/walk.sh" | grep -qE "$LITERAL_DB" \
    && ok "the fence refuses a tool that reads the town" \
    || bad "the fence refuses a tool that reads the town" "it did not match"
grep -rq -e cockpit_dbs -e cockpit_beads_json -e cockpit_db_for -e merge-beads "$PROBE" \
    && ok "the fence refuses the restored walk API" \
    || bad "the fence refuses the restored walk API" "it did not match"
grep -rq '_db"' "$PROBE" \
    && ok "the fence refuses a restored _db tag" \
    || bad "the fence refuses a restored _db tag" "it did not match"
# ...and does not fire on the function that REPLACED the walk, which contains the substring.
printf 'db=$(cockpit_db) || exit 1\n' > "$PROBE/ok.sh"
grep -q '_db"' "$PROBE/ok.sh" \
    && bad "the _db fence does not fire on cockpit_db" "it matched cockpit_db" \
    || ok "the _db fence does not fire on cockpit_db"
rm -rf "$PROBE"

# ======================================================================================
echo
echo "cockpit_db — the answer, or a refusal"

# Sourced in a subshell each time: db.sh resolves COCKPIT_DB once, at source time.
# Explicit assignments, not a prefix on `.`: a temporary assignment before the source
# builtin does not survive into the sourced file's own expansion of the same name, so
# `COCKPIT_DB=x . db.sh` reads as empty and every case here would pass for the wrong reason.
cdb() { ( set +u; export COCKPIT_DB="$1" SPIRA_DB=""; . "$COCKPIT/db.sh"; cockpit_db ) 2>&1; }
cdb_rc() { ( set +u; export COCKPIT_DB="$1" SPIRA_DB=""; . "$COCKPIT/db.sh"; cockpit_db >/dev/null 2>&1 ); printf '%s' "$?"; }

TMP="$(mktemp -d)"
NODB="$TMP/not-a-database"; mkdir -p "$NODB"
HASDB="$TMP/looks-like-one"; mkdir -p "$HASDB/.beads"

eq "a database with .beads is the answer" "$HASDB" "$(cdb "$HASDB")"
eq "a directory without .beads is refused" "1" "$(cdb_rc "$NODB")"
want "the refusal says what it refused" "refusing to guess" "$(cdb "$NODB")"
# The whole point. The old walk's failure was silently addressing another database.
nowant "a refusal never falls back to another database" "/some/other/db" "$(cdb "$NODB")"

# ======================================================================================
# Everything past here needs a real bd. The database is a throwaway on Spira's own server.
# ======================================================================================
. "$HERE/testdb.sh"
testdb_require test-cockpit-db
testdb_up cockpitdb || { echo "testdb_up failed"; exit 1; }
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

DB="$SPIRA_DB"
export COCKPIT_DB="$DB"
# THE ESCALATION LABEL IS PINNED TO A NON-DEFAULT VALUE HERE ON PURPOSE. Asserting against
# the shipped default would pass just as well if the code had the literal written in, which
# is the thing this key exists to stop; a distinctive value fails the moment one does.
export SPIRA_ASK_LABEL=needs-a-human
BD="${TESTDB_BD:-bd}"
bead() {   # bead <id> <labels-csv> <status> <description>
    printf '{"id":"%s","title":"t %s","description":"%s","status":"%s","issue_type":"task","labels":[%s],"updated_at":"2026-09-05T00:00:00Z"}\n' \
      "$1" "$1" "$4" "$3" "$(printf '"%s",' ${2//,/ } | sed 's/,$//')"
}

echo
echo "cockpit_beads — every bead, and a failure that reads as one"

testdb_seed <<EOF
$(bead sp-open   "$SPIRA_ASK_LABEL,overseer" open   "an ask")
$(bead sp-shut   insight,overseer    closed "a record")
EOF

beads() { ( . "$COCKPIT/db.sh"; cockpit_beads ); }
raw="$(beads)"
n="$(printf '%s' "$raw" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d if isinstance(d,list) else d.get("issues",[])))' 2>/dev/null)"
eq "both beads are returned" "2" "$n"
# --all is load-bearing: an insight is CREATED closed, and `bd list` hides closed issues.
want "a closed insight is included" "sp-shut" "$raw"
nowant "no row is tagged with a database" '"_db"' "$raw"

DEAD="$(testdb_unreachable)"
out="$( COCKPIT_DB="$DEAD" bash -c '. "'"$COCKPIT"'/db.sh"; cockpit_beads' 2>/dev/null )"; rc=$?
[ "$rc" -ne 0 ] && ok "an unreachable database is an error, not an empty queue" \
                || bad "an unreachable database is an error, not an empty queue" \
                       "exited 0 with [$out]"

# ======================================================================================
echo
echo "the ask path — raised, answered and closed in that one database"

out="$("$COCKPIT/reply.sh" sp-open "a reply" 2>&1)"
want "reply.sh reports the database it wrote to" "$(basename "$DB")" "$out"
thread="$("$BD" -C "$DB" comments sp-open --json 2>/dev/null | sed -n '/^[[{]/,$p')"
want "the comment landed in it" "a reply" "$thread"
# Authorship is what lets the watcher tell my own reply from the operator's; announcing mine
# back to me as though they had commented is a notification loop with itself.
want "the comment is authored claude" '"claude"' "$thread"

# the operator speaks last, so the thread is an open obligation whatever the bead's status says.
# The sleep is load-bearing: `bd comments` orders by `created_at`, which is second-resolution,
# so two comments added in the same second come back in an order nothing defines — and "whose
# turn is it" is read off the end of that list.
sleep 2
# THE OPERATOR'S ACTOR NAME COMES FROM THE CONFIGURATION, not from a literal. unanswered.sh
# compares the last author against SPIRA_OPERATOR_ACTOR, so a fixture writing a hardcoded name
# tests one installation's value and fails everywhere else — the same defect as a test that
# hardcodes a default (law-gates-run-in-a-clean-environment).
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" comments add sp-open "and their answer" >/dev/null 2>&1
out="$("$COCKPIT/unanswered.sh" 2>&1)"
want "unanswered.sh sees the thread they spoke last on" "sp-open" "$out"
eq "and counts it once, not once per database" "1" "$("$COCKPIT/unanswered.sh" --count 2>&1)"

out="$(SELF_CLOSED="$TMP/self-closed" "$COCKPIT/resolve.sh" sp-open "done — evidence here" 2>&1)"
want "resolve.sh closes in it" "resolved sp-open" "$out"
eq "the bead is closed" "closed" \
   "$("$BD" -C "$DB" show sp-open --json 2>/dev/null | sed -n '/^[[{]/,$p' \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d[0] if isinstance(d,list) else d).get("status",""))' 2>/dev/null)"
want "and records the id so the watcher does not page them about my own close" \
     "sp-open" "$(cat "$TMP/self-closed" 2>/dev/null)"

# ======================================================================================
echo
echo "verify-asks.sh — an operator ask that proves itself"

testdb_reset
testdb_seed <<EOF
$(bead sp-done "$SPIRA_ASK_LABEL,overseer" open "VERIFY: echo the-evidence")
$(bead sp-todo "$SPIRA_ASK_LABEL,overseer" open "VERIFY: false")
EOF
out="$("$COCKPIT/verify-asks.sh" --apply 2>&1)"
want "the satisfied ask is closed" "SATISFIED  sp-done" "$out"
want "the unsatisfied one is left alone" "still open sp-todo" "$out"
reason="$("$BD" -C "$DB" show sp-done --json 2>/dev/null | sed -n '/^[[{]/,$p' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d[0] if isinstance(d,list) else d).get("close_reason") or "")' 2>/dev/null)"
# A close that says "done" is a claim with nothing behind it.
want "it closes with the check's own output as evidence" "the-evidence" "$reason"

# ======================================================================================
echo
echo "answered-since.sh — a verdict given while nobody was home"

MARK="$TMP/mark"
out="$(ANSWER_MARK="$MARK" "$COCKPIT/answered-since.sh" 2>&1)"
eq "the first run seeds silently rather than replaying history" "" "$out"
[ -s "$MARK" ] && ok "and writes the mark" || bad "and writes the mark" "the mark is empty"

# Both sleeps are load-bearing, and for the same reason: the mark and `closed_at` are both
# second-granularity ISO-8601 compared as strings, so a close and the run that announces it
# landing inside the same second is a race — bd can round the close up to the next second
# while the run that reports it stamps the one before, and the verdict is then announced
# again on the following run. Hours separate these in production; only the test compresses
# them, so the test is what has to separate them.
sleep 1
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" close sp-todo --force --reason "take your default" >/dev/null 2>&1
sleep 1
out="$(ANSWER_MARK="$MARK" "$COCKPIT/answered-since.sh" 2>&1)"
want "the verdict is reported" "sp-todo" "$out"
want "with the reason they gave" "take your default" "$out"
out="$(ANSWER_MARK="$MARK" "$COCKPIT/answered-since.sh" 2>&1)"
nowant "and is announced once, not every session" "sp-todo" "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
