#!/usr/bin/env bash
#
# test-answers.sh — the operator's answers reach a session, and nothing else does.
#
#   ./test-answers.sh
#
# Against a REAL `bd` on a throwaway database, because every property here is a property of
# beads rather than of our parsing: where a comment's author is recorded, whether a comment
# bumps the bead's updated_at (it does not), and — the one this suite exists for — whether
# beads records WHO closed an issue. A stub would answer all three from memory.
#
# Four failures are covered, each of which happened:
#
#   A COMMENT ON AN FYI REACHED NOBODY. An FYI is created closed and carries neither the
#   escalation label nor a status transition, so a close-cursor is blind to it twice over.
#   A reply left on one sat unread until the operator said so.
#
#   AN AGENT'S OWN CLOSE CAME BACK AS AN ANSWER. The row `bd list` returns has no closed_by,
#   so a harness close and the operator's verdict look identical on it. A session acting on
#   that is acting on its own echo, and it is silent because the announcement reads exactly
#   like a real answer.
#
#   AND THE CHEAP CURSOR DOES NOT WORK. A comment does not move updated_at, so a mark over
#   closes cannot express how far the comment leg has read. That is asserted here rather
#   than assumed, because the whole second cursor exists only if it is true.
#
#   A CLEARED MARK SWALLOWED THE WINDOW IT WAS CLEARED IN. The remedy for a watcher whose
#   state had accumulated against a database it no longer read was to delete that state, and
#   a mark that seeds at `now` when it is missing loses every answer given since its last
#   read — silently, because having lost your place and having nothing to say print the same.
#
# Every negative is paired with a positive control: a matcher that finds nothing must first
# be shown finding something, or "no answers" and "looking in the wrong place" are the same
# output (law-absence-needs-a-positive-control).
#
# covers: spira/answers.py cockpit/answered-since.sh cockpit/unanswered.sh cockpit/watch-answers.sh cockpit/reply.sh cockpit/resolve.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
COCKPIT="$HERE/../cockpit"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
eq()     { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

TMP="$(mktemp -d)"
. "$HERE/testdb.sh"
testdb_require test-answers
testdb_up answers || { echo "testdb_up failed"; exit 1; }
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

DB="$SPIRA_DB"
BD="${TESTDB_BD:-bd}"

# EVERY CONFIGURED NAME IS PINNED TO A NON-DEFAULT. Asserting against the shipped defaults
# passes just as well if the code has the literal written in, which is the thing these keys
# exist to stop. The operator's actor is deliberately not the word the code defaults to.
export SPIRA_DB="$DB" COCKPIT_DB="$DB" BD_BIN="$BD"
export SPIRA_ASK_LABEL=needs-a-human
export SPIRA_OPERATOR_ACTOR=the-boss
export SPIRA_OPERATOR="Boss"
AGENT=an-agent
# EXPLICIT AND MINIMAL. SPIRA_RUN is where the watcher defaults its marks, and SELF_CLOSED is
# a file the harness appends to as it closes its own asks — inheriting either would let this
# suite write into a live installation's state, and a real self-closed record would suppress
# a verdict here for a reason nothing in the suite mentions
# (law-gates-run-in-a-clean-environment).
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SELF_CLOSED="$TMP/self-closed"; : > "$SELF_CLOSED"

VC="$TMP/verdict-cursor"; CC="$TMP/comment-cursor"
OLD=2000-01-01T00:00:00Z

# answers.py is fed the bead list the same way its callers feed it.
answers() {   # answers <format> [extra args...]
    local fmt="$1"; shift
    "$BD" -C "$DB" list --all --limit 0 --json 2>/dev/null | sed -n '/^[[{]/,$p' \
      | python3 "$HERE/answers.py" "bd=$BD" "db=$DB" \
            "ask_label=$SPIRA_ASK_LABEL" "operator_actor=$SPIRA_OPERATOR_ACTOR" \
            "operator=$SPIRA_OPERATOR" "format=$fmt" "$@" 2>&1
}
setcursor() { printf '%s\n' "$2" > "$1"; }   # a BARE timestamp: the format already installed

bead() {   # bead <id> <labels-csv> <status> <title>
    printf '{"id":"%s","title":"%s","status":"%s","issue_type":"task","labels":[%s],"updated_at":"2026-01-01T00:00:00Z"}\n' \
      "$1" "$4" "$3" "$(printf '"%s",' ${2//,/ } | sed 's/,$//')"
}

testdb_seed <<EOF
$(bead sp-fyi  insight,overseer            closed "an FYI, created closed")
$(bead sp-quiet insight,overseer           closed "an FYI nobody has spoken on")
$(bead sp-ask  "$SPIRA_ASK_LABEL,overseer" open   "an escalation")
$(bead sp-mine "$SPIRA_ASK_LABEL,overseer" open   "an escalation I resolve myself")
$(bead sp-late "$SPIRA_ASK_LABEL,overseer" open   "an escalation answered after the mark was cleared")
$(bead sp-pre  "$SPIRA_ASK_LABEL,overseer" open   "an escalation the harness resolved itself")
EOF

# ======================================================================================
echo "the premise — a comment leaves no trace on the bead a close-cursor watches"
# ======================================================================================
before="$("$BD" -C "$DB" show sp-fyi --json 2>/dev/null | sed -n '/^[[{]/,$p' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d[0] if isinstance(d,list) else d).get("updated_at",""))')"
sleep 1
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" comments add sp-fyi \
    "treat it as just another project" >/dev/null 2>&1
after="$("$BD" -C "$DB" show sp-fyi --json 2>/dev/null | sed -n '/^[[{]/,$p' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d[0] if isinstance(d,list) else d).get("updated_at",""))')"
eq "a comment does not bump updated_at, so a close-cursor cannot see one" "$before" "$after"

thread="$("$BD" -C "$DB" comments sp-fyi --json 2>/dev/null | sed -n '/^[[{]/,$p')"
want "the author IS recorded, on the comment" "$SPIRA_OPERATOR_ACTOR" "$thread"

# ======================================================================================
echo
echo "the comment leg — an FYI is exactly the case that had no path at all"
# ======================================================================================
setcursor "$VC" "$OLD"; setcursor "$CC" "$OLD"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
want "an FYI with a new comment is reported"      "COMMENTED ON sp-fyi" "$out"
want "and the announcement names the operator"    "BOSS" "$out"
want "and carries the comment text, not a path to it" "treat it as just another project" "$out"

out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "run again immediately and it is silent" "" "$out"

# THE NEGATIVE, WITH THE POSITIVE ALREADY ESTABLISHED ABOVE. An FYI whose only comment is
# older than the mark is the same query returning nothing for the right reason.
setcursor "$CC" "2099-01-01T00:00:00Z"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "an FYI whose only comment predates the mark is silent" "" "$out"

# An FYI with no conversation at all must never be fetched into a report.
setcursor "$CC" "$OLD"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
nowant "an FYI nobody has spoken on is not reported" "sp-quiet" "$out"

# Whose voice. The agent replies in the same thread, and its own words must not come back.
sleep 1
BEADS_ACTOR="$AGENT" "$BD" -C "$DB" comments add sp-fyi "acknowledged" >/dev/null 2>&1
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
nowant "an agent's own reply is not announced back to it" "acknowledged" "$out"

# ...and the operator speaking again after it IS.
sleep 1
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" comments add sp-fyi "one more thing" >/dev/null 2>&1
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
want "a later comment of theirs still gets through" "one more thing" "$out"

# ======================================================================================
echo
echo "the verdict leg — a close is reported only when THEY made it"
# ======================================================================================
setcursor "$VC" "$OLD"; setcursor "$CC" "2099-01-01T00:00:00Z"

BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" close sp-ask --force \
    --reason "take your default" >/dev/null 2>&1
# The claim the whole filter rests on: beads records the closing actor SOMEWHERE readable.
evs="$("$BD" -C "$DB" history sp-ask --events --json 2>/dev/null | sed -n '/^[[{]/,$p')"
want "beads records the closing actor in its audit events" "$SPIRA_OPERATOR_ACTOR" "$evs"
# ...and not on the issue row, which is why the extra call is not laziness.
row="$("$BD" -C "$DB" show sp-ask --json 2>/dev/null | sed -n '/^[[{]/,$p')"
nowant "the issue row carries no closed_by" "closed_by" "$row"

out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
want "their close is reported as a verdict" "ANSWERED sp-ask" "$out"
want "with the reason, which IS the answer" "take your default" "$out"

out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "and never twice" "" "$out"

# THE ECHO. An agent closes an escalation itself, quoting them in the reason. Nothing on the
# row distinguishes it, so a filter that trusts the row announces it as an answer they never
# gave -- and the text looks exactly like a real verdict.
BEADS_ACTOR="$AGENT" "$BD" -C "$DB" close sp-mine --force \
    --reason "resolved myself, quoting them: take your default" >/dev/null 2>&1
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "an agent's own close is not announced back to it as a verdict" "" "$out"

# ======================================================================================
echo
echo "the marks — a bare timestamp is upgraded, and a tie is not lost"
# ======================================================================================
setcursor "$CC" "$OLD"
answers monitor "verdict_cursor=$VC" "comment_cursor=$CC" >/dev/null
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CC" 2>/dev/null \
    && ok "an installed bare-timestamp mark is read and rewritten" \
    || bad "an installed bare-timestamp mark is read and rewritten" "$(cat "$CC")"

# TWO COMMENTS IN ONE SECOND. `created_at` is second-resolution, so a mark that is only a
# timestamp must either replay the pair forever or drop one of them. Written as separate
# beads so a single fetch cannot order its way out of the tie.
rm -f "$CC"; setcursor "$CC" "$OLD"
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" comments add sp-quiet "tie A" >/dev/null 2>&1
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" comments add sp-ask   "tie B" >/dev/null 2>&1
tie_a="$("$BD" -C "$DB" comments sp-quiet --json 2>/dev/null | sed -n '/^[[{]/,$p' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["created_at"])' 2>/dev/null)"
tie_b="$("$BD" -C "$DB" comments sp-ask --json 2>/dev/null | sed -n '/^[[{]/,$p' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["created_at"])' 2>/dev/null)"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
want "both of a same-second pair are reported once" "tie A" "$out"
want "both of a same-second pair are reported once" "tie B" "$out"
if [ "$tie_a" = "$tie_b" ]; then
    ok "the pair genuinely shared a timestamp ($tie_a)"
else
    printf '  note  the pair landed in different seconds (%s / %s) — the tie was not exercised\n' \
        "$tie_a" "$tie_b"
fi
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "and neither is replayed on the next pass" "" "$out"

# FIRST RUN SEEDS. Arming a watcher must not replay every historical answer as though it
# had just landed -- a burst of stale verdicts is how a real one goes unread.
rm -f "$TMP/fresh-v" "$TMP/fresh-c"
out="$(answers monitor "verdict_cursor=$TMP/fresh-v" "comment_cursor=$TMP/fresh-c")"
eq "a fresh mark seeds silently rather than replaying history" "" "$out"
[ -s "$TMP/fresh-c" ] && ok "and the mark is written on that first pass" \
                      || bad "and the mark is written on that first pass" "no file"

# ======================================================================================
echo
echo "a CLEARED mark is covered by its sibling, rather than seeded silently"
# ======================================================================================
# The remedy for a poisoned state file is to delete it — that is what was done to the watcher
# whose per-bead state had been accumulated against a database it no longer read. Under a
# mark that seeds at `now` when it is missing, that deletion silently swallows every answer
# given between the last read and the reset, and it is invisible: a watcher that has lost its
# place and a watcher with nothing to say print exactly the same thing.
setcursor "$VC" "$OLD"; setcursor "$CC" "$OLD"
answers monitor "verdict_cursor=$VC" "comment_cursor=$CC" >/dev/null
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "both marks are drained to the present first" "" "$out"

sleep 1
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" close sp-late --force \
    --reason "answered while the mark was gone" >/dev/null 2>&1
rm -f "$VC"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
want "a verdict given after the mark was cleared is still reported" "ANSWERED sp-late" "$out"
want "and carries the answer itself" "answered while the mark was gone" "$out"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "and the rebuilt mark does not replay it" "" "$out"

# THE OTHER DIRECTION, so the coverage is not one-legged.
sleep 1
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" comments add sp-quiet "said with no mark" >/dev/null 2>&1
rm -f "$CC"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
want "a comment left after ITS mark was cleared is reported too" "said with no mark" "$out"

# THE NEGATIVE THAT MUST SURVIVE. Both marks absent is a genuine first arming, and replaying
# every historical verdict at once is how a real one goes unread. The lines above are the
# positive control: the same code path, reporting.
rm -f "$VC" "$CC"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
eq "but BOTH marks absent still seeds silently" "" "$out"

# ======================================================================================
echo
echo "the self-closed record — the cheap pre-filter, and what it is not allowed to be"
# ======================================================================================
# cockpit/resolve.sh appends the id of every ask the harness closes itself, BEFORE it closes
# it. Reading that file skips a `bd history` call for the common case. It is a pre-filter and
# never the decision: a close made by an agent that did not go through resolve.sh is absent
# from it, and the audit-event filter above is what still catches that one.
setcursor "$VC" "$OLD"; setcursor "$CC" "2099-01-01T00:00:00Z"
answers monitor "verdict_cursor=$VC" "comment_cursor=$CC" >/dev/null

sleep 1
printf 'sp-pre\n' > "$SELF_CLOSED"
# Closed as the OPERATOR on purpose. Nothing but the file can suppress this one, so if it is
# silent the file was read; if it speaks, the pre-filter is dead code and resolve.sh has been
# writing to nobody. (In service this cannot mislead: resolve.sh records only ids it closes.)
BEADS_ACTOR="$SPIRA_OPERATOR_ACTOR" "$BD" -C "$DB" close sp-pre --force \
    --reason "the harness resolved this itself" >/dev/null 2>&1
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
nowant "an id recorded by resolve.sh is skipped before the trail is read" "sp-pre" "$out"

# THE POSITIVE CONTROL: the same close, the same cursor, with the record empty.
setcursor "$VC" "$OLD"
: > "$SELF_CLOSED"
out="$(answers monitor "verdict_cursor=$VC" "comment_cursor=$CC")"
want "and it is only the record doing that — emptied, the verdict arrives" "ANSWERED sp-pre" "$out"
printf 'sp-pre\n' > "$SELF_CLOSED"

# ======================================================================================
echo
echo "the callers — both legs, through the programs a session actually runs"
# ======================================================================================
setcursor "$CC" "$OLD"; setcursor "$VC" "$OLD"
out="$(VERDICT_CURSOR="$VC" COMMENT_CURSOR="$CC" "$COCKPIT/watch-answers.sh" once 2>&1)"
want "watch-answers.sh once reports the comment on the FYI" "COMMENTED ON sp-fyi" "$out"
want "watch-answers.sh once reports the verdict"            "ANSWERED sp-ask" "$out"
out="$(VERDICT_CURSOR="$VC" COMMENT_CURSOR="$CC" "$COCKPIT/watch-answers.sh" once 2>&1)"
eq "and is silent on the next pass, so it is safe as a Monitor" "" "$out"

setcursor "$CC" "$OLD"; setcursor "$VC" "$OLD"
out="$(ANSWER_MARK="$VC" ANSWER_COMMENT_MARK="$CC" "$COCKPIT/answered-since.sh" 2>&1)"
want "answered-since.sh reports a comment left overnight" "sp-fyi" "$out"
want "answered-since.sh reports a verdict left overnight" "sp-ask" "$out"
nowant "and never the agent's own close"                  "sp-mine" "$out"
out="$(ANSWER_MARK="$VC" ANSWER_COMMENT_MARK="$CC" "$COCKPIT/answered-since.sh" 2>&1)"
eq "and says nothing at the next session start" "" "$out"

# ======================================================================================
echo
echo "the witness — proof the watcher can SEE, kept apart from how far it has read"
# ======================================================================================
# The manifest's health assertion for this watcher greps its state for one of our own bead
# ids, because a watcher reading a database that was retired underneath it holds rows — just
# not ours — and is otherwise indistinguishable from one with nothing to say.
#
# THE PROPERTY THAT MUST HOLD IS "EVEN WHEN QUIET". A cursor names a bead only in the instant
# one is reported, so an assertion over a cursor renders a healthy idle watcher DEGRADED, and
# a false alarm is the expensive kind (law-alerts-must-be-actionable). Sight is therefore its
# own file, written every pass.
W="$TMP/witness"
hids() {   # the real assertion, in a minimal environment: a live conf would decide the verdict
    env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/absent.conf" \
        SPIRA_ID_PREFIX="${1:-sp}" bash "$HERE/watchd.sh" health-ids "$W"
}
setcursor "$CC" "$OLD"; setcursor "$VC" "$OLD"
out="$(ANSWER_STATE="$W" VERDICT_CURSOR="$VC" COMMENT_CURSOR="$CC" \
       "$COCKPIT/watch-answers.sh" once 2>&1)"
want "a reporting pass still names the beads it saw" "sp-ask" "$(cat "$W" 2>/dev/null)"
eq   "and the health assertion accepts it" "0" "$(hids >/dev/null 2>&1; echo $?)"

# The pass that broke: nothing new to say, so nothing lands in either cursor.
out="$(ANSWER_STATE="$W" VERDICT_CURSOR="$VC" COMMENT_CURSOR="$CC" \
       "$COCKPIT/watch-answers.sh" once 2>&1)"
eq "a quiet pass reports nothing"                    "" "$out"
eq "and the witness still proves the watcher sees"   "0" "$(hids >/dev/null 2>&1; echo $?)"
# WHY IT CANNOT BE THE CURSOR, shown rather than argued. A newly armed watcher seeds its
# cursors silently — no answer is replayed, so no id is written — and it may sit that way for
# days before the operator says anything. That is a watcher which is working perfectly and
# cannot prove it, and the witness written on that very first pass is what closes the gap.
rm -f "$VC" "$CC" "$W"
ANSWER_STATE="$W" VERDICT_CURSOR="$VC" COMMENT_CURSOR="$CC" \
    "$COCKPIT/watch-answers.sh" once >/dev/null 2>&1
eq "a freshly armed cursor names no bead, so it cannot prove sight" "1" \
   "$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/absent.conf" SPIRA_ID_PREFIX=sp \
      bash "$HERE/watchd.sh" health-ids "$VC" >/dev/null 2>&1; echo $?)"
eq "while the witness from that same first pass does" "0" "$(hids >/dev/null 2>&1; echo $?)"

# THE POSITIVE CONTROL FOR THE CHECK ITSELF. A witness that always passed would be worthless,
# so drive the watcher's own payload to a database holding none of our beads and require a
# refusal — that IS the blind watcher, and it is the state this whole epic exists to catch.
printf '[%s]' "$(bead zz-9001 overseer open "a bead belonging to somebody else")" \
  | python3 "$HERE/answers.py" "bd=$BD" "db=$DB" "ask_label=$SPIRA_ASK_LABEL" \
        "operator_actor=$SPIRA_OPERATOR_ACTOR" "witness=$W" format=monitor >/dev/null 2>&1
eq "a pass seeing only foreign beads is refused" "1" "$(hids >/dev/null 2>&1; echo $?)"
has_our=$(cat "$W"); want "having recorded what it did see" "zz-9001" "$has_our"

# AN EMPTY PAYLOAD TRUNCATES rather than leaving the last good list standing. Holding the
# previous answer would report sight that is no longer proved — the failure mode is a watcher
# whose query has silently stopped returning our work, still rendering OK.
printf '[]' | python3 "$HERE/answers.py" "bd=$BD" "db=$DB" "ask_label=$SPIRA_ASK_LABEL" \
        "operator_actor=$SPIRA_OPERATOR_ACTOR" "witness=$W" format=monitor >/dev/null 2>&1
eq "an empty pass does not keep asserting the last sighting" "1" "$(hids >/dev/null 2>&1; echo $?)"

# ONLY THE WATCHER WRITES IT. The assertion answers "can THAT process see", so a session hook
# refreshing the same file would let a dead watcher read healthy — which is the shape of the
# original defect, a watcher looking fine to everything except the thing it was watching.
rm -f "$W"
setcursor "$CC" "$OLD"; setcursor "$VC" "$OLD"
ANSWER_STATE="$W" ANSWER_MARK="$VC" ANSWER_COMMENT_MARK="$CC" \
    "$COCKPIT/answered-since.sh" >/dev/null 2>&1
eq "the session hook writes no witness of its own" "no" "$([ -e "$W" ] && echo yes || echo no)"

# ======================================================================================
echo
echo "the fence — the panel must CLOSE as the operator, not merely comment as them"
# ======================================================================================
# Authorship on the close is what the verdict leg filters on, so a panel that closes
# unstamped makes every verdict it writes indistinguishable from an agent's -- and the leg
# above would then drop the operator's real answers. This is the one line that cannot regress.
# IT ANCHORS ON THE FUNCTION, NOT ON A MATCH ARM. The first version searched the
# `View::Decisions => { ... }` arm for `close` and `operator_actor()` together, which held
# only while the close was open-coded inside the arm. Extracting it to `close_decision` left
# the property TRUE and the fence RED — the arms that still say `View::Decisions` now yield
# the tab's title and the key's verb, neither of which closes anything. A fence keyed to a
# shape rather than to the behaviour fails the moment the shape is tidied, and it then reads
# exactly like the regression it exists to catch.
mrs="$COCKPIT/panel/src/model.rs"
fence_py='
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"fn close_decision\(.*?\n\}", src, re.S)
sys.exit(0 if m and "\"close\"" in m.group(0) and "operator_actor()" in m.group(0) else 1)
'
if [ -f "$mrs" ]; then
    if python3 -c "$fence_py" "$mrs"
    then ok "the panel closes as the operator's actor"
    else bad "the panel closes as the operator's actor" \
             "close_decision does not pass operator_actor() to bd close"; fi
    # The positive control: the check must be able to refuse. The probe is the same function
    # with the actor dropped, which is the regression in its most plausible form — somebody
    # simplifying run_as back to run.
    probe="$TMP/model.rs"
    printf 'fn close_decision(db: &str, id: &str, reason: &str) -> Result<(), String> {\n    run("bd", &["-C", db, "close", id, "--reason", reason])\n}\n' > "$probe"
    if python3 -c "$fence_py" "$probe"
    then bad "the fence refuses an unstamped close" "it accepted one"
    else ok "the fence refuses an unstamped close"; fi
    # AND IT MUST STILL FIND THE FUNCTION AT ALL. A rename would make the search miss, which
    # `bad` would report as an unstamped close — the same wrong story the shape-keyed version
    # told. Absence and violation are different findings (law-absence-needs-a-positive-control).
    grep -q 'fn close_decision(' "$mrs" \
        && ok "and close_decision is the function it judges" \
        || bad "and close_decision is the function it judges" "no fn close_decision in $mrs"
else
    printf '  note  no panel source here; the close-authorship fence did not run\n'
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
