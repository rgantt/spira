#!/usr/bin/env bash
#
# test-check4-requeue.sh — a bead with enough reopened events hits the requeue cap;
#   a bead with zero reopened events does not.
#
#   ./test-check4-requeue.sh
#
# THE DEFECT THIS GUARDS. attempts_of counts claims minus closes, so a close/reopen thrash
# loop keeps the difference at 0 or 1 no matter how many sessions burn. The requeue cap
# (REQUEUE_AT) was unreachable because _requeues was a hardcoded 0, so the escalation block
# at CHECK4 that names the reopen count was dead code. This suite arms that valve.
#
# TWO ACCEPTANCE CRITERIA:
# 1. POSITIVE CONTROL — a bead with REQUEUE_AT or more reopened events raises an escalation
#    naming the reopen count. Without this, a suppression that never fires is green forever.
# 2. BELOW THRESHOLD — a bead with fewer reopened events than REQUEUE_AT raises no
#    escalation. Without this, a broken counter that always fires looks correct.
#
# FIXTURE PINS REQUEUE_AT TO A NON-DEFAULT so the test cannot pass on a literal written
# into the code. The shipped default is 5; the fixture uses 3. If the code reads
# REQUEUE_AT from the environment, both cases are trivially exercised.
#
# A REAL bd ON A THROWAWAY DATABASE — events are written by bd reopen and bd close, the
# same path the harness uses (law-prefer-the-real-dependency).
#
# FAIL-FIRST PROTOCOL (law-a-regression-test-must-be-seen-to-fail): run this suite against
# the unfixed tree (sentinel.sh with _requeues=0) and confirm it fails before relying on it.
#
# defect: sp-6bop
# covers: spira/lib.sh spira/sentinel.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-check4-requeue
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up check4-requeue || { echo "test-check4-requeue: could not build a fixture database"; exit 1; }
# shellcheck disable=SC1090
. "$HERE/lib.sh"

echo "test-check4-requeue.sh"

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree" "$SH/chamber"

cp "$HERE/sentinel.sh" "$HERE/lib.sh" "$HERE/landing.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub pilgrimage.sh 'printf "%s" "${PILGRIMAGE_OUT:-}"'
stub strand.sh     'printf "%s" "${STRAND_OUT:-}"'
stub sending.sh    'printf "%s" "${SENDING_OUT:-}"'
stub governor.sh   'exit 0'
stub gate.sh       'exit ${GATE_RC:-0}'
stub reflect.sh    'true'
stub ask.sh        'printf "%s\n" "$*" >> "$ASK_LOG"; true'
export ASK_LOG="$TMP/ask.log"; : > "$ASK_LOG"

cat > "$TMP/launch" <<'L'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCH_LOG"
exit "${LAUNCH_RC:-0}"
L
cat > "$TMP/systemctl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "${LAND_STATE:-inactive}"
S
chmod +x "$TMP/launch" "$TMP/systemctl"
export LAUNCH_LOG="$TMP/launch.log"

# Fayth partition: the beads seeded below carry spira,plan labels and no exclusion labels.
printf 'FAYTH_LABELS="spira,plan"\nFAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL,$SPIRA_CI_LABEL"\nFAYTH_MAX_CONCURRENT=0\n' > "$SH/chamber/t.fayth"

# FIXTURE THRESHOLD: 3 (shipped default is 5 — a different value pins the test to the
# environment variable path rather than to any literal in the code).
FIXTURE_REQUEUE_AT=3

sentinel() {
    rm -f "$RUN/reflect.fired" "$RUN/inference.cooldown"
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" \
    SPIRA_REPO="$REPO" \
    SPIRA_GOAL=sp-goal SPIRA_FAYTHS="t" SPIRA_INFERENCE_EVERY=0 \
    SPIRA_NOTIFY="$SH/ask.sh" \
    SPIRA_LAUNCH="$TMP/launch" SPIRA_SYSTEMCTL="$TMP/systemctl" \
    SPIRA_SUMMON="$TMP/launch" \
    SPIRA_SKIP_RECLAIM=1 \
    SPIRA_SKIP_CLOSED_CHECK=1 \
    SPIRA_REQUEUE_AT="$FIXTURE_REQUEUE_AT" \
        bash "$SH/sentinel.sh" 2>&1
}

num() { local v="$1"; printf '%d' "${v:-0}"; }

# cycle_reopen <id> <n>: close and reopen a bead n times, generating n reopened events.
# bd close requires --reason; bd reopen writes the reopened event.
cycle_reopen() {
    local id="$1" n="$2" i=0
    while [ "$i" -lt "$n" ]; do
        bdq close "$id" --reason "thrash-$i" >/dev/null 2>&1
        bdq reopen "$id" >/dev/null 2>&1
        i=$((i+1))
    done
    # Leave bead open so CHECK4 evaluates it.
}

# ======================================================================================
echo
echo "positive control — bead at threshold raises requeue escalation:"
# ======================================================================================
# POSITIVE CONTROL FIRST. Without it, a counter that mutes all escalations is
# indistinguishable from one that fires correctly.
testdb_reset; : > "$ASK_LOG"; rm -rf "$RUN/poison-asked"
testdb_seed <<'JSONL'
{"id":"sp-rq-1","title":"thrash bead at threshold","status":"open","issue_type":"task","labels":["spira","plan"],"updated_at":"2026-09-13T00:00:00Z"}
JSONL

# Seed FIXTURE_REQUEUE_AT closed/reopened pairs so reopens_of reaches the cap.
cycle_reopen sp-rq-1 "$FIXTURE_REQUEUE_AT"

# Verify the events are there before running the sentinel.
reopen_count="$(num "$(reopens_of sp-rq-1)")"
is "fixture has $FIXTURE_REQUEUE_AT reopened events" "$FIXTURE_REQUEUE_AT" "$reopen_count"

out="$(sentinel)"
# The escalation ask.sh call carries the bead id and reopen count.
want "requeue escalation fires naming the bead"   "sp-rq-1"              "$(cat "$ASK_LOG")"
want "requeue escalation names the reopen count"  "requeued $FIXTURE_REQUEUE_AT times" "$(cat "$ASK_LOG")"

# ======================================================================================
echo
echo "below threshold — bead with fewer reopens raises no escalation:"
# ======================================================================================
testdb_reset; : > "$ASK_LOG"; rm -rf "$RUN/poison-asked"
testdb_seed <<'JSONL'
{"id":"sp-rq-2","title":"thrash bead below threshold","status":"open","issue_type":"task","labels":["spira","plan"],"updated_at":"2026-09-13T00:00:00Z"}
JSONL

# One reopen — below the fixture threshold of 3.
cycle_reopen sp-rq-2 1
reopen_count="$(num "$(reopens_of sp-rq-2)")"
is "fixture has 1 reopened event" "1" "$reopen_count"

out="$(SPIRA_REQUEUE_AT=$FIXTURE_REQUEUE_AT sentinel)"
nowant "no requeue escalation below threshold" "sp-rq-2" "$(cat "$ASK_LOG")"

printf '\ntest-check4-requeue.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
