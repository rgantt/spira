#!/usr/bin/env bash
#
# test-fayth.sh — a persona's partition is its own, and every persona in the chamber runs.
#
#   ./test-fayth.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# `ops.fayth` shipped complete and inert on. It was correct — a partition of its
# own, its own statute prefixes, its own lease and timeout — and nothing ever evaluated it,
# because sentinel.sh CHECK 7 gated every summon on one hardcoded `--label spira,plan`
# count. Ops could only wake when the BUILDER had work, which is exactly backwards for an
# on-call persona, and no test could have noticed: the decision lived inline in a script
# whose every other line touches the real repository and the real beads database.
#
# So the decision moved into lib.sh, and this is the suite that holds it. Two properties
# carry the weight, and both are invisible when there is only one persona:
#
#   * readiness is asked through the fayth's OWN predicate, per fayth;
#   * the roster is DISCOVERED from the chamber, so a persona that lands is one that runs.
#
# A REAL `bd` on a fixture database created for the run and dropped by a trap. The claims
# here are about which predicate is asked on whose behalf, but every one of them is read
# THROUGH `bd ready`, so a model of that query is the thing actually under test — and a
# model drifts: the stub this replaced ignored `--label` outright for a day, which made the
# callers look broken while they were correct. The case that matters most — a queue with
# incident work and no plan work — is arranged in the fixture rather than in the live
# database, where it would mean filing a real incident.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-fayth

TMP="$(mktemp -d)"
KIDS=()
cleanup() { for p in "${KIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
            testdb_drop; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
testdb_up fayth || { echo "test-fayth: could not build a fixture database"; exit 1; }

# THE ESCALATION LABEL IS PINNED TO A NON-DEFAULT VALUE HERE ON PURPOSE. Asserting against
# the shipped default would pass just as well if the code had the literal written in, which
# is the thing this key exists to stop; a distinctive value fails the moment one does.
export SPIRA_ASK_LABEL=needs-a-human
export SPIRA_RUN="$TMP/run"
export SPIRA_HOME="$TMP/home"
mkdir -p "$SPIRA_RUN" "$SPIRA_HOME/chamber"
printf '#!/bin/sh\nexit 0\n' > "$SPIRA_HOME/aeon.sh"; chmod +x "$SPIRA_HOME/aeon.sh"

# The recorder that stands in for systemd-run. It records the whole argv, because half of
# what this suite asserts is that the per-persona properties reaching the transient unit are
# that persona's own.
SUMMONED="$TMP/summoned.txt"
export SPIRA_SUMMON="$TMP/summon.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' "$SUMMONED" > "$SPIRA_SUMMON"
chmod +x "$SPIRA_SUMMON"

fayth() {   # fayth <name> <labels> [extra lines...]
    { printf 'FAYTH_NAME=%s\nFAYTH_LABELS="%s"\nFAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL"\n' "$1" "$2"
      shift 2; for line in "$@"; do printf '%s\n' "$line"; done
    } > "$SPIRA_HOME/chamber/$1.fayth"
}

# THE WHOLE DATABASE, per case. A reset to the fixture's baseline commit is one wire call
# and costs about a third of a second, which buys every case a database with nothing in it
# but what the case named — and no test ordering to reason about.
beads() {   # beads [row ...] — the whole database, one `bead` row per argument
    testdb_reset
    [ $# -gt 0 ] || return 0
    printf '%s\n' "$@" | testdb_seed
}
bead() {    # bead <id> <labels-csv> [type] [status] -> one import row
    printf '{"id":"%s","title":"t %s","status":"%s","issue_type":"%s","labels":[%s],"updated_at":"2026-09-04T00:00:00Z"}\n' \
      "$1" "$1" "${4:-open}" "${3:-task}" "$(printf '"%s",' ${2//,/ } | sed 's/,$//')"
}

summon() { : > "$SUMMONED"; summon_fayth "$1" >"$TMP/log" 2>&1; printf '%s' "$?"; }
summon_log() { cat "$TMP/log"; }
recorded() { cat "$SUMMONED" 2>/dev/null; }

# A process with 'aeon.sh' genuinely in its argv, because aeon_alive reads /proc and must
# never be satisfied by a pattern (law: pgrep may nominate, /proc decides).
live_aeon() {   # live_aeon <fayth> <bead-id>
    ( exec -a "aeon.sh $1" sleep 120 ) & local pid=$!
    KIDS+=("$pid"); echo "$pid" > "$SPIRA_RUN/aeon-$1-$2.pid"
}

fayth builder spira,plan     'FAYTH_MAX_CONCURRENT=1' 'FAYTH_TIMEOUT_SECONDS=3600'
fayth ops     spira,incident 'FAYTH_MAX_CONCURRENT=1' 'FAYTH_TIMEOUT_SECONDS=1800'
beads

# shellcheck disable=SC1090
. "$HERE/lib.sh"

# ======================================================================================
echo "the roster is discovered, never hardcoded:"
# ======================================================================================
is "fayth_names lists every fayth in the chamber" "builder ops" "$(fayth_names | tr '\n' ' ' | sed 's/ $//')"
is "spira_fayths defaults to the whole chamber"   "builder ops" "$(spira_fayths | sed 's/ $//')"

# The property the old `${SPIRA_FAYTHS:-builder}` default did not have: landing a persona
# is the whole of installing it. ops.fayth was complete and unreferenced for a day.
fayth sage spira,review
is "a fayth that lands is a fayth that runs" "builder ops sage" "$(spira_fayths | sed 's/ $//')"
rm -f "$SPIRA_HOME/chamber/sage.fayth"

is "SPIRA_FAYTHS still overrides for a host" "ops" "$(SPIRA_FAYTHS=ops spira_fayths)"

# ...and a host that narrows the roster says which personas it left out. A fayth present and
# unlisted is one that landed complete and will never run — the failure that went unnoticed
# for a day, made loud rather than made impossible, because narrowing is legitimate.
want "a narrowed roster names what it drops" "builder.fayth is in the chamber" "$(roster_warnings "ops" 2>&1)"
is   "the full roster warns about nothing"   "" "$(roster_warnings "$(spira_fayths)" 2>&1)"
nowant "and does not warn about what it lists" "ops.fayth" "$(roster_warnings "builder ops" 2>&1)"
is "an empty chamber yields no personas, not a default" "" \
   "$(SPIRA_HOME="$TMP/empty" spira_fayths)"

# ======================================================================================
echo
echo "readiness is asked through each fayth's OWN predicate:"
# ======================================================================================
# THE BUG, stated as a fixture: an incident is waiting and the plan queue is empty. Under
# the single `--label spira,plan` gate this summoned nothing at all.
beads "$(bead sp-inc-1 spira,incident)"
is "the builder's partition is empty" 0 "$(fayth_ready builder)"
is "ops's own partition has the incident" 1 "$(fayth_ready ops)"
is "ops is summoned with no plan work queued" 0 "$(summon ops)"
want "and the log says whose queue it read" "CHECK7 ops: 1 ready" "$(summon_log)"
is "the builder is not summoned for ops's work" 1 "$(summon builder)"
want "and says so"  "nothing ready in its partition" "$(summon_log)"

# The mirror image, so the fix cannot be "summon everyone always".
beads "$(bead sp-plan-1 spira,plan)"
is "the builder is summoned for plan work" 0 "$(summon builder)"
is "ops is not summoned for plan work"     1 "$(summon ops)"

# Both queues full: both personas wake in the same pass.
beads "$(bead sp-plan-1 spira,plan)" "$(bead sp-inc-1 spira,incident)"
is "builder wakes" 0 "$(summon builder)"
is "ops wakes too" 0 "$(summon ops)"

# ======================================================================================
echo
echo "a fayth's exclusions are its own too:"
# ======================================================================================
beads "$(bead sp-inc-2 "spira,incident,$SPIRA_ASK_LABEL")"
is "an escalation is never dispatched as work" 0 "$(fayth_ready ops)"
beads "$(bead sp-inc-3 spira,incident,spira-poison)"
is "a poisoned bead is not ready"              0 "$(fayth_ready ops)"
beads "$(bead sp-epic spira,incident epic)"
is "an epic is not claimable work"             0 "$(fayth_ready ops)"
beads "$(bead sp-inc-4 spira,incident task closed)"
is "a closed bead is not ready"                0 "$(fayth_ready ops)"
# AND over the labels, not OR: the Spira database holds 1,600 imported Gas Town beads and a
# persona that ORs its way into them races a live polecat (law-spira-is-a-replica-until-cutover).
beads "$(bead pd-999 spira)"
is "a partial label match is not in the partition" 0 "$(fayth_ready ops)"

# ======================================================================================
echo
echo "concurrency is per persona, and read from that persona's file:"
# ======================================================================================
beads "$(bead sp-inc-1 spira,incident)" "$(bead sp-plan-1 spira,plan)"
live_aeon ops sp-inc-0
is "a live ops aeon fills ops's only slot" 0 "$(fayth_free ops)"
is "and ops is not summoned again"         1 "$(summon ops)"
want "the log names the cap"  "at concurrency cap" "$(summon_log)"
is "the builder's slot is untouched by it" 1 "$(fayth_free builder)"
is "and the builder still wakes"           0 "$(summon builder)"

fayth ops spira,incident 'FAYTH_MAX_CONCURRENT=2' 'FAYTH_TIMEOUT_SECONDS=1800'
is "raising ops's cap frees a slot"        1 "$(fayth_free ops)"
is "and ops is summoned again"             0 "$(summon ops)"
fayth ops spira,incident 'FAYTH_MAX_CONCURRENT=1' 'FAYTH_TIMEOUT_SECONDS=1800'

# ======================================================================================
echo
echo "no field leaks from one fayth to the next:"
# ======================================================================================
# Sourcing a fayth sets FAYTH_* in the caller. The whole defect was one persona wearing
# another's predicate, so reading two in a row must not reproduce it by a second route.
is "fayth_get reads the builder's labels" "spira,plan"     "$(fayth_get builder FAYTH_LABELS)"
is "and then ops's own"                   "spira,incident" "$(fayth_get ops FAYTH_LABELS)"
is "and the builder's again, unchanged"   "spira,plan"     "$(fayth_get builder FAYTH_LABELS)"
is "nothing is left set in the caller"    ""               "${FAYTH_LABELS:-}"

# The transient unit must carry the summoned persona's OWN ceiling. Ops's incidents are a
# bounded diagnosis (1800s); the builder's beads are an implementation (3600s).
beads "$(bead sp-inc-1 spira,incident)"
rm -f "$SPIRA_RUN"/aeon-ops-*.pid
summon ops >/dev/null
want "ops's transient unit carries ops's timeout" "TimeoutStartSec=1800" "$(recorded)"
want "and names the ops aeon"                     "aeon.sh ops"          "$(recorded)"
beads "$(bead sp-plan-1 spira,plan)"
summon builder >/dev/null
want "the builder's carries the builder's"        "TimeoutStartSec=3600" "$(recorded)"

# ======================================================================================
echo
echo "an absent fayth is skipped, not guessed at:"
# ======================================================================================
is "summon_fayth refuses a name with no file" 1 "$(summon nowhere)"
want "and says which"  "no fayth in the chamber" "$(summon_log)"
is "and summons nothing"  "" "$(recorded)"

# ======================================================================================
echo
echo "liveness is scoped to the partition being asked about:"
# ======================================================================================
# strand.sh reports on ONE partition, so a running Ops aeon must not read as "the plan is
# being worked" and silence a genuine starvation escalation.
is "fayths_for_labels picks the plan's persona"     "builder" "$(fayths_for_labels spira,plan | tr '\n' ' ' | sed 's/ $//')"
is "and the incident partition's, separately"       "ops"     "$(fayths_for_labels spira,incident | tr '\n' ' ' | sed 's/ $//')"
is "a partition no persona claims selects nobody"   ""        "$(fayths_for_labels spira,nothing)"
is "SPIRA_FAYTHS does not widen it"                 "builder" \
   "$(SPIRA_FAYTHS='builder ops' fayths_for_labels spira,plan | tr '\n' ' ' | sed 's/ $//')"

# ======================================================================================
echo
echo "the sentinel asks unconditionally:"
# ======================================================================================
# A structural regression check on the one thing behavioural tests cannot reach here: a
# sentinel pass touches the real repository, so the summon loop can only be inspected. It
# must sit at the top level of the script — the defect was precisely that it sat inside
# `if [ "$ready" -gt 0 ]`, one persona's count gating all of them.
SENT="$HERE/sentinel.sh"
grep -qx 'for f in \$FAYTHS; do' "$SENT" \
  && ok "the summon loop is unconditional, at top level" \
  || bad "the summon loop is unconditional" "no top-level 'for f in \$FAYTHS; do' in sentinel.sh"

loop_at="$(grep -n '^for f in \$FAYTHS; do' "$SENT" | head -1 | cut -d: -f1)"
goal_at="$(grep -n '^if \[ "\$GOAL_REACHED" = 1 \]' "$SENT" | head -1 | cut -d: -f1)"
if [ -n "$loop_at" ] && [ -n "$goal_at" ] && [ "$loop_at" -lt "$goal_at" ]; then
    ok "a finished plan does not skip the summon"
else
    bad "a finished plan does not skip the summon" "loop at [$loop_at], goal exit at [$goal_at]"
fi

# And no persona's readiness is read from a hardcoded label anywhere in the summon path.
nowant "summon_fayth hardcodes no partition" "spira,plan" \
  "$(sed -n '/^summon_fayth() {/,/^}/p' "$HERE/lib.sh")"
nowant "fayth_ready hardcodes no partition"  "spira," \
  "$(sed -n '/^fayth_ready() {/,/^}/p' "$HERE/lib.sh")"

# ======================================================================================
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
