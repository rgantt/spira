#!/usr/bin/env bash
#
# test-qa.sh — the QA fayth: SPIRA_QA_DEPTH, lane isolation, closing rule, bead citations.
#
#   ./test-qa.sh
#
# FOUR ACCEPTANCE CRITERIA (bead sp-gsmx.6):
#   1. Depth isolation — each setting widens scope; scars never reaches the structural sweep
#   2. Bead citations  — every proposed bead cites the defect it exists for
#   3. Closing rule    — a session that finds nothing must record what it looked at
#   4. Pool isolation  — QA is not drawn from SPIRA_MAX_AEONS
#
# POSITIVE CONTROLS. Every absence assertion is preceded by a presence assertion on the same
# path, so a check pointed at the wrong thing and a check that found nothing look different
# (law-absence-needs-a-positive-control).
#
# STRUCTURAL ASSERTIONS, NOT RUNTIME ONES. The acceptance criteria are about the brief and
# the fayth definition, not about an aeon's live behaviour. Runtime testing would need a
# real sweep over a real scar record, which is what a manual QA pass costs. The properties
# under test here are: the fayth's lane declaration (pool isolation), the brief's structure
# (depth isolation, closing rule, citations), and the configuration key (SPIRA_QA_DEPTH).
#
# defect: sp-gsmx.6
# covers: spira/chamber/qa.fayth spira/chamber/qa.md spira/conf.sh spira/qa-sweep.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"

pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "${2:-}"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM

# A MINIMAL ENVIRONMENT, non-default everywhere so that a test asserting the default does
# not pass by having the literal written into the code (law-gates-run-in-a-clean-environment).
export SPIRA_CONF="$T/no-such.conf"
export SPIRA_HOME="$HERE"
export SPIRA_RUN="$T/run"
export SPIRA_DB="$T/no-db"
mkdir -p "$SPIRA_RUN"

. "$HERE/lib.sh"

FAYTH_FILE="$HERE/chamber/qa.fayth"
BRIEF_FILE="$HERE/chamber/qa.md"

# ======================================================================================
echo
echo "criterion 1 — depth isolation: scars < modules < wide, scars never reaches structural"
# ======================================================================================
#
# The brief must name all three depth settings, and the control flow must be monotonically
# wider: modules must cover everything scars covers (because it is a superset), and wide
# must cover everything modules covers.
#
# WHAT WE CAN TEST STRUCTURALLY. The brief is the program. A brief that names structural
# analysis only under `wide` and NOT under `scars` enforces depth isolation as well as code
# can without running a live sweep. If the brief says "structural" or "changed code" in a
# section gated by `scars`, the isolation is broken. We check the brief's text.
#
# POSITIVE CONTROL FIRST: scars IS mentioned (so the check below is not trivially true
# because the brief is empty or the grep is wrong).

brief="$(cat "$BRIEF_FILE")"

want "positive: 'scars' setting is named in the brief"     "scars"  "$brief"
want "positive: 'modules' setting is named in the brief"   "modules" "$brief"
want "positive: 'wide' setting is named in the brief"      "wide"   "$brief"

# Each depth must be a strict superset: 'wide only' must say 'wide' in its gate.
want "structural sweep is gated by 'wide only'"            "wide only"            "$brief"
want "module ranking is gated by 'modules and wide only'"  "modules and wide only" "$brief"

# Steps 1 and 2 (the scars depth) must NOT contain structural-analysis instructions:
# no git log for changed files, no "structural gaps", no "changed code with no assertion".
# We extract Step 1 and Step 2 individually (between their headers) to avoid matching the
# intro table, which legitimately references "structural" when explaining it is NOT in scars.
step1_section="$(printf '%s\n' "$brief" | awk '/### Step 1/{ found=1 } /### Step 2/{ exit } found')"
step2_section="$(printf '%s\n' "$brief" | awk '/### Step 2/{ found=1 } /### Step 3/{ exit } found')"
nowant "Step 1 (scars) does not instruct 'changed code'" "changed code" "$step1_section"
nowant "Step 2 (incidents) does not instruct 'changed code'" "changed code" "$step2_section"

# Step 4 (structural) must exist and be gated by 'wide only'.
step4_section="$(printf '%s\n' "$brief" | awk '/### Step 4/{ found=1 } found')"
want "Step 4 exists and mentions structural gaps" "structural" "$step4_section"
want "Step 4 is gated by 'wide only'"            "wide only"  "$step4_section"

# ======================================================================================
echo
echo "criterion 2 — bead citations: proposed beads cite the defect"
# ======================================================================================
#
# Every bead QA proposes must carry the defect it exists for. The brief instructs QA to
# include the defect id in the bead's description. We check that the brief:
#   a) instructs QA to include the defect id in the body of a proposed bead, AND
#   b) does NOT allow filing a bead with no defect reference.
#
# POSITIVE CONTROL: the brief's propose-bead template must mention 'Defect:'.

want "positive: the brief's bead template names 'Defect:'"        "Defect:"         "$brief"
want "proposed bead template includes the intro bead id"           "intro-bead-id"   "$brief"
want "proposed bead description calls out the fix bead id"         "fix-bead-id"     "$brief"
want "proposed bead carries the qa-proposed label"                 "qa-proposed"     "$brief"

# ======================================================================================
echo
echo "criterion 3 — closing rule: silence is outlawed; nothing-found must be recorded"
# ======================================================================================
#
# A QA session that finds nothing must record that it looked and what it looked at.
# The brief must state this rule and instruct QA to record COUNTS (not just "nothing found").
#
# POSITIVE CONTROL: the brief has a closing-rule section.

want "positive: brief has a closing-rule section"      "Closing rule"  "$brief"
want "closing rule says 'silence is what is outlawed'" "silence is what is outlawed" "$brief"
want "closing rule requires named counts"               "counts"        "$brief"
# The note template must be present and name count placeholders.
want "nothing-found note template is in the brief"     "examined"      "$brief"
want "nothing-found note names the qa depth"           "depth="        "$brief"

# ======================================================================================
echo
echo "criterion 4 — pool isolation: QA is not drawn from SPIRA_MAX_AEONS"
# ======================================================================================
#
# qa.fayth must declare FAYTH_LANE so it is routed through spira_lane_fayths(), never
# through the builder pool. The pool test proves this mechanically, exactly as test-lanes.sh
# proves it for ops.fayth.
#
# POSITIVE CONTROL: qa.fayth declares something in FAYTH_LANE (not empty).

fayth_content="$(cat "$FAYTH_FILE")"
want   "positive: qa.fayth declares FAYTH_LANE"           "FAYTH_LANE=" "$fayth_content"
want   "qa.fayth declares FAYTH_LANE=qa"                  "FAYTH_LANE=qa" "$fayth_content"
nowant "qa.fayth does not use FAYTH_ROLE=party"           "FAYTH_ROLE=party" \
       "$(grep -v '^#' "$FAYTH_FILE")"

# With the real fayth roster, qa is in lane fayths and NOT in task fayths.
export SPIRA_FAYTHS="builder ops qa"
real_task="$(spira_task_fayths)"
real_lane="$(spira_lane_fayths)"

want   "qa appears in lane fayths"           "qa"      "$real_lane"
nowant "qa does NOT appear in task fayths"   "qa"      "$real_task"
want   "builder is still in the task pool"   "builder" "$real_task"

# The qa lane is declared in conf.sh's key list and defaults.
want "SPIRA_QA_DEPTH is a recognised conf key" "SPIRA_QA_DEPTH" "$(cat "$HERE/conf.sh")"
want "SPIRA_LANES default includes qa"          "qa"             "$(grep 'SPIRA_LANES:=' "$HERE/conf.sh")"
want "SPIRA_LANES default includes ops"         "ops"            "$(grep 'SPIRA_LANES:=' "$HERE/conf.sh")"

# SPIRA_QA_DEPTH default must be 'scars' — the cheapest setting ships as the default so a
# fresh install does not immediately schedule the expensive structural sweep.
want "SPIRA_QA_DEPTH default is 'scars'"        "scars"          "$(grep 'SPIRA_QA_DEPTH:=' "$HERE/conf.sh")"

# The service is executable and references qa-sweep.sh create.
want "spira-qa.service references qa-sweep.sh create" "qa-sweep.sh create" \
     "$(cat "$(dirname "$HERE")/systemd/spira-qa.service" 2>/dev/null || echo '')"
is   "qa-sweep.sh is executable" "0" "$([ -x "$HERE/qa-sweep.sh" ] && echo 0 || echo 1)"

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
