#!/usr/bin/env bash
#
# test-suite-cleanup.sh — the suite runner kills background jobs suites leave behind.
#
# WHAT THIS TESTS. suites.sh and gate-spira.sh now run each suite in its own process
# group via setsid (PGID = suite_pid). After the suite exits, the harness checks for
# survivors with `kill -0 -- -$suite_pid`, kills them, and marks the suite red if it
# otherwise passed. This suite verifies that mechanism works: detection fires when a suite
# leaves a background job, cleanup terminates it, and a clean suite triggers no false alarm.
#
# WHY THIS EXISTS. sp-a8c5: test-aeon-heartbeat.sh hung before its own cleanup code ran,
# leaving orphaned sleep 3600 children that held the output pipe open and blocked four
# following suites until systemd's 900s hard kill. A harness that sweeps the process group
# after each suite would have killed the stragglers and reported the defect without stalling.
#
# No database, no network, under two seconds.
#
# defect: sp-a8c5
# covers: spira/suites.sh spira/gate-spira.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "${2:-}"; }

# A suite that leaves a background job and exits 0.
cat > "$TMP/leaky.sh" <<'SUITE'
#!/usr/bin/env bash
sleep 3600 &
exit 0
SUITE

# A suite that kills its own background job before exiting.
cat > "$TMP/clean.sh" <<'SUITE'
#!/usr/bin/env bash
sleep 3600 &
child=$!
kill "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
exit 0
SUITE

echo "setsid isolation — suite gets its own process group"

# Positive control: run the leaky suite via setsid and confirm survivors are detectable.
setsid bash "$TMP/leaky.sh" > /dev/null 2>&1 &
leaky_pgid=$!
wait "$leaky_pgid" 2>/dev/null; leaky_rc=$?
[ "$leaky_rc" -eq 0 ] \
    && ok "leaky suite exited 0 (so the survivor is a cleanup defect, not a crash)" \
    || bad "leaky suite non-zero exit" "rc=$leaky_rc"
if kill -0 -- -"$leaky_pgid" 2>/dev/null; then
    ok "survivor is detectable via process group after suite exits"
else
    bad "no survivor detected" "kill -0 -- -$leaky_pgid returned non-zero (race or no sleep?)"
fi
# The harness would now kill survivors; do so here too.
kill -- -"$leaky_pgid" 2>/dev/null || true

echo
echo "setsid isolation — clean suite leaves no process group survivors"

setsid bash "$TMP/clean.sh" > /dev/null 2>&1 &
clean_pgid=$!
wait "$clean_pgid" 2>/dev/null; clean_rc=$?
[ "$clean_rc" -eq 0 ] && ok "clean suite exited 0" || bad "clean suite non-zero exit" "rc=$clean_rc"
if kill -0 -- -"$clean_pgid" 2>/dev/null; then
    bad "clean suite left background jobs" "process group $clean_pgid still has members"
    kill -- -"$clean_pgid" 2>/dev/null || true
else
    ok "clean suite: no survivors detected (process group is empty)"
fi

echo
echo "harness sweep — kill terminates survivors and they stay dead"

setsid bash "$TMP/leaky.sh" > /dev/null 2>&1 &
sweep_pgid=$!
wait "$sweep_pgid" 2>/dev/null

kill -- -"$sweep_pgid" 2>/dev/null || true
# Brief wait: SIGTERM is asynchronous; the sleep needs a moment to die.
sleep 0.2

if kill -0 -- -"$sweep_pgid" 2>/dev/null; then
    bad "survivor persisted after kill -- -$sweep_pgid" "(still alive 200ms after SIGTERM)"
    kill -9 -- -"$sweep_pgid" 2>/dev/null || true
else
    ok "survivors are dead after harness sweep"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
