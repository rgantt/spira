#!/usr/bin/env bash
#
# test-incident.sh — the intake dedupe holds against two concurrent filers of the same ref.
#
#   ./test-incident.sh
#
# THE INCIDENT THIS SUITE REPRODUCES. The watchtower's first live run at 2026-09-07T22:30:15Z
# produced TWO beads for the same ref, identical to the second: sp-aapz and sp-uvfq. The
# log named both at the same timestamp, which is only possible if two invocations ran
# concurrently — the watchtower timer and the install-triggered start. The spool had drained
# both entries; both called open_incident before either called bdq create; both got "no open
# incident"; both filed.
#
# THE MECHANISM IS A CHECK FOLLOWED BY AN ACT. open_incident asks the database whether any
# open bead carries the ref; file_one creates one if not. Two callers that ask before either
# answers both get "no" and both file. That is not an atomic operation; only a mutual-
# exclusion lock around the entire check-and-create pair makes it one.
#
# THE FIX IS A FLOCK AROUND drain_one. Every path through the intake — `incident.sh file`,
# `incident.sh systemd`, `incident.sh drain` — passes through drain_one, so one lock guards
# all of them. The wait is bounded and a timeout leaves the entry spooled, which is the
# write-ahead behaving as designed.
#
# WHAT IS UNDER TEST HERE IS NOT THE SEQUENTIAL CASE. Sequential calls evidently already
# deduped; the incident was concurrent. A suite that planted one bead and then filed a second
# would test the sequential path and miss the race entirely. This suite plants NOTHING and
# fires two filers simultaneously against an empty database.
#
# THE POSITIVE CONTROL COMES FIRST (law-absence-needs-a-positive-control). Before asserting
# that concurrent calls dedupe, this suite verifies that a SINGLE call creates a bead and
# that OPEN_INCIDENT FINDS IT — using open_incident's own query path (the bd list
# --external-ref filter). A mis-set SPIRA_DB, a wrong label, or a broken external-ref filter
# all look like "nothing was created" to an assertion that only counts beads, and the control
# is what distinguishes them from "the lock works".
#
# Driven through the REAL incident.sh against a REAL bd on a throwaway fixture database —
# no stubs. The race is a claim about the database transaction ordering, and a stub that
# returned "no open bead" on every call would make a suite that always "passed"
# (law-prefer-the-real-dependency).
#
# covers: spira/incident.sh spira/watchtower.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want(){ [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }

echo "test-incident.sh"

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-incident
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up incident || { echo "test-incident: could not build a fixture database"; exit 1; }

# A no-op notifier so the SIN escalation path does not reach the real cockpit.
NOOP="$TMP/noop.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"

RUN="$TMP/run"; mkdir -p "$RUN"
SPOOL="$RUN/spool"
LOCK="$RUN/incident.lock"
ILOG="$RUN/incident.log"

# Run incident.sh with an explicit, named environment, pointing at the fixture database and
# isolated scratch directories (law-gates-run-in-a-clean-environment). HOME is the real one
# because bd and dolt read their credentials from it; SPIRA_PATH is passed because conf.sh
# rebuilds PATH from it; SPIRA_CONF names a non-existent file so a real spira.conf on this
# box cannot override any key the suite sets explicitly.
inc() {
    env -i HOME="$HOME" PATH="$PATH" SPIRA_PATH="${SPIRA_PATH:-}" \
        SPIRA_CONF="$TMP/nonexistent.conf" \
        SPIRA_DB="$SPIRA_DB" \
        SPIRA_SPOOL="$SPOOL" \
        SPIRA_INCIDENT_LOG="$ILOG" \
        SPIRA_INCIDENT_LOCK="$LOCK" \
        SPIRA_RUN="$RUN" \
        SPIRA_NOTIFY="$NOOP" \
        SPIRA_ASK="$NOOP" \
        "$@" bash "$HERE/incident.sh" file "the test sweep" -
}

# Count open beads carrying the given external ref on the fixture database. The output
# format is "○ sp-xyz ● P1 [bug] …", so we match on the bead-id pattern anywhere in
# the line rather than at the start of it.
count_open() {
    bd -C "$SPIRA_DB" list --status open,in_progress --limit 0 \
        --label spira,incident --external-ref "$1" 2>/dev/null \
      | grep -cE ' sp-[a-z0-9]+' || true
}

# ======================================================================================
echo
echo "the positive control — a single call creates one bead and open_incident finds it:"
# ======================================================================================
# If this fails, open_incident's query (--external-ref, --label spira,incident) is not
# finding what incident.sh filed, and every concurrent-case assertion below is testing the
# wrong thing.
printf 'positive control payload\n' | inc >/dev/null
n="$(count_open 'incident:the-test-sweep')"
is "a single filing creates exactly one bead" "1" "$n"

testdb_reset
mkdir -p "$RUN"

# ======================================================================================
echo
echo "the sequential case — a second call on the same ref is a recurrence, not a new bead:"
# ======================================================================================
# The sequential dedupe evidently already passed before the incident. This case is kept as
# a sanity check: if it breaks, the lock (which is only needed for concurrency) is not the
# culprit and the external-ref filter is probably broken.
printf 'first\n' | inc >/dev/null
printf 'second\n' | inc >/dev/null
n="$(count_open 'incident:the-test-sweep')"
is "two sequential calls leave exactly one open bead" "1" "$n"
log_count="$(grep -c 'recurred' "$ILOG" 2>/dev/null || true)"
is "the second call was recorded as a recurrence, not a filing" "1" "$log_count"

testdb_reset
mkdir -p "$RUN"
> "$ILOG"

# ======================================================================================
echo
echo "the concurrent case — two simultaneous filers of the same ref create exactly one bead:"
# ======================================================================================
# THE INCIDENT CASE, REPRODUCED. Both processes call open_incident before either calls
# bdq create; without the flock both get "no open incident" and both file. The lock in
# drain_one serialises the check-and-create pair so the second caller waits, re-runs
# open_incident inside the lock, finds the bead the first caller just created, and records
# a recurrence instead.
#
# Both processes are started with no sleep between them. Dolt's query latency is enough to
# widen the race window so this is not a lucky ordering — it is the same shape as the
# incident, just in a test database.
printf 'concurrent A\n' | inc >/dev/null &
pid_a=$!
printf 'concurrent B\n' | inc >/dev/null &
pid_b=$!
wait "$pid_a" || true
wait "$pid_b" || true

n="$(count_open 'incident:the-test-sweep')"
is "two concurrent filers create exactly one bead" "1" "$n"
recur_count="$(grep -c 'recurred' "$ILOG" 2>/dev/null || true)"
is "the second caller recorded a recurrence, not a second filing" "1" "$recur_count"

testdb_reset
mkdir -p "$RUN"
> "$ILOG"

# A separate wrapper that accepts extra env vars as leading positional args (env(1)
# treats leading VAR=val tokens as environment assignments). Stdout is discarded; use
# find_bead to locate what was filed.
inc_env() {
    env -i HOME="$HOME" PATH="$PATH" SPIRA_PATH="${SPIRA_PATH:-}" \
        SPIRA_CONF="$TMP/nonexistent.conf" \
        SPIRA_DB="$SPIRA_DB" \
        SPIRA_SPOOL="$SPOOL" \
        SPIRA_INCIDENT_LOG="$ILOG" \
        SPIRA_INCIDENT_LOCK="$LOCK" \
        SPIRA_RUN="$RUN" \
        SPIRA_NOTIFY="$NOOP" \
        SPIRA_ASK="$NOOP" \
        "$@" \
        bash "$HERE/incident.sh" file "harness repo test" - >/dev/null 2>&1
}

# Find the bead by its external ref (the ref incident.sh derives from the title).
find_bead() {   # find_bead <external-ref> -> bead id or empty
    bd -C "$SPIRA_DB" list --status open,in_progress --limit 1 \
        --external-ref "$1" 2>/dev/null \
      | grep -oE '\bsp-[a-z0-9]+\b' | head -1 || true
}

# ======================================================================================
echo
echo "the repo: label — a declared repo is stamped on the bead (positive control):"
# ======================================================================================
# POSITIVE CONTROL (law-absence-needs-a-positive-control). File an incident that names
# the harness as its repository and assert the resulting bead carries repo:spira.
# Without this, a mis-set SPIRA_DB, a broken label command, or an absent code path all
# look like "no label" to an assertion that only checks for its absence.
printf 'repo test payload\n' | inc_env SPIRA_INCIDENT_REPO=spira
id_repo="$(find_bead 'incident:harness-repo-test')"
if [ -n "${id_repo:-}" ]; then
    labels_repo="$(bd -C "$SPIRA_DB" label list "$id_repo" 2>/dev/null || true)"
    want "repo:spira on a bead filed with SPIRA_INCIDENT_REPO=spira" "repo:spira" "$labels_repo"
else
    bad "repo label: positive control" "incident.sh filed nothing (no bead at incident:harness-repo-test)"
fi

testdb_reset
mkdir -p "$RUN"
> "$ILOG"

# ======================================================================================
echo
echo "the repo: label — an undeclared repo is marked needs-repo-triage, not silently defaulted:"
# ======================================================================================
# WHERE THE CALLER DECLARES NO REPO the bead must carry needs-repo-triage rather than
# silently going to the home-repo fallback. A wrong repo is not indistinguishable from a
# right one (sp-io5e, law-a-split-repoints-nothing).
printf 'no-repo payload\n' | inc_env
id_norep="$(find_bead 'incident:harness-repo-test')"
if [ -n "${id_norep:-}" ]; then
    labels_norep="$(bd -C "$SPIRA_DB" label list "$id_norep" 2>/dev/null || true)"
    want "needs-repo-triage when no SPIRA_INCIDENT_REPO declared" "needs-repo-triage" "$labels_norep"
    case "$labels_norep" in
        *"repo:"*) bad "no-repo: must carry no repo: label when repo undeclared" "got: $labels_norep" ;;
        *) ok "no-repo: no repo: label present when repo undeclared" ;;
    esac
else
    bad "no-repo: positive control" "incident.sh filed nothing (no bead at incident:harness-repo-test)"
fi

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
