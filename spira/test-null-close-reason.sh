#!/usr/bin/env bash
#
# test-null-close-reason.sh — bd-update-closed-guard.sh refuses `bd update --status closed`
#   in aeon sessions, and stays quiet for `bd close` and for non-aeon sessions.
#
# POSITIVE CONTROL FIRST (law-absence-needs-a-positive-control): the guard MUST fire
# on the exact invocation that produced 44 beads with close_reason = NULL before any
# negative control runs. Silence from the negative controls is then evidence the guard
# works, not that it never could.
#
# THE CALLER IS NAMED: aeon model sessions — specifically commit 5cm1a8a0 (2026-09-09
# 12:41:07, author aeon-shiva) closed sp-vws3h via `bd update --status closed` instead
# of `bd close --reason-file -`. The spike (sp-7bvay) established that NULL close_reason
# can only come from `bd update --status closed`; this bead confirmed the caller.
#
# law-a-regression-test-must-be-seen-to-fail: run this suite against the pre-fix tree
# (without bd-update-closed-guard.sh installed as a PreToolUse hook) and confirm that
# the POSITIVE CONTROL cases below report FAIL before the guard is in place.
#
# defect: sp-ic4jc
# covers: spira/bd-update-closed-guard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()      { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()     { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()    { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "wanted [$2] in [$3]"; esac; }
nowant()  { case "$3" in *"$2"*) bad "$1" "did not want [$2] in [$3]" ;; *) ok "$1"; esac; }
wantrc()  { if [ "$3" -eq "$2" ]; then ok "$1"; else bad "$1" "wanted rc=$2, got rc=$3"; fi; }

echo "test-null-close-reason.sh"

GUARD="$HERE/bd-update-closed-guard.sh"
[ -f "$GUARD" ] || { printf 'SKIP bd-update-closed-guard.sh not found at %s\n' "$GUARD"; exit 77; }

# run_guard <command> [KEY=VAL ...] -> combined stdout+stderr, returns the guard's exit code.
# Builds the PreToolUse JSON, pipes it to the guard with SPIRA_AEON=1 (simulating an aeon
# session), and optionally with extra KEY=VAL overrides.
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

# run_guard_no_aeon: same but WITHOUT SPIRA_AEON, simulating a brain/maintenance session.
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
echo "POSITIVE CONTROL — exact invocation that closed 44 beads with close_reason = NULL"
# ==========================================================================
# aeon-shiva used this form to close sp-vws3h (commit 5cm1a8a0, 2026-09-09 12:41:07).
# This must fire; silence here means the guard could never have caught those 44 beads.

out=$(run_guard 'bd -C /workspaces/spira update sp-vws3h --status closed' || true)
want "bd update --status closed refused in aeon"         "BLOCKED by bd-update-closed-guard" "$out"
want "names bd close as the correct tool"                "bd close"                           "$out"
want "names BD_UPDATE_CLOSED_OVERRIDE"                   "BD_UPDATE_CLOSED_OVERRIDE"          "$out"
rc=0; run_guard 'bd -C /workspaces/spira update sp-vws3h --status closed' >/dev/null 2>&1 || rc=$?
wantrc "guard exits 2 to block the tool call"            2                                    "$rc"

# Short-path bd (no -C, no absolute path)
out=$(run_guard 'bd update sp-abc --status closed' || true)
want "short-path bd update refused"                      "BLOCKED by bd-update-closed-guard" "$out"

# Absolute path to bd binary
out=$(run_guard '/workspaces/gt/settings/bin/bd update sp-abc --status closed' || true)
want "absolute-path bd update refused"                   "BLOCKED by bd-update-closed-guard" "$out"

# With env var prefix (BEADS_ACTOR=aeon-foo)
out=$(run_guard 'BEADS_ACTOR=aeon-foo bd -C /db update sp-abc --status closed' || true)
want "env-prefixed bd update refused"                    "BLOCKED by bd-update-closed-guard" "$out"

# --status=closed (equals sign form)
out=$(run_guard 'bd update sp-abc --status=closed' || true)
want "bd update --status=closed refused"                 "BLOCKED by bd-update-closed-guard" "$out"

# ==========================================================================
echo
echo "NEGATIVE CONTROL — bd close is the sanctioned path and must not be blocked"
# ==========================================================================

out=$(run_guard 'bd -C /workspaces/spira close sp-abc --reason-file -' || true)
nowant "bd close --reason-file - not blocked"            "BLOCKED"                           "$out"

out=$(run_guard 'bd close sp-abc --reason "done"' || true)
nowant "bd close --reason not blocked"                   "BLOCKED"                           "$out"

out=$(run_guard 'bd -C /db close sp-abc --force --reason "Verified"' || true)
nowant "bd close --force not blocked"                    "BLOCKED"                           "$out"

# ==========================================================================
echo
echo "NEGATIVE CONTROL — bd update --status open is used by release_own_claim and must pass"
# ==========================================================================

out=$(run_guard 'bdq update sp-abc --status open --assignee ""' || true)
nowant "bd update --status open not blocked"             "BLOCKED"                           "$out"

out=$(run_guard 'bd update sp-abc --status in_progress' || true)
nowant "bd update --status in_progress not blocked"      "BLOCKED"                           "$out"

# ==========================================================================
echo
echo "non-aeon sessions are not blocked"
# ==========================================================================
# A brain session or maintenance session without SPIRA_AEON must not be blocked;
# test fixtures seed pre-closed beads and run without SPIRA_AEON.

out=$(run_guard_no_aeon 'bd update sp-abc --status closed' || true)
nowant "no SPIRA_AEON: update --status closed not blocked" "BLOCKED"                         "$out"

# ==========================================================================
echo
echo "override is honoured"
# ==========================================================================

out=$(run_guard 'bd update sp-abc --status closed' BD_UPDATE_CLOSED_OVERRIDE=1 || true)
nowant "env override passes"                             "BLOCKED"                           "$out"

out=$(run_guard 'BD_UPDATE_CLOSED_OVERRIDE=1 bd update sp-abc --status closed' || true)
nowant "inline override passes"                          "BLOCKED"                           "$out"

# ==========================================================================
echo
echo "prose and single-quoted spans are not refused"
# ==========================================================================

out=$(run_guard "echo 'never use bd update --status closed'" || true)
nowant "single-quoted prose not blocked"                 "BLOCKED"                           "$out"

out=$(run_guard 'cat > note.md <<'"'"'EOF'"'"'
Do NOT use: bd update --status closed
EOF' || true)
nowant "heredoc prose not blocked"                       "BLOCKED"                           "$out"

# ==========================================================================
echo
echo "non-Bash tools pass through"
# ==========================================================================
out=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Read", "tool_input": {"file_path": "/tmp/test.sh"}}))
' | env -i PATH="$PATH" HOME="$HOME" SPIRA_AEON=1 bash "$GUARD" 2>&1) || true
nowant "non-Bash tool not blocked"                       "BLOCKED"                           "$out"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
