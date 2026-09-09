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
# defect: sp-5ll6
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

# Create a minimal repo-map so bdq can validate repo: labels in the test.
# Format is name|path (pipe-separated), with comments starting with #.
REPO_MAP="$TMP/repo-map"
printf 'brain|%s\n' "$SPIRA_DB" > "$REPO_MAP"

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

# Count open beads carrying the given external ref on the fixture database.
# NOTE: bd-embedded does not support --external-ref server-side filtering, so filter
# client-side via JSON, exactly as incident.sh open_incident does.
count_open() {
    bd -C "$SPIRA_DB" list --status open,in_progress --limit 0 --label spira,incident --json 2>/dev/null \
      | python3 -c '
import sys, json
target = sys.argv[1]
count = 0
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d, list) else [d]):
    if i.get("external_ref") == target:
        count += 1
print(count)
' "$1"
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
        SPIRA_REPO_MAP="$REPO_MAP" \
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
# NOTE: bd-embedded does not support --external-ref server-side filtering, so filter
# client-side via JSON.
find_bead() {   # find_bead <external-ref> -> bead id or empty
    bd -C "$SPIRA_DB" list --status open,in_progress --limit 0 --json 2>/dev/null \
      | python3 -c '
import sys, json
target = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d, list) else [d]):
    if i.get("external_ref") == target:
        print(i["id"]); break
' "$1"
}

# ======================================================================================
echo
echo "the repo: label — a declared repo is stamped on the bead (positive control):"
# ======================================================================================
# POSITIVE CONTROL (law-absence-needs-a-positive-control). File an incident that names
# a repository and assert the resulting bead carries the repo: label.
# Without this, a mis-set SPIRA_DB, a broken label command, or an absent code path all
# look like "no label" to an assertion that only checks for its absence.
printf 'repo test payload\n' | inc_env SPIRA_INCIDENT_REPO=brain
id_repo="$(find_bead 'incident:harness-repo-test')"
if [ -n "${id_repo:-}" ]; then
    labels_repo="$(bd -C "$SPIRA_DB" label list "$id_repo" 2>/dev/null || true)"
    want "repo:brain on a bead filed with SPIRA_INCIDENT_REPO=brain" "repo:brain" "$labels_repo"
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

testdb_reset
mkdir -p "$RUN"
> "$ILOG"

# ======================================================================================
echo
echo "cross-repo dedup — same ref, different repo: labels resolve to ONE incident (sp-jvlrs):"
# ======================================================================================
# THE PROPERTY a61a110 HAD NO WAY TO OBSERVE. open_incident formerly filtered on the
# caller's full LABELS including repo:, so two filers declaring different repos produced
# disjoint candidate sets and each filed a fresh bead. The fix strips repo: from the dedup
# filter (DEDUPE_LABELS), making external_ref the effective key regardless of which repo
# the caller declared.
#
# POSITIVE CONTROL: one filing with repo:brain creates a bead. A second filing of the same
# title with repo:fixture-repo must find that bead and record a recurrence.
_cross_title="cross repo dedup test"
_cross_ref="incident:cross-repo-dedup-test"
_cross_env() {
    env -i HOME="$HOME" PATH="$PATH" SPIRA_PATH="${SPIRA_PATH:-}" \
        SPIRA_CONF="$TMP/nonexistent.conf" \
        SPIRA_DB="$SPIRA_DB" \
        SPIRA_REPO_MAP="$REPO_MAP" \
        SPIRA_SPOOL="$SPOOL" \
        SPIRA_INCIDENT_LOG="$ILOG" \
        SPIRA_INCIDENT_LOCK="$LOCK" \
        SPIRA_RUN="$RUN" \
        SPIRA_NOTIFY="$NOOP" \
        SPIRA_ASK="$NOOP" \
        "$@" \
        bash "$HERE/incident.sh" file "$_cross_title" - >/dev/null 2>&1
}
printf 'first filer\n'  | _cross_env SPIRA_INCIDENT_REPO=brain
printf 'second filer\n' | _cross_env SPIRA_INCIDENT_REPO=fixture-repo
n="$(bd -C "$SPIRA_DB" list --status open,in_progress --limit 0 --json 2>/dev/null \
  | python3 -c '
import sys, json
target = sys.argv[1]; count = 0
try: d = json.load(sys.stdin)
except Exception: print(0); raise SystemExit(0)
for i in (d if isinstance(d, list) else [d]):
    if i.get("external_ref") == target: count += 1
print(count)
' "$_cross_ref")"
is "same ref with different repo: labels resolves to one incident, not two" "1" "$n"
recur_cross="$(grep -c 'recurred' "$ILOG" 2>/dev/null || true)"
is "second cross-repo filer was recorded as a recurrence, not a new filing" "1" "$recur_cross"

testdb_reset
mkdir -p "$RUN"
> "$ILOG"

# ======================================================================================
echo
echo "undeclared-repo ask dedupe — multiple incidents for the same ref produce ONE ask:"
# ======================================================================================
# THE BLEED THIS SUITE EXERCISES. 21 distinct test files produced 57 open asks by 16:07
# on 2026-09-09 (sp-k4de0, sp-unpyd). Each test suite pass filed a fresh ask rather than
# bumping the existing one, because the filing used the incident TITLE (which varies — it
# embeds the new bead id) rather than the EXTERNAL REF (which is stable across incidents
# from the same source).
#
# The fix: dedupe on the ref, within the intake flock that already serialises drain_one.
# Two concurrent filers both hold the lock before checking, so the second always finds the
# ask the first just created.
#
# A REAL ASK TOOL IS NEEDED TO TEST THIS. A noop mock never writes to the database, so the
# dedupe check always sees "no open ask" and always files — which passes a broken check and
# breaks a working one identically. The mock below creates real decision beads with the
# correct label in the test fixture, so the second call can find and comment on the first.
MOCK_ASK="$TMP/mock-ask.sh"
cat > "$MOCK_ASK" <<'MOCK'
#!/usr/bin/env bash
# Minimal ask.sh stand-in: 'add' creates a decision bead in the test database.
# Anything else is a no-op so SIN escalations do not interfere with the count.
set -uo pipefail
DB="${COCKPIT_DB:-${SPIRA_DB:-}}"
[ -n "$DB" ] || exit 0
case "${1:-}" in
    add)
        title="${2:-}"
        bd -C "$DB" create "$title" \
            --type decision \
            --labels "${SPIRA_ASK_LABEL:-needs-operator},overseer,ask-question" \
            --silent >/dev/null 2>&1 || true
        ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$MOCK_ASK"

# inc_ask: like inc_env but uses the real-enough mock ask for the dedupe tests.
inc_ask() {
    env -i HOME="$HOME" PATH="$PATH" SPIRA_PATH="${SPIRA_PATH:-}" \
        SPIRA_CONF="$TMP/nonexistent.conf" \
        SPIRA_DB="$SPIRA_DB" \
        SPIRA_SPOOL="$SPOOL" \
        SPIRA_INCIDENT_LOG="$ILOG" \
        SPIRA_INCIDENT_LOCK="$LOCK" \
        SPIRA_RUN="$RUN" \
        SPIRA_ASK="$MOCK_ASK" \
        "$@" bash "$HERE/incident.sh" file "undeclared repo test" - >/dev/null 2>&1
}

# Count open asks whose title contains the stable key for this ref.
# Filters on issue_type=decision rather than the ask label: the label value comes from
# SPIRA_ASK_LABEL which the outer shell reads from the real spira.conf, while the
# mock's subprocess uses only what was passed through env -i (the default needs-operator).
# issue_type=decision is stable, set at create time, and unambiguous: incidents are bugs.
count_undeclared_asks() {   # count_undeclared_asks <ref> -> integer
    local key="undeclared repo: $(printf '%s' "$1" | cut -c1-72)"
    bd -C "$SPIRA_DB" list --status open --limit 0 --json 2>/dev/null \
      | python3 -c '
import sys, json
want = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: print(0); raise SystemExit(0)
rows = d if isinstance(d, list) else [d]
print(sum(1 for r in rows if want in (r.get("title") or "") and r.get("issue_type") == "decision"))
' "$key"
}

# The dedupe ref that incident.sh derives from the title "undeclared repo test".
NOREP_REF="incident:undeclared-repo-test"

# -------
echo
echo "  positive control — single filing creates one ask:"
printf 'first payload\n' | inc_ask >/dev/null
n="$(count_undeclared_asks "$NOREP_REF")"
is "single undeclared-repo incident creates exactly one ask" "1" "$n"

testdb_reset; mkdir -p "$RUN"; > "$ILOG"

# -------
echo
echo "  sequential dedupe — second filing finds existing ask after incident resolves:"
# THE BLEED, REPRODUCED. An incident closes (operator said it was fixed); the next run
# of the same test file (same ref) creates a new incident. Without the fix, a second ask
# is also created. With the fix, the open ask is found and commented on instead.
# Step 1: file the first incident (creates incident-1 + ask-A).
printf 'payload 1\n' | inc_ask >/dev/null
# Extract the incident bead id from the log ("filed <id> for incident:...").
_seq_id="$(grep 'incident: filed .* for incident:undeclared-repo-test' "$ILOG" \
    | awk '{print $4}' | head -1)"
# Close the incident so the next filing is a new bead, not a recurrence.
[ -n "${_seq_id:-}" ] && \
    bd -C "$SPIRA_DB" close "$_seq_id" --reason "resolved in test" >/dev/null 2>&1 || true
# Step 2: same test still has no repo — new run, new incident, must reuse the ask.
> "$ILOG"
printf 'payload 2\n' | inc_ask >/dev/null
n="$(count_undeclared_asks "$NOREP_REF")"
is "two incidents (close in between) produce one ask" "1" "$n"
recur_log="$(grep -c 'undeclared-repo ask already open' "$ILOG" 2>/dev/null || true)"
is "second filing after close logged as a recurrence, not a new ask" "1" "$recur_log"

testdb_reset; mkdir -p "$RUN"; > "$ILOG"

# -------
echo
echo "  concurrent dedupe — two simultaneous filers create exactly one ask:"
# TWO FILERS, NO SLEEP BETWEEN THEM. The intake flock serialises drain_one; the second
# filer waits, then re-checks inside the lock and finds the ask the first just created.
printf 'concurrent A\n' | inc_ask >/dev/null &
pid_a=$!
printf 'concurrent B\n' | inc_ask >/dev/null &
pid_b=$!
wait "$pid_a" || true
wait "$pid_b" || true
n="$(count_undeclared_asks "$NOREP_REF")"
is "two concurrent undeclared-repo filers produce one ask" "1" "$n"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
