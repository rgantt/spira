#!/usr/bin/env bash
#
# test-elastic-ceiling.sh — an elastic persona may not take the last fleet slot while a
#   non-elastic task persona has ready work.
#
#   ./test-elastic-ceiling.sh
#
# ACCEPTANCE CRITERIA (bead sp-2dz47):
#   1. REFUSED: fleet N, N-1 live, non-elastic has ready work → elastic summon refused
#   2. POSITIVE CONTROL: same fleet state, no non-elastic ready work → elastic succeeds
#   3. TWO FREE SLOTS: elastic succeeds even with non-elastic ready work (rule binds last slot only)
#   4. NON-ELASTIC: non-elastic persona with one slot free always succeeds (rule is elastic-only)
#
# WHAT THIS IS NOT. This does not test the pool ordering (sp-8m9bp); it tests that the
# reservation holds at the fleet ceiling regardless of evaluation order.
#
# COST STATED. The elastic check calls fayth_ready per non-elastic task persona, but only
# when slots_free == 1 and the candidate is elastic. The mock counts fayth_ready calls so
# the test can assert this property directly.
#
# covers: spira/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "${2:-}"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant(){ [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/run" "$T/chamber" "$T/bin"

# A MINIMAL ENVIRONMENT, non-default everywhere so that assertions cannot pass by reading
# literals out of conf.sh (law-gates-run-in-a-clean-environment).
export SPIRA_RUN="$T/run"
export SPIRA_CONF="$T/no-such.conf"
export SPIRA_HOME="$T"
export SPIRA_DB="$T/no-db"

. "$HERE/lib.sh"

# ======================================================================================
# TWO SYNTHETIC FAYTHS: one elastic task persona, one non-elastic task persona.
# Neither is named "builder" or "ops" — the rule must bind to the declaration, not the
# name. FAYTH_ELASTIC=1 identifies the elastic one; absence of it identifies the fixed one.
# ======================================================================================
cat > "$T/chamber/stretchy.fayth" <<'F'
FAYTH_NAME=stretchy
FAYTH_LABELS="test,plan"
FAYTH_EXCLUDE_LABELS="test-poison"
FAYTH_MAX_CONCURRENT=4
FAYTH_ELASTIC=1
FAYTH_HEARTBEAT_SECONDS=120
F

cat > "$T/chamber/anchor.fayth" <<'F'
FAYTH_NAME=anchor
FAYTH_LABELS="test,incident"
FAYTH_EXCLUDE_LABELS="test-poison"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=60
F

export SPIRA_FAYTHS="anchor stretchy"

# ======================================================================================
# STUBS. No real database, no real systemd, no real process table.
#
# fayth_ready_calls tracks how many times fayth_ready was invoked, keyed by persona,
# so the cost assertion can verify the per-non-elastic-fayth query count.
# ======================================================================================
MOCK_LIVE=0
aeons_live_total() { printf '%d' "$MOCK_LIVE"; }
aeon_count()       { printf '0'; }
capacity_paused()  { return 1; }   # no outage

# Per-fayth ready counts. Keyed by fayth name; default 0.
MOCK_READY_stretchy=0
MOCK_READY_anchor=0
# Call counts are written to a file because fayth_ready is called inside $() subshells
# and a variable increment would not be visible to the parent shell.
FAYTH_READY_CALL_FILE="$T/fayth-ready-calls"
fayth_ready() {
    printf '%s\n' "$1" >> "$FAYTH_READY_CALL_FILE"
    local _n; _n="MOCK_READY_${1}"
    printf '%d' "${!_n:-0}"
}
fayth_ready_call_count() { grep -c . "$FAYTH_READY_CALL_FILE" 2>/dev/null || printf '0'; }
reset_call_count() { : > "$FAYTH_READY_CALL_FILE"; }

SUMMONED="$T/summoned.log"
cat > "$T/bin/mock-summon" <<'MOCK'
#!/usr/bin/env bash
fayth="${@: -1}"
[ "$fayth" = "--dry-run" ] && fayth="${@: -2:1}"
printf 'SUMMONED:%s\n' "$fayth" >> "$SUMMONED_FILE"
exit 0
MOCK
chmod +x "$T/bin/mock-summon"
export SPIRA_SUMMON="$T/bin/mock-summon"
export SUMMONED_FILE="$SUMMONED"

# Fleet ceiling: 3 slots total.
export SPIRA_MAX_LIVE_AEONS=3

# ======================================================================================
echo
echo "criterion 1 — elastic refused when last slot and non-elastic has ready work"
# ======================================================================================
# N=3, N-1=2 live, 1 slot free. anchor (non-elastic) has ready work.
# stretchy (elastic) must be refused; anchor would succeed.
#
# POSITIVE CONTROL runs first so that "stretchy refused" cannot pass by a broken
# summon path that refuses everything.

# Positive control for the control: with 2 free slots, stretchy IS summoned despite
# anchor having ready work (two-free-slots criterion tested again here for ordering).
MOCK_LIVE=1     # 3-1=2 free slots
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth stretchy 4 >/dev/null 2>&1 || true
is "positive: elastic succeeds with 2 free slots (anchor also ready)" \
   "SUMMONED:stretchy" "$(cat "$SUMMONED" 2>/dev/null)"

# Now set N-1=2 live → exactly 1 slot free. anchor has work → stretchy must be refused.
MOCK_LIVE=2     # 3-2=1 free slot
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth stretchy 4 >/dev/null 2>&1 || true
is "criterion 1: elastic refused when last slot and non-elastic has ready work" \
   "absent" "$( [ -f "$SUMMONED" ] && cat "$SUMMONED" || echo absent )"

# Verify the log names the reason and the persona being reserved for.
MOCK_LIVE=2
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
log_out="$(summon_fayth stretchy 4 2>&1 || true)"
want  "log names 'held back'"         "held back"      "$log_out"
want  "log names the reserved fayth"  "anchor"         "$log_out"
nowant "log says 'at concurrency cap'"  "at concurrency cap" "$log_out"

# ======================================================================================
echo
echo "criterion 2 — positive control: elastic succeeds when no non-elastic has ready work"
# ======================================================================================
# Same fleet state (N-1 live, 1 slot free), but anchor has NO ready work.
# stretchy must be summoned.
MOCK_LIVE=2     # 1 slot free
MOCK_READY_anchor=0
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth stretchy 4 >/dev/null 2>&1 || true
is "criterion 2: elastic succeeds when no non-elastic has work (positive control)" \
   "SUMMONED:stretchy" "$(cat "$SUMMONED" 2>/dev/null)"

# ======================================================================================
echo
echo "criterion 3 — two free slots: elastic succeeds even with non-elastic ready work"
# ======================================================================================
# N=3, 1 live → 2 free slots. The rule binds only the last slot.
MOCK_LIVE=1     # 3-1=2 free slots
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth stretchy 4 >/dev/null 2>&1 || true
is "criterion 3: elastic succeeds with 2 free slots despite non-elastic ready work" \
   "SUMMONED:stretchy" "$(cat "$SUMMONED" 2>/dev/null)"

# ======================================================================================
echo
echo "criterion 4 — non-elastic persona is never refused by this rule"
# ======================================================================================
# Fleet at exactly 1 free slot. anchor (non-elastic) must succeed regardless.
MOCK_LIVE=2     # 1 slot free
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth anchor >/dev/null 2>&1 || true
is "criterion 4: non-elastic persona succeeds with 1 slot free" \
   "SUMMONED:anchor" "$(cat "$SUMMONED" 2>/dev/null)"

# ======================================================================================
echo
echo "cost assertion — fayth_ready not called for non-elastic personas when 2+ slots free"
# ======================================================================================
# WHAT WE ARE MEASURING. The reservation check calls fayth_ready per non-elastic task
# persona, but only when slots_free == 1 and the candidate is elastic. When slots_free >= 2
# the loop is never entered, so the per-persona query cost is zero.
#
# fayth_ready calls are written to a file (subshells cannot update parent variables).
# The file name is keyed by fayth, so we can distinguish reservation calls from the
# candidate's own readiness call at line r=$(fayth_ready "$f").

# REFUSED case (1 slot, non-elastic has work): fayth_ready called for anchor (reservation)
# then function returns 1 — stretchy's own readiness check at line 1047 is never reached.
export SPIRA_MAX_LIVE_AEONS=3
reset_call_count
MOCK_LIVE=2
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth stretchy 4 >/dev/null 2>&1 || true
# 1 call: anchor's reservation check. Stops there — function already returned 1.
is "cost: refused case makes exactly 1 fayth_ready call (anchor reservation only)" \
   "1" "$(fayth_ready_call_count)"
is "cost: that call was for anchor" \
   "anchor" "$(cat "$FAYTH_READY_CALL_FILE" 2>/dev/null)"

# 2-FREE-SLOT case: reservation loop not entered; only stretchy's own readiness called.
reset_call_count
MOCK_LIVE=1     # 2 free slots
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth stretchy 4 >/dev/null 2>&1 || true
# 1 call: stretchy's own readiness at line r=$(fayth_ready "$f"); anchor never queried.
is "cost: 2-free-slot path makes 1 fayth_ready call (stretchy only, no reservation)" \
   "1" "$(fayth_ready_call_count)"
is "cost: that call was for stretchy (not anchor)" \
   "stretchy" "$(cat "$FAYTH_READY_CALL_FILE" 2>/dev/null)"

# ======================================================================================
echo
echo "no ceiling — SPIRA_MAX_LIVE_AEONS unset means today's behaviour exactly"
# ======================================================================================
unset SPIRA_MAX_LIVE_AEONS
MOCK_LIVE=999   # any live count
MOCK_READY_anchor=1
MOCK_READY_stretchy=1
rm -f "$SUMMONED"
summon_fayth stretchy 4 >/dev/null 2>&1 || true
is "no ceiling: elastic succeeds when SPIRA_MAX_LIVE_AEONS is unset" \
   "SUMMONED:stretchy" "$(cat "$SUMMONED" 2>/dev/null)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
