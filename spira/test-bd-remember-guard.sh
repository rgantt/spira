#!/usr/bin/env bash
#
# test-bd-remember-guard.sh — bd-remember-guard.sh refuses `bd remember sop-*` and
#   `bd remember law-*` in aeon sessions, and honours its named override.
#
# POSITIVE CONTROL FIRST (law-absence-needs-a-positive-control): the guard MUST fire
# on the exact back-door write that produced the six empty SOPs before any negative
# control runs. Silence from the negative controls is then evidence the guard works,
# not that it never could.
#
# The exact pattern driven here is the write that produced sop-escalation-body-is-a-slug
# and five peers: `bd remember --key sop-<slug> -` when stdin is empty, which stored the
# literal string `-` as the SOP body, failing lint for three required fields.
#
# law-a-regression-test-must-be-seen-to-fail: run this suite against the pre-fix tree
# (without bd-remember-guard.sh installed as a PreToolUse hook) and confirm that the
# POSITIVE CONTROL cases below report FAIL before the guard is in place.
#
# defect: sp-36dc8
# covers: spira/bd-remember-guard.sh spira/sop.sh rule.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "wanted [$2] in [$3]"; esac; }
nowant() { case "$3" in *"$2"*) bad "$1" "did not want [$2] in [$3]" ;; *) ok "$1"; esac; }

echo "test-bd-remember-guard.sh"

GUARD="$HERE/bd-remember-guard.sh"
[ -f "$GUARD" ] || { printf 'SKIP bd-remember-guard.sh not found at %s\n' "$GUARD"; exit 77; }

# run_guard <command> [KEY=VAL ...] -> combined stdout+stderr, returns the guard's exit code.
# Builds the PreToolUse JSON, pipes it to the guard with SPIRA_AEON=1 in the environment
# (simulating an aeon session), and optionally with extra KEY=VAL overrides.
run_guard() {
    local cmd="$1"; shift
    local rc out
    out=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$cmd" | env -i PATH="$PATH" HOME="$HOME" SPIRA_AEON=1 "$@" bash "$GUARD" 2>&1); rc=$?
    printf '%s' "$out"
    return "$rc"
}

# run_guard_no_aeon: same but WITHOUT SPIRA_AEON, simulating a brain / maintenance session.
run_guard_no_aeon() {
    local cmd="$1"; shift
    local rc out
    out=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$cmd" | env -i PATH="$PATH" HOME="$HOME" "$@" bash "$GUARD" 2>&1); rc=$?
    printf '%s' "$out"
    return "$rc"
}

# ==========================================================================
echo
echo "POSITIVE CONTROL — exact back-door write that produced the six empty SOPs"
# ==========================================================================
# The exact command an aeon used: bd remember --key sop-<slug> - (stdin empty).
# This must fire; silence here means the guard never could have caught the incident.

out=$(run_guard 'bd -C /some/db remember --key sop-escalation-body-is-a-slug -' || true)
want "bd remember --key sop-* refused in aeon"     "BLOCKED by bd-remember-guard" "$out"
want "names sop.sh write as the correct tool"      "sop.sh write"                 "$out"
want "names the override"                          "BD_REMEMBER_MANAGED_KEY_OVERRIDE" "$out"

out=$(run_guard 'bd -C /some/db remember --key law-my-statute "some text"' || true)
want "bd remember --key law-* refused in aeon"     "BLOCKED by bd-remember-guard" "$out"
want "names rule.sh enact as the correct tool"     "rule.sh enact"                "$out"

# ==========================================================================
echo
echo "POSITIVE CONTROL — positional key forms"
# ==========================================================================
out=$(run_guard 'bd remember sop-foo "body text here"' || true)
want "positional sop- key refused"                 "BLOCKED by bd-remember-guard" "$out"

out=$(run_guard 'bd remember law-foo "body"' || true)
want "positional law- key refused"                 "BLOCKED by bd-remember-guard" "$out"

out=$(run_guard 'bd -C /some/db remember sop-reclaim-loop "text"' || true)
want "bd -C path remember sop- refused"            "BLOCKED by bd-remember-guard" "$out"

# ==========================================================================
echo
echo "other keys are not refused"
# ==========================================================================
# `bd remember` on non-managed prefixes is unrestricted.

out=$(run_guard 'bd remember my-custom-key "some value"' 2>&1) || true
nowant "non-managed key not refused"               "BLOCKED"                       "$out"

out=$(run_guard 'bd remember meta-info "some value"' 2>&1) || true
nowant "meta- prefix not refused"                  "BLOCKED"                       "$out"

# ==========================================================================
echo
echo "override is honoured"
# ==========================================================================
out=$(run_guard 'bd remember sop-foo "body"' BD_REMEMBER_MANAGED_KEY_OVERRIDE=1 2>&1) || true
nowant "env override passes sop-"                  "BLOCKED"                       "$out"

out=$(run_guard 'BD_REMEMBER_MANAGED_KEY_OVERRIDE=1 bd remember sop-foo "body"' 2>&1) || true
nowant "inline override passes sop-"               "BLOCKED"                       "$out"

out=$(run_guard 'BD_REMEMBER_MANAGED_KEY_OVERRIDE=1 bd remember law-foo "body"' 2>&1) || true
nowant "inline override passes law-"               "BLOCKED"                       "$out"

# ==========================================================================
echo
echo "non-aeon sessions are not blocked"
# ==========================================================================
# A brain session or maintenance session without SPIRA_AEON must not be blocked.

out=$(run_guard_no_aeon 'bd remember sop-foo "body"' 2>&1) || true
nowant "no SPIRA_AEON: sop- not refused"           "BLOCKED"                       "$out"

out=$(run_guard_no_aeon 'bd remember law-foo "body"' 2>&1) || true
nowant "no SPIRA_AEON: law- not refused"           "BLOCKED"                       "$out"

# ==========================================================================
echo
echo "prose and single-quoted spans are not refused"
# ==========================================================================
out=$(run_guard "echo 'never use bd remember sop-foo'" 2>&1) || true
nowant "single-quoted prose not refused"           "BLOCKED"                       "$out"

out=$(run_guard 'cat > note.md <<'"'"'EOF'"'"'
Do NOT use: bd remember sop-foo or bd remember law-foo
EOF' 2>&1) || true
nowant "heredoc prose not refused"                 "BLOCKED"                       "$out"

# ==========================================================================
echo
echo "sop.sh write and rule.sh enact are not affected"
# ==========================================================================
# The sanctioned writers must not be blocked — they are the alternative named in the refusal.

out=$(run_guard 'bash spira/sop.sh write my-sop - <<< "SYMPTOM: x\nCHECK: y\nFIX: z"' 2>&1) || true
nowant "sop.sh write not blocked"                  "BLOCKED"                       "$out"

out=$(run_guard 'bash rule.sh enact my-law "Every agent must..."' 2>&1) || true
nowant "rule.sh enact not blocked"                 "BLOCKED"                       "$out"

# ==========================================================================
echo
echo "non-Bash tools pass through"
# ==========================================================================
out=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Read", "tool_input": {"file_path": "sop-foo.txt"}}))
' | env -i PATH="$PATH" HOME="$HOME" SPIRA_AEON=1 bash "$GUARD" 2>&1) || true
nowant "non-Bash tool not blocked"                 "BLOCKED"                       "$out"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
