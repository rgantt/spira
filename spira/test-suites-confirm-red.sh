#!/usr/bin/env bash
#
# test-suites-confirm-red.sh — a red that passes in an aeon's environment files an
# environment finding, not a suite defect.
#
# WHAT THIS GUARDS. The timed runner's systemd unit injects SPIRA_HOME into every suite it
# starts. A suite that fails because SPIRA_HOME is set (e.g. by redirecting a repo-map lookup
# onto the installed copy) files a bead an aeon cannot reproduce — the bead's own reproduce
# line runs without SPIRA_HOME and comes back green. The aeon closes the bead truthfully,
# commits nothing, and the next pass files the same red again. This test requires that such a
# red is detected and filed as an environment finding, not as a suite defect (sp-ezs7o).
#
# THE KEY INVARIANT. For each red, suites.sh re-runs the suite once without runner-injected
# variables (RUNNER_VARS). If the second run passes, the finding is environmental. If it
# fails too, the suite is genuinely broken. This test uses planted suites that check whether
# SPIRA_HOME is set, so the invariant is directly observable.
#
# defect: sp-ezs7o
# covers: spira/suites.sh spira/incident.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
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
# SPIRA_SUITES_MAXSEC which is not exercised here; naming only SPIRA_HOME makes the confirming
# run strip only SPIRA_HOME, and the env-sensitive suite detects exactly that.
RUNNER_VAR="SPIRA_HOME"

# sut: run suites.sh in an environment that includes SPIRA_HOME (simulating the systemd unit).
# The SPIRA_HOME here points at the fixture's own spira dir, which is the runner-injected value
# that the confirming run must strip.
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
bead_body() {
    B show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
d = d[0] if isinstance(d, list) else d
print(d.get("description") or "")
' 2>/dev/null || true
}

# Gate file: one gated suite so timed set is non-empty.
printf '#!/usr/bin/env bash\nexit 0\n' > "$SH/test-cx-gated.sh"
printf 'spira/test-cx-gated.sh\n' > "$GATEF"

# ======================================================================================
echo
echo "an env-sensitive red files an environment finding, not a suite defect:"
# ======================================================================================
# THE PLANTED SUITE fails when SPIRA_HOME is set (the runner injects it) and passes when
# SPIRA_HOME is absent (the aeon's environment). The confirming run strips SPIRA_HOME;
# the suite passes there; suites.sh must file an ENV-MISMATCH finding, NOT a suite defect.
plant test-cx-env-sensitive.sh <<'S'
#!/usr/bin/env bash
# covers: spira/nothing.sh
[ -z "${SPIRA_HOME:-}" ] && exit 0
printf '  FAIL  SPIRA_HOME is set: %s\n' "$SPIRA_HOME"
exit 1
S

out="$(sut run)"
want "an env-sensitive red is labelled ENV-MISMATCH in the pass output" "ENV-MISMATCH" "$out"
nowant "and is not labelled RED (which would mislead an aeon)" " RED " "$out"
want "the pass output names the stripped variable" "$RUNNER_VAR" "$out"

# AN ENVIRONMENT FINDING, NOT A SUITE DEFECT.
env_ids="$(beads_with 'passes in an aeon')"
is "one environment-finding bead is filed" "1" "$(count "$env_ids")"
suite_ids="$(beads_with 'test-cx-env-sensitive.sh is red in the timed suite run')"
is "no suite-defect bead is filed" "0" "$(count "$suite_ids")"

env_id="$(printf '%s\n' "$env_ids" | head -1)"
if [ -n "$env_id" ]; then
    body="$(bead_body "$env_id")"
    want "the finding names the differing variable" "$RUNNER_VAR" "$body"
    want "it says an aeon should not reproduce it"  "Do not send an aeon" "$body"
fi

# THE ENV-MISMATCH COUNT IS IN THE SUMMARY.
want "the env-mismatch count appears in the summary" "env-mismatch" "$out"

# ======================================================================================
echo
echo "a genuinely broken suite still files a suite defect (not suppressed by confirming run):"
# ======================================================================================
# POSITIVE CONTROL. A suite that fails regardless of SPIRA_HOME must still be filed as a
# suite defect — the confirming run finds it red too, so it goes through the normal path.
plant test-cx-always-red.sh <<'S'
#!/usr/bin/env bash
# covers: spira/nothing.sh
printf '  FAIL  this suite is broken regardless of SPIRA_HOME\n'
exit 1
S

out2="$(sut run)"
# The env-sensitive suite (still planted) will also appear as ENV-MISMATCH; only assert
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

# Budget-sensitive suite: sleeps 3s (fast to fail but needs to TAKE time so left < 5 on exit).
plant test-cx-budget-red.sh <<'S'
#!/usr/bin/env bash
# covers: spira/nothing.sh
sleep 3
[ -z "${SPIRA_HOME:-}" ] && exit 0
printf '  FAIL  env-sensitive but budget is about to be zero\n'
exit 1
S

# BUDGET=7: suite starts (left=7 > 5), runs for 3s, exits. left ≈ 7-3=4 ≤ 5.
# No budget for confirming run → red-unconfirmed.
BUDGET=7
rm -f "$STATE/test-cx-budget-red.sh.result"
out3="$(sut run)"
BUDGET=120
want "when no budget for confirming run, output says so" "RED-UNCONFIRMED" "$out3"
# Nothing should be filed since we can't confirm whether it is a real defect or env-only.
budget_suite_ids="$(beads_with 'test-cx-budget-red.sh')"
is "no bead is filed for an unconfirmed red" "0" "$(count "$budget_suite_ids")"
# The result file IS written, as red-unconfirmed, so the next pass tries again.
red_status="$(awk '{print $1}' "$STATE/test-cx-budget-red.sh.result" 2>/dev/null || echo -)"
is "the result file records red-unconfirmed" "red-unconfirmed" "$red_status"

# ======================================================================================
echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
