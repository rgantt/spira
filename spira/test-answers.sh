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
# Three failures are covered, each of which happened:
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
# Every negative is paired with a positive control: a matcher that finds nothing must first
# be shown finding something, or "no answers" and "looking in the wrong place" are the same
# output (law-absence-needs-a-positive-control).
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
echo "the callers — both legs, through the programs a session actually runs"
# ======================================================================================
setcursor "$CC" "$OLD"; setcursor "$VC" "$OLD"
out="$(VERDICT_CURSOR="$VC" COMMENT_CURSOR="$CC" "$HERE/verdicts.sh" once 2>&1)"
want "verdicts.sh once reports the comment on the FYI" "COMMENTED ON sp-fyi" "$out"
want "verdicts.sh once reports the verdict"            "ANSWERED sp-ask" "$out"
out="$(VERDICT_CURSOR="$VC" COMMENT_CURSOR="$CC" "$HERE/verdicts.sh" once 2>&1)"
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
echo "the fence — the panel must CLOSE as the operator, not merely comment as them"
# ======================================================================================
# Authorship on the close is what the verdict leg filters on, so a panel that closes
# unstamped makes every verdict it writes indistinguishable from an agent's -- and the leg
# above would then drop the operator's real answers. This is the one line that cannot regress.
mrs="$COCKPIT/panel/src/model.rs"
if [ -f "$mrs" ]; then
    if python3 - "$mrs" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"View::Decisions\s*=>\s*\{(.*?)\n        \}", src, re.S)
sys.exit(0 if m and "close" in m.group(1) and "operator_actor()" in m.group(1) else 1)
PY
    then ok "the panel closes as the operator's actor"
    else bad "the panel closes as the operator's actor" \
             "View::Decisions closes without operator_actor()"; fi
    # The positive control: the check must be able to refuse.
    probe="$TMP/model.rs"
    printf 'match v {\n        View::Decisions => {\n            run("bd", &["close", &i.id]);\n        }\n}\n' > "$probe"
    if python3 - "$probe" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"View::Decisions\s*=>\s*\{(.*?)\n        \}", src, re.S)
sys.exit(0 if m and "close" in m.group(1) and "operator_actor()" in m.group(1) else 1)
PY
    then bad "the fence refuses an unstamped close" "it accepted one"
    else ok "the fence refuses an unstamped close"; fi
else
    printf '  note  no panel source here; the close-authorship fence did not run\n'
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
