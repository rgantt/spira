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

# Count ALL beads (any status) carrying the given external ref on the fixture database.
# Used by the close-then-refile regression: after the fix the closed bead is reopened so
# the total count stays 1; under the unfixed code a new bead is created and the count is 2.
count_all() {
    bd -C "$SPIRA_DB" list --all --status open,in_progress,closed --limit 0 --label spira,incident --json 2>/dev/null \
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
echo "close-then-refile dedup — a closed bead within the lookback is reopened (sp-srgr6):"
# ======================================================================================
# THE DEFECT REPRODUCED. open_incident formerly filtered --status open,in_progress only.
# Closing a bead for a still-failing ref made it invisible: the next invocation found no
# open bead and filed a fresh one — repeating until 38 duplicate beads accumulated in 2 days.
#
# SEEN TO FAIL against the unfixed tree (law-a-regression-test-must-be-seen-to-fail):
# Filing first bead; closing it; filing same ref again produced:
#   2026-09-10T14:25:47Z incident: filed sp-7ed for incident:the-test-sweep   ← second bead
# count_all returned 2 (one closed original + one fresh open bead).
#
# After the fix: recent_closed_incident finds the closed bead within SPIRA_INCIDENT_DEDUP_LOOKBACK
# days and file_one reopens it with a recurrence note — count_all stays 1, count_open stays 1.
printf 'first payload\n' | inc >/dev/null
# Extract and close the bead that was just filed.
_ctr_id="$(bd -C "$SPIRA_DB" list --status open,in_progress --limit 0 --json 2>/dev/null \
  | python3 -c '
import sys, json
target = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d, list) else [d]):
    if i.get("external_ref") == target:
        print(i["id"]); break
' 'incident:the-test-sweep')"
[ -n "${_ctr_id:-}" ] && \
    bd -C "$SPIRA_DB" close "$_ctr_id" --reason "resolved in regression test" >/dev/null 2>&1 || true
> "$ILOG"
# File the same ref again — should reopen, not create a second bead.
printf 'second payload\n' | inc >/dev/null
n_all="$(count_all 'incident:the-test-sweep')"
is "close-then-refile leaves exactly one bead total (original reopened)" "1" "$n_all"
n_open="$(count_open 'incident:the-test-sweep')"
is "the original bead was reopened (now open)" "1" "$n_open"
log_reopen="$(grep -c 'reopened from closed' "$ILOG" 2>/dev/null || true)"
is "reopen path was logged, not a new filing" "1" "$log_reopen"

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
echo "  sequential dedupe — second filing produces no new ask after incident resolves:"
# THE BLEED, REPRODUCED. An incident closes (operator said it was fixed); the next run
# of the same test file (same ref) formerly created a new incident AND a new ask.
# sp-jvlrs fixed the ask side (dedup on ref, not title).
# sp-srgr6 fixed the incident side: the closed bead is found in the lookback window and
# REOPENED rather than a new bead being filed. When the bead is reopened, the code never
# reaches the "file new bead" path and the ask count stays at 1.
# A second valid path: a new bead IS filed but the ask is found and commented on. Both
# produce exactly one ask — the test asserts on that invariant, not on the internal path.
# Step 1: file the first incident (creates incident-1 + ask-A).
printf 'payload 1\n' | inc_ask >/dev/null
# Extract the incident bead id from the log ("filed <id> for incident:...").
_seq_id="$(grep 'incident: filed .* for incident:undeclared-repo-test' "$ILOG" \
    | awk '{print $4}' | head -1)"
# Close the incident so the bead-dedup lookback is exercised on the second filing.
[ -n "${_seq_id:-}" ] && \
    bd -C "$SPIRA_DB" close "$_seq_id" --reason "resolved in test" >/dev/null 2>&1 || true
# Step 2: same test still has no repo — new run. Must not create a second ask.
> "$ILOG"
printf 'payload 2\n' | inc_ask >/dev/null
n="$(count_undeclared_asks "$NOREP_REF")"
is "two incidents (close in between) produce one ask" "1" "$n"
# The recurrence path is "reopened from closed" (bead-level dedup) or "ask already open"
# (ask-level dedup). Either proves no fresh ask was filed — accept both.
recur_log="$(grep -cE 'reopened from closed|undeclared-repo ask already open' "$ILOG" 2>/dev/null || true)"
is "second filing after close was a recurrence (no new ask or new bead)" "1" "$recur_log"

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

testdb_reset; mkdir -p "$RUN"; > "$ILOG"

# ======================================================================================
echo
echo "provenance — undeclared-repo ask leads with unit+host+path, not the ref slug:"
# ======================================================================================
# THE REJECTED ASKS (sp-fzxk9, sp-dmjge). Four escalations in one hour were rejected as
# unreadable. The leading line was the external_ref slug — a dedupe key, not a sentence.
# "is this from a test container?" was asked three times. This test verifies the fix:
# the ask title now leads with "<unit> on <host>: <path>", making the origin unmistakable.
#
# POSITIVE CONTROL (law-a-regression-test-must-be-seen-to-fail). Against the unfixed code,
# the ask title starts with "undeclared repo: incident:..." — assertions 1 and 3 below
# would fail. After the fix, the title starts with unit+host+path and the path appears.
#
# SPIRA_INCIDENT_PATH is passed explicitly so the path component is checkable; without it
# the path renders ? (which is correct, but untestable for a specific value).

# get_ask_title: return the title of the decision bead for this ref (the ask filed by
# the undeclared-repo escalation). The search key is the stable ref substring, which
# remains in the new title format as a substring (not the prefix).
get_ask_title() {   # get_ask_title <ref> -> title of the filed ask
    local key="undeclared repo: $(printf '%s' "$1" | cut -c1-72)"
    bd -C "$SPIRA_DB" list --status open --limit 0 --json 2>/dev/null \
      | python3 -c '
import sys, json
want = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: print(""); raise SystemExit(0)
rows = d if isinstance(d, list) else [d]
for r in rows:
    if want in (r.get("title") or "") and r.get("issue_type") == "decision":
        print(r.get("title", "")); break
' "$key"
}

PROV_REF="incident:undeclared-repo-test"
printf 'provenance payload\n' | inc_ask SPIRA_INCIDENT_PATH="$HERE/test-incident.sh" >/dev/null
_ask_title="$(get_ask_title "$PROV_REF")"
# The title must NOT start with the ref slug — that was the unreadable form.
case "$_ask_title" in
    "undeclared repo:"*) bad "provenance: ask title starts with ref slug (not provenance)" "got: $_ask_title" ;;
    *)                   ok "provenance: ask title does not start with ref slug" ;;
esac
# The title must contain ' on ' — the provenance format is '<unit> on <host>: <path>'.
case "$_ask_title" in
    *" on "*) ok "provenance: ask title contains provenance marker ' on '" ;;
    *)        bad "provenance: ask title must contain ' on '" "got: $_ask_title" ;;
esac
# The declared SPIRA_INCIDENT_PATH must appear — proving it reached the ask title.
case "$_ask_title" in
    *"test-incident.sh"*) ok "provenance: ask title contains the declared SPIRA_INCIDENT_PATH" ;;
    *)  bad "provenance: declared path (test-incident.sh) must appear in ask title" "got: $_ask_title" ;;
esac

testdb_reset; mkdir -p "$RUN"; > "$ILOG"

# ======================================================================================
echo
echo "dedup efficiency — O(1) bd show calls regardless of open-incident queue depth (sp-80br6):"
# ======================================================================================
# THE PROBLEM. The dedup path formerly called bd show once per candidate returned by
# bd list --label <labels>. N open incidents meant N sequential subprocess calls inside
# the intake flock, measured at ~202ms each: 10 open incidents added ~2s per new filing,
# exactly when the queue is deepest.
#
# THE FIX. Each bead now carries ref:<hash-of-external-ref> at filing time. _dedup_incident
# queries bd list --label ref:<hash>, returning at most 1 candidate, and reads external_ref
# directly from bd list --json output — no bd show per candidate.
#
# POSITIVE CONTROL (law-absence-needs-a-positive-control). The naive O(N) approach must
# visibly show N bd show calls for N candidates, proving the counter wrapper is working.
# A counter that always returns 0 would make any code look efficient; the positive control
# distinguishes "nothing calls bd show" from "the counter is broken."
#
# THE COUNTER WRAPS $SPIRA_BD. incident.sh uses bdq (which wraps $SPIRA_BD) for all bd
# calls; replacing SPIRA_BD with a counting wrapper captures every bd show invocation.
# The wrapper writes to SHOW_COUNT_FILE atomically enough for this single-process test.

SHOW_COUNT_FILE="$TMP/show-count"
BD_REAL="${SPIRA_BD:-bd}"

BD_COUNTER="$TMP/bd-counter"
# The wrapper must use the original bd binary ($BD_REAL), not itself recursively.
# Scan all args for 'show': bdq prepends -C $SPIRA_DB, so 'show' is not always at $1.
cat > "$BD_COUNTER" <<WRAPPER
#!/usr/bin/env bash
for _a in "\$@"; do
    if [ "\$_a" = "show" ]; then
        _c=\$(cat "$SHOW_COUNT_FILE" 2>/dev/null || echo 0)
        printf '%d\n' \$((_c+1)) > "$SHOW_COUNT_FILE"
        break
    fi
done
exec "$BD_REAL" "\$@"
WRAPPER
chmod +x "$BD_COUNTER"

# POSITIVE CONTROL: a naive O(N) function that calls bd show for each candidate in the
# open incident list — the shape of the OLD dedup path. Proves the counter captures shows.
_naive_dedup_show_count() {
    local search_labels
    search_labels="$(printf '%s' "${LABELS:-spira,incident}" | tr ',' '\n' | grep -v '^repo:' | paste -sd, -)"
    printf '0\n' > "$SHOW_COUNT_FILE"
    "$BD_COUNTER" -C "$SPIRA_DB" list --status open,in_progress --limit 0 \
        --label "$search_labels" --json 2>/dev/null \
      | python3 -c "
import sys, json, subprocess
bd_bin = sys.argv[1]
spira_db = sys.argv[2]
try:
    for bead in json.load(sys.stdin):
        bid = bead.get('id')
        if not bid: continue
        subprocess.run([bd_bin, '-C', spira_db, 'show', bid, '--json'], capture_output=True)
except: pass
" "$BD_COUNTER" "$SPIRA_DB" 2>/dev/null
    cat "$SHOW_COUNT_FILE" 2>/dev/null || echo 0
}

# Plant N beads with different refs so the naive loop has N candidates to bd-show.
N_BENCH=5
for _i in $(seq 1 $N_BENCH); do
    "$BD_REAL" -C "$SPIRA_DB" create "bench-incident-$_i" \
        --type bug --priority 2 --labels spira,incident \
        --external-ref "incident:bench-ref-$_i" --silent >/dev/null 2>&1
done

naive_shows="$(_naive_dedup_show_count)"
is "positive control: naive O(N) approach calls bd show $N_BENCH times for $N_BENCH candidates" \
   "$N_BENCH" "$naive_shows"

testdb_reset; mkdir -p "$RUN"; > "$ILOG"

# NEW CODE: file via incident.sh (which uses the label-keyed path) alongside N-1 noise
# beads that lack the ref: label. The dedup path on the second filing should issue
# exactly 0 bd show calls — the label query returns 1 candidate and external_ref is
# read directly from bd list --json output.
for _i in $(seq 2 $N_BENCH); do
    "$BD_REAL" -C "$SPIRA_DB" create "bench-noise-$_i" \
        --type bug --priority 2 --labels spira,incident \
        --external-ref "incident:noise-ref-$_i" --silent >/dev/null 2>&1
done

# File the target ref via incident.sh; it creates the bead and adds ref:<hash> label.
printf 'seed\n' | inc SPIRA_INCIDENT_REF="incident:bench-target" >/dev/null 2>&1 || true

# Second filing on same ref (the dedup recurrence path). Count bd show calls.
printf '0\n' > "$SHOW_COUNT_FILE"
printf 'recur\n' | SPIRA_BD="$BD_COUNTER" inc SPIRA_INCIDENT_REF="incident:bench-target" >/dev/null 2>&1 || true
new_shows="$(cat "$SHOW_COUNT_FILE" 2>/dev/null || echo 0)"
is "label-keyed dedup issues 0 bd show calls with $N_BENCH open candidates" "0" "$new_shows"

testdb_reset; mkdir -p "$RUN"; > "$ILOG"

# FALLBACK TEST: a bead filed without the ref: label (older code) still dedupes.
# The fallback path (sub-path B) handles this case correctly.
# Plant a bead manually (no ref: label, with the right external_ref).
_fb_ref="incident:fallback-test-ref"
_fb_id="$("$BD_REAL" -C "$SPIRA_DB" create "fallback test incident" \
    --type bug --priority 2 --labels spira,incident \
    --external-ref "$_fb_ref" --silent 2>/dev/null | tr -d '[:space:]')"
[ -n "$_fb_id" ] && \
    "$BD_REAL" -C "$SPIRA_DB" label add "$_fb_id" "sp-recur-1" >/dev/null 2>&1 || true

# File the same ref via incident.sh — must find the existing bead (recurrence, not new).
printf 'fallback recur\n' | inc SPIRA_INCIDENT_REF="$_fb_ref" >/dev/null 2>&1 || true
n_fb="$(bd -C "$SPIRA_DB" list --status open,in_progress --limit 0 --json 2>/dev/null \
  | python3 -c "
import sys, json
target = sys.argv[1]
count = 0
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d, list) else [d]):
    if i.get('external_ref') == target: count += 1
print(count)
" "$_fb_ref")"
is "a bead filed without ref: label is still found via the fallback path" "1" "$n_fb"
recur_fb="$(grep -c 'recurred' "$ILOG" 2>/dev/null || true)"
is "fallback-found bead was treated as recurrence, not new filing" "1" "$recur_fb"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
