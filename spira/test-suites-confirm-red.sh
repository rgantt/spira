#!/usr/bin/env bash
#
# test-suites-confirm-red.sh — the timed runner strips runner-injected variables from
# each suite's primary launch; env-sensitive suites pass cleanly instead of filing false
# alarms. A genuinely broken suite still files a suite defect. A suite that goes red
# but cannot be confirmed before the budget expires is recorded as red-unconfirmed
# without filing a bead.
#
# WHAT THIS GUARDS. The timed runner's systemd unit injects SPIRA_HOME (and other
# RUNNER_VARS) into every suite it starts. Before sp-mug21, a suite that failed because
# SPIRA_HOME was set filed a bead an aeon cannot reproduce — the bead's reproduce line
# runs without SPIRA_HOME and comes back green. The fix (sp-mug21) strips RUNNER_VARS
# from each suite's primary launch so the mismatch cannot form in the first place: an
# env-sensitive suite passes under the runner rather than going red and filing a bead
# nobody can act on. The confirming-run machinery remains in place for the cases where
# a suite fails in the primary launch despite RUNNER_VARS being stripped.
#
# defect: sp-ezs7o sp-xw80r
# covers: spira/suites.sh spira/incident.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"

# RUNNER-INJECTED VARIABLES. The systemd unit injects SPIRA_HOME and SPIRA_SUITES_MAXSEC
# into this suite's environment. testdb.sh (sourced below) always sources conf.sh, and
# conf.sh uses SPIRA_HOME to resolve SPIRA_REPO — pointing it at the production checkout.
# That exports SPIRA_BD and SPIRA_RUN pointing at production rather than the fixture,
# which can shadow what testdb_up sets and break the test. The confirming run strips both;
# unset them here to match that environment.
unset SPIRA_HOME SPIRA_SUITES_MAXSEC

pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-suites-confirm-red.sh"

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-suites-confirm-red
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up suites-confirm-red || { echo "test-suites-confirm-red: could not build fixture database"; exit 1; }

SH="$TMP/spira"; RUN="$TMP/run"; STATE="$TMP/state"; GATEF="$TMP/gate-suites"
mkdir -p "$SH" "$RUN" "$STATE" "$TMP/home" "$TMP/repo"
cp "$HERE/suites.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/incident.sh" "$SH/"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TMP/ask.log" > "$SH/ask.sh"
chmod +x "$SH/ask.sh"

BUDGET=120; PERSUITE=20; STALE=3600; PRIO=3; REPONAME=fixture-repo
TOOLPATH="$TMP/bin"; mkdir -p "$TOOLPATH"
printf '#!/usr/bin/env bash\nHOME=%s exec %s "$@"\n' "$HOME" "$(type -P bd)" > "$TOOLPATH/bd"
chmod +x "$TOOLPATH/bd"

# RUNNER_VARS=SPIRA_HOME so the test controls exactly one variable. The default also includes
# SPIRA_SUITES_MAXSEC which is not exercised here; naming only SPIRA_HOME makes the primary
# launch strip only SPIRA_HOME, and the env-sensitive suite detects exactly that variable.
RUNNER_VAR="SPIRA_HOME"

# sut: run suites.sh in an environment that includes SPIRA_HOME (simulating the systemd unit).
# suites.sh strips RUNNER_VARS from each suite's primary launch (sp-mug21), so the injected
# SPIRA_HOME is visible to suites.sh itself (for confirming-run logic) but not to the suites.
sut() {
    local cmd="$1"; shift
    env -i PATH="$PATH" HOME="$TMP/home" \
        SPIRA_CONF="$TMP/no-such.conf" \
        SPIRA_HOME="$SH" SPIRA_REPO="$TMP/repo" SPIRA_HOME_REPO="$REPONAME" \
        SPIRA_DB="$SPIRA_DB" SPIRA_RUN="$RUN" \
        SPIRA_SUITES_STATE="$STATE" SPIRA_GATE_SUITES="$GATEF" \
        SPIRA_SUITES_BUDGET="$BUDGET" SPIRA_SUITE_TIMEOUT="$PERSUITE" \
        SPIRA_SUITES_STALE="$STALE" SPIRA_SUITES_PRIORITY="$PRIO" \
        SPIRA_NOTIFY="$SH/ask.sh" \
        SPIRA_PATH="$TOOLPATH" \
        SPIRA_SUITES_RUNNER_VARS="$RUNNER_VAR" \
        SPIRA_INCIDENT_LOCK_WAIT="60" \
        "$@" bash "$SH/suites.sh" "$cmd" 2>&1
}
plant() { cat > "$SH/$1"; chmod +x "$SH/$1"; }
B() { bd -C "$SPIRA_DB" "$@"; }
beads_with() {
    B list --status open,in_progress --limit 0 --json 2>/dev/null \
        | sed -n '/^[[{]/,$p' \
        | python3 -c '
import sys, json
key = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d, list) else [d]):
    if key in (i.get("title") or ""): print(i["id"])
' "$1"
}
count() { printf '%s\n' "$1" | grep -c . || true; }

# Gate file: one gated suite so timed set is non-empty.
printf '#!/usr/bin/env bash\nexit 0\n' > "$SH/test-cx-gated.sh"
printf 'spira/test-cx-gated.sh\n' > "$GATEF"

# ======================================================================================
echo
echo "an env-sensitive suite passes cleanly (RUNNER_VARS stripped from primary launch):"
# ======================================================================================
# THE PLANTED SUITE fails when SPIRA_HOME is set and passes when it is absent. Under the
# timed runner, suites.sh strips SPIRA_HOME from the suite's primary launch environment
# (sp-mug21), so the suite passes — the mismatch cannot form in the first place.
plant test-cx-env-sensitive.sh <<'S'
#!/usr/bin/env bash
# covers: spira/nothing.sh
[ -z "${SPIRA_HOME:-}" ] && exit 0
printf '  FAIL  SPIRA_HOME is set: %s\n' "$SPIRA_HOME"
exit 1
S

# POSITIVE CONTROL. Before trusting "the suite passed under the runner", prove it IS
# sensitive to SPIRA_HOME when the variable is set — otherwise a suite that always exits 0
# would produce the same pass appearance (law-absence-needs-a-positive-control).
_pc_rc=0
SPIRA_HOME="$SH" bash "$SH/test-cx-env-sensitive.sh" >/dev/null 2>&1 || _pc_rc=$?
is "positive control: env-sensitive suite fails when SPIRA_HOME is set" "1" "$_pc_rc"

out="$(sut run)"
# The suite appears in the output and is labelled ok — RUNNER_VARS were stripped.
want "the env-sensitive suite is labelled ok (RUNNER_VARS stripped)" \
    "test-cx-env-sensitive.sh   ok" "$out"
nowant "its output line does not say RED" " RED " "$out"
nowant "its output line does not say ENV-MISMATCH" "ENV-MISMATCH" "$out"

# No bead of any kind: no red was detected, so nothing to file.
env_ids="$(beads_with 'passes in an aeon')"
is "no environment-finding bead is filed (no red occurred)" "0" "$(count "$env_ids")"
suite_ids="$(beads_with 'test-cx-env-sensitive.sh is red in the timed suite run')"
is "no suite-defect bead is filed" "0" "$(count "$suite_ids")"

# ======================================================================================
echo
echo "a genuinely broken suite still files a suite defect (not suppressed by confirming run):"
# ======================================================================================
# POSITIVE CONTROL. A suite that fails regardless of SPIRA_HOME must still be filed as a
# suite defect — the primary launch (RUNNER_VARS stripped) finds it red, the confirming
# run (also without RUNNER_VARS) finds it red too, so it goes through the confirmed-red path.
plant test-cx-always-red.sh <<'S'
#!/usr/bin/env bash
# covers: spira/nothing.sh
printf '  FAIL  this suite is broken regardless of SPIRA_HOME\n'
exit 1
S

out2="$(sut run)"
# The env-sensitive suite (still planted) will also appear as ok; only assert
# that test-cx-always-red.sh specifically shows RED in its output line.
want "a genuinely broken suite is labelled RED in its output line" \
    "test-cx-always-red.sh      RED" "$out2"
nowant "and its output line does not say ENV-MISMATCH" \
    "test-cx-always-red.sh      ENV-MISMATCH" "$out2"

suite_ids2="$(beads_with 'test-cx-always-red.sh is red in the timed suite run')"
is "a suite-defect bead is filed for the genuinely broken suite" "1" "$(count "$suite_ids2")"
env_ids2="$(beads_with "test-cx-always-red.sh is red under the timed runner but passes")"
is "no environment-finding bead is filed for it" "0" "$(count "$env_ids2")"

# ======================================================================================
echo
echo "when budget is exhausted after the suite runs, file nothing and record red-unconfirmed:"
# ======================================================================================
# THE CONFIRMING RUN TAKES TIME. The budget check `left <= 5` fires AFTER the suite has
# finished but BEFORE the confirming run starts. If the suite consumes most of the budget,
# there is no room for a confirming run; the result is recorded but no bead is filed.
# STRATEGY: run this test with a clean timed set so previous suites do not consume budget.
rm -f "$SH/test-cx-always-red.sh" "$SH/test-cx-env-sensitive.sh"

# Budget-sensitive suite: always fails (independent of SPIRA_HOME) but sleeps to consume
# budget, so that left ≤ 5 when it exits and the confirming run cannot start.
plant test-cx-budget-red.sh <<'S'
#!/usr/bin/env bash
# covers: spira/nothing.sh
sleep 3
printf '  FAIL  this suite always fails (budget exhaustion test)\n'
exit 1
S

# BUDGET=7: suite starts (left=7 > 5), runs for 3s, exits. left ≈ 4 ≤ 5.
# SPIRA_HOME is set in sut()'s environment, so confirm_differing is non-empty; the
# budget check fires before the confirming run starts → red-unconfirmed.
BUDGET=7
rm -f "$STATE/test-cx-budget-red.sh.result"
out3="$(sut run)"
BUDGET=120
want "when no budget for confirming run, output says so" "RED-UNCONFIRMED" "$out3"
# Nothing should be filed since we cannot confirm whether this is a defect or env-only.
budget_suite_ids="$(beads_with 'test-cx-budget-red.sh')"
is "no bead is filed for an unconfirmed red" "0" "$(count "$budget_suite_ids")"
# The result file IS written, as red-unconfirmed, so the next pass tries again.
red_status="$(awk '{print $1}' "$STATE/test-cx-budget-red.sh.result" 2>/dev/null || echo -)"
is "the result file records red-unconfirmed" "red-unconfirmed" "$red_status"

# ======================================================================================
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
