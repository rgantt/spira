#!/usr/bin/env bash
#
# test-skew-escalate.sh — escalate() outputs failures to stdout; a silent failure is
# indistinguishable from a quiet-because-nothing-happened pass.
#
#   ./test-skew-escalate.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# escalate() in skew.sh was swallowing both streams of the SPIRA_NOTIFY call
# (>/dev/null 2>&1), so a failing ask.sh produced no output in skew.log and the
# divergence went unreported for an entire day while the timer ran every hour.
# This suite proves the fix: a failing notify, and a missing notify path, both
# produce output on stdout and return non-zero.
#
# THE POSITIVE CONTROL IS FIRST (law-absence-needs-a-positive-control). Before
# claiming the check catches escalation failure, prove the escalation path is
# reached at all: a successful notify must produce output on stdout. A check that
# always claims "escalation failed" would pass every subsequent assertion without
# proving the path was exercised.
#
# THE FIXTURE IS A REAL GIT REPO with the harness signature files (boundary,
# gate.sh, lib.sh) committed and one tracked file modified, so check() reaches
# the DIRTY path and calls escalate(). No shared state with the installed harness
# is used (law-gates-run-in-a-clean-environment).
#
# covers: spira/skew.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-skew-escalate.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a minimal git repo that passes harness_in's positive control.
#
# harness_in() requires files named boundary, gate.sh, and lib.sh in the same
# directory (scope_from_paths in exclude.sh checks for exactly those three).
# We commit them, then modify one so check() reaches the DIRTY path and calls
# escalate(). A fake install.sh is added so the STALE check does not produce a
# CANNOT-DIFF soft finding (which would otherwise hide whether hard=1 was set).
# ---------------------------------------------------------------------------
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config user.email "test@test"
git -C "$REPO" config user.name "test"
mkdir -p "$REPO/spira" "$REPO/systemd"

# Harness signature files. scope_from_paths needs all three in the same dir.
printf '# harness boundary\n'  > "$REPO/spira/boundary"
printf '#!/usr/bin/env bash\n' > "$REPO/spira/gate.sh"
printf '#!/usr/bin/env bash\n' > "$REPO/spira/lib.sh"

# A stub install.sh that always says "units match". Prevents CANNOT-DIFF from
# adding a soft finding that would suppress the escalation call.
cat > "$REPO/systemd/install.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--diff" ] && { echo "stub: installed units match what this box renders"; exit 0; }
echo "stub install.sh"; exit 0
EOF
chmod +x "$REPO/systemd/install.sh"

git -C "$REPO" add spira/ systemd/
git -C "$REPO" commit -q -m "fixture: harness signature"

# Make the repo dirty: modify a tracked file so check() finds a DIRTY finding
# and calls escalate().
printf '# modified\n' >> "$REPO/spira/lib.sh"

# A skew.sh runner with an explicit minimal environment. Each call uses its own
# SPIRA_RUN directory (created with mktemp) so the dedupe stamp never suppresses
# a second escalation in the same test run. HOME is required by conf.sh for the
# SPIRA_DB default.
run_skew() {
    local run_dir
    run_dir="$(mktemp -d "$TMP/run-XXXXX")"
    env -i PATH="$PATH" \
        HOME="$TMP/home" \
        SPIRA_CONF=/nonexistent \
        SPIRA_HOME="$REPO/spira" \
        SPIRA_REPO="$REPO" \
        SPIRA_RUN="$run_dir" \
        SPIRA_DOLT_DATA="" \
        SPIRA_TESTDB_DATA="" \
        "${@}" \
        bash "$HERE/skew.sh" check 2>&1
    return "${PIPESTATUS[0]:-$?}"
}

# ===========================================================================
echo
echo "positive control — successful notify appears on stdout:"
# ===========================================================================
GOOD_NOTIFY="$TMP/good-notify.sh"
cat > "$GOOD_NOTIFY" <<'EOF'
#!/usr/bin/env bash
echo "sp-xxxx"
exit 0
EOF
chmod +x "$GOOD_NOTIFY"

good_out="$(run_skew SPIRA_NOTIFY="$GOOD_NOTIFY")"; good_rc=$?
# Divergence was found (DIRTY); exit 1 is correct.
is  "positive control exits 1 (divergence found)" "1" "$good_rc"
# The escalation confirmation must appear on stdout so skew.log has it.
want "positive control: escalation noted on stdout" "escalated" "$good_out"

# ===========================================================================
echo
echo "no escalation path — warning appears on stdout, not silently dropped:"
# ===========================================================================
# SPIRA_NOTIFY is a non-executable path. The finding must reach stdout so
# skew.log (which captures stdout) records it and the operator can see it.
no_path_out="$(run_skew SPIRA_NOTIFY=/nonexistent/ask.sh)"; no_path_rc=$?
is  "no-path exits 1 (divergence found)" "1" "$no_path_rc"
want "no-path warning appears on stdout" "no escalation path" "$no_path_out"
want "no-path output names the bad path" "/nonexistent/ask.sh" "$no_path_out"
# The old code returned 0 (silently) when no path was found. A failed escalation
# must not be treated as "escalation succeeded and everything is fine."
# This is enforced by check() itself: exit 1 means divergence found, regardless
# of whether the escalation worked.

# ===========================================================================
echo
echo "failing notify — failure message appears on stdout, returns non-zero:"
# ===========================================================================
BAD_NOTIFY="$TMP/bad-notify.sh"
cat > "$BAD_NOTIFY" <<'EOF'
#!/usr/bin/env bash
echo "bad-notify: simulated failure from test fixture" >&2
exit 1
EOF
chmod +x "$BAD_NOTIFY"

fail_out="$(run_skew SPIRA_NOTIFY="$BAD_NOTIFY")"; fail_rc=$?
is  "failing notify exits 1" "1" "$fail_rc"
want "failing notify message on stdout"  "escalation failed" "$fail_out"
want "failing notify rc included"        "rc=1"              "$fail_out"
# The notify's own stderr must appear in the output — not swallowed.
want "failing notify output included"    "simulated failure" "$fail_out"

# ===========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
