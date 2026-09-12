#!/usr/bin/env bash
#
# test-concierge.sh — the Concierge persona: composed like an aeon, summoned by nobody.
#
#   ./test-concierge.sh
#
# Two claims, and the second is the one with teeth.
#
# COMPOSED — concierge.sh renders chamber/concierge.md with every placeholder substituted and
# the statute book appended in full, and REFUSES to start when it cannot. A concierge launched
# without its brief looks identical to a working one from outside, and the way anybody finds
# out is the next violated statute.
#
# NEVER SUMMONED — the sentinel draws from spira_task_fayths and spira_lane_fayths, and
# neither may ever contain it. This one carries its own positive control: an ordinary fayth
# sits in the same fixture chamber and MUST appear, because a test asserting only absence
# passes just as well against a roster that is empty for some unrelated reason
# (law-absence-needs-a-positive-control).
#
# No database for the roster half, no network, under a second.
#
# defect: sp-u4x
# covers: spira/lib.sh concierge.sh spira/chamber/concierge.fayth spira/chamber/concierge.md
# hermetic-ok: fixture chamber, no systemd or database for the roster checks
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

is()     { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
           else fail=$((fail+1)); printf '  FAIL  %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
want()   { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok    %s\n' "$1" ;;
           *) fail=$((fail+1)); printf '  FAIL  %s: wanted [%s]\n' "$1" "$2" ;; esac; }
nowant() { case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL  %s: did not want [%s]\n' "$1" "$2" ;;
           *) pass=$((pass+1)); printf '  ok    %s\n' "$1" ;; esac; }

echo "the roster — who the sentinel may summon"

# A FIXTURE CHAMBER, NOT THE REAL ONE. The shipped $SPIRA_FAYTHS omits the concierge on every
# host today, so a suite reading the live roster would pass for a reason that has nothing to do
# with FAYTH_SUMMON — and would keep passing after the property was deleted.
CH="$TMP/chamber"; mkdir -p "$CH"
cat > "$CH/worker.fayth" <<'EOF'
FAYTH_NAME=worker
FAYTH_LABELS="spira,plan"
EOF
cat > "$CH/laner.fayth" <<'EOF'
FAYTH_NAME=laner
FAYTH_LABELS="spira,incident"
FAYTH_LANE=ops
EOF
cat > "$CH/human.fayth" <<'EOF'
FAYTH_NAME=human
FAYTH_SUMMON=operator
EOF
# A persona that is BOTH operator-summoned and in a lane. FAYTH_SUMMON must win: the lane
# loop is a second door into the sentinel, and a fayth kept out of one list and handed to the
# other is summoned exactly as if nothing had been declared.
cat > "$CH/humanlane.fayth" <<'EOF'
FAYTH_NAME=humanlane
FAYTH_LABELS="spira,incident"
FAYTH_LANE=ops
FAYTH_SUMMON=operator
EOF

roster() { # roster <function>
    env -i PATH="$PATH" HOME="$TMP" LC_ALL=C.UTF-8 SPIRA_CONF="$TMP/no.conf" \
        SPIRA_HOME="$TMP" SPIRA_FAYTHS="worker laner human humanlane" \
        bash -c '. "$2"/lib.sh 2>/dev/null; "$1"' _ "$1" "$HERE" 2>/dev/null
}
# The fixture chamber must sit under SPIRA_HOME, which is where fayth_get and fayth_names look.
ln -sfn "$CH" "$TMP/chamber"

is "the task pool is the ordinary fayth alone"        "worker"          "$(roster spira_task_fayths)"
is "the lane list is the ordinary lane fayth alone"   "laner"           "$(roster spira_lane_fayths)"
# fayth_names sorts, so both operator personas appear in this order.
is "and the operator personas are named as such"      "human humanlane" "$(roster spira_operator_fayths)"

nowant "an operator persona is never in the task pool"  "human" "$(roster spira_task_fayths)"
nowant "nor in the lane list, which is the second door" "human" "$(roster spira_lane_fayths)"

# THE POSITIVE CONTROL FOR THE CONTROL. Strip FAYTH_SUMMON from the fixture and the same
# persona MUST appear — otherwise these assertions would pass against a roster that was empty
# for some unrelated reason, which is the shape of a test that guards nothing.
printf 'FAYTH_NAME=human\n' > "$CH/human.fayth"
want "without FAYTH_SUMMON that persona IS summoned" "human" "$(roster spira_task_fayths)"

echo
echo "the shipped concierge — real persona, summoned by nobody"

ship() { # ship <function>   — the REAL chamber, with the concierge listed in the roster
    env -i PATH="$PATH" HOME="$TMP" LC_ALL=C.UTF-8 SPIRA_CONF="$TMP/no.conf" \
        SPIRA_HOME="$HERE" SPIRA_FAYTHS="builder ops concierge" \
        bash -c '. "$2"/lib.sh 2>/dev/null; "$1"' _ "$1" "$HERE" 2>/dev/null
}
# LISTED IN $SPIRA_FAYTHS ON PURPOSE. No host lists it today, so the roster alone would keep
# it out — and that is a second reason, not the one under test. Naming it here removes the
# reason that is doing the work by accident and leaves only FAYTH_SUMMON holding the line.
nowant "the shipped concierge is not in the task pool"   "concierge" "$(ship spira_task_fayths)"
nowant "the shipped concierge is not in the lane list"   "concierge" "$(ship spira_lane_fayths)"
want   "the shipped concierge IS an operator persona"    "concierge" "$(ship spira_operator_fayths)"
want   "and the other personas are still summonable"     "builder"   "$(ship spira_task_fayths)"

echo
echo "the brief — composed, or refused"

BRIEF="$(bash "$HARNESS/concierge.sh" brief 2>"$TMP/err")"
if [ -n "$BRIEF" ] && [ -f "$BRIEF" ]; then
    pass=$((pass+1)); printf '  ok    concierge.sh brief renders a file\n'
    B="$(cat "$BRIEF")"
    # EVERY PLACEHOLDER, because an unsubstituted one is a command line the session will try
    # to run. The failure arrives hours later as "the concierge does not escalate anything".
    nowant "no placeholder survives rendering"  "{{"          "$B"
    want   "the brief names the ask path"       "ask.sh add"  "$B"
    want   "and the bead contract"              "bead.sh file" "$B"
    want   "and carries the statute book"       "# Memories in force" "$B"
    # THE STATUTES THIS ROLE IS ACTUALLY HELD TO, IN FULL TEXT — not as index slugs. This is
    # the whole reason FAYTH_STATUTE_CORE exists: the shipped core set is builder-shaped, and
    # the statute the operator's own session violated for 39 turns was outside it.
    for law in law-the-harness-checkout-is-production law-filed-bead-queued-xor-escalated \
               law-decisions-surface-immediately law-closed-is-not-landed; do
        want "  $law is rendered in full" "## $law" "$B"
    done
else
    fail=$((fail+1)); printf '  FAIL  concierge.sh brief produced nothing:\n%s\n' "$(cat "$TMP/err")"
fi

# A MISSING BRIEF IS A REFUSAL, NOT A DEGRADED START — the assertion that the refusal exists.
# Pointed at a persona with no markdown, it must fail loudly rather than launch a session whose
# only difference from a working one is that it was never told anything.
out="$(CONCIERGE_FAYTH=no-such-persona bash "$HARNESS/concierge.sh" brief 2>&1)"; rc=$?
is   "a missing brief exits non-zero"     1 "$rc"
want "and says which file was missing"    "no-such-persona.md" "$out"

echo
echo "concierge self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
