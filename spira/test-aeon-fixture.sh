#!/usr/bin/env bash
#
# test-aeon-fixture.sh — one test fixture per aeon session, built at summon and dropped at
# exit, end to end through the real aeon.sh.
#
#   ./test-aeon-fixture.sh
#
# THE PROPERTY. Waiting on tests was 43% of an aeon's wall clock, and nearly all of a suite's
# cost is `bd init` building a throwaway database. The landing gate already builds one and
# lets every suite reset it instead; an aeon running suites by hand got none, so each of its
# ~15 single-suite runs paid the whole build again. So aeon.sh builds one at summon and
# exports it into the session, where every Bash call inherits it.
#
# Two halves, and both are asserted here, because either one alone is a defect: a suite run
# inside the session must RESET the inherited fixture rather than build a second one, and the
# database must be GONE when the aeon exits — it shares a server with live data, and litter
# there is not noticed until it is a problem.
#
# WHAT IS FAKED, AND WHY ONLY THIS. `claude` is a shim: it records the environment it was
# given, runs one real `testdb_up` against it, and reports what happened. Everything else is
# the real thing — a real Dolt server, a real `bd init`, a real claim, a real worktree
# (law-prefer-the-real-dependency). A stub of the fixture library would be a model of the one
# behaviour under test.
#
# THE CONFIGURED PATH IS PINNED TO A NON-DEFAULT. The fixture repository keeps its library at
# `tests/db.sh`, never at the shipped default, so a hardcoded `spira/testdb.sh` anywhere in
# aeon.sh fails this suite instead of passing it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-aeon-fixture

TMP="$(mktemp -d)"
cleanup_all() { testdb_drop; rm -rf "$TMP"; }
trap cleanup_all EXIT INT TERM
testdb_up aeonfx || { echo "test-aeon-fixture: could not build a fixture database"; exit 1; }

# ---- an explicit environment for every child -------------------------------------------
# Sourced ABOVE with the operator's config still readable, because that is where the Dolt
# server's port comes from; pinned HERE so that nothing below reads it. The children get the
# coordinates as values instead — a suite whose verdict depends on one box's config file is
# asserting about that box (law-gates-run-in-a-clean-environment).
export SPIRA_CONF="$TMP/nonexistent.conf"
export SPIRA_PATH="$(dirname "$(command -v bd)"):$(dirname "$(command -v dolt)")"
export TESTDB_HOST TESTDB_PORT

# ---- two repositories: one with a fixture library, one without --------------------------
# The pair is the positive control for the absence check. "No TESTDB_SHARED in the session"
# proves nothing on its own — an aeon that never exports one anywhere would pass it — so the
# same assertion is made against a repository that DOES get a fixture.
mkrepo() {              # mkrepo <path>
    mkdir -p "$1"; git -C "$1" init -q -b main
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
    echo seed > "$1/f"; git -C "$1" add f; git -C "$1" commit -qm seed
}
WITH="$TMP/withfx"; NOFX="$TMP/nofx"
mkrepo "$WITH"; mkrepo "$NOFX"
mkdir -p "$WITH/tests"
cp "$HERE/testdb.sh" "$WITH/tests/db.sh"
cp "$HERE/conf.sh"   "$WITH/tests/conf.sh"
git -C "$WITH" add tests; git -C "$WITH" commit -qm fixture-library
export SPIRA_TESTDB_LIB="tests/db.sh"

export SPIRA_HOME="$TMP/home"; mkdir -p "$SPIRA_HOME/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/aeon.sh" "$HERE/testdb.sh" "$SPIRA_HOME/"
cp -r "$HERE/actors" "$SPIRA_HOME/" 2>/dev/null || true
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_REPO_MAP="$TMP/repo-map"
{ printf 'withfx | %s | push | main | |\n' "$WITH"
  printf 'nofx | %s | push | main | |\n'   "$NOFX"; } > "$SPIRA_REPO_MAP"

cat > "$SPIRA_HOME/chamber/builder.fayth" <<FAYTH
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
FAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=600
FAYTH
# The persona carries {{FIXTURE}} because the RENDERED brief is part of the deliverable: a
# placeholder that never expands leaves the literal `{{FIXTURE}}` in front of the aeon, which
# is worse than saying nothing — and that has happened here before, to {{PARK}}.
printf 'work {{BEAD_ID}} in {{REPO}}\n\n{{FIXTURE}}\n' > "$SPIRA_HOME/chamber/builder.md"

# ---- the shim ---------------------------------------------------------------------------
# It answers the two questions the suite cannot ask from outside a running session: what
# TESTDB_* the session was given, and what a suite run under them actually does. The
# `testdb_up` it runs is the REAL one out of the worktree — the same call every suite makes.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'SHIM'
#!/usr/bin/env bash
# The marker is the suite's proof that THIS ran and not something else: a session that never
# happened satisfies every "the session saw no fixture" assertion just as well.
: > "$TRACE.ran"
cat /dev/stdin > "$TRACE.prompt" 2>/dev/null
env | grep '^TESTDB_' | sort > "$TRACE.env"
# The path is written out literally rather than read from SPIRA_TESTDB_LIB: that key is
# configuration for the harness, is not exported, and a session finds its suites the way any
# reader of the repository would.
if [ -n "${TESTDB_NAME:-}" ] && [ -f tests/db.sh ]; then
    inherited="$TESTDB_NAME"
    t0="$(date +%s%3N)"
    ( . tests/db.sh && testdb_up shim >/dev/null 2>&1 && printf '%s' "$TESTDB_NAME" ) \
        > "$TRACE.reused" 2>/dev/null
    printf '%s' "$(( $(date +%s%3N) - t0 ))" > "$TRACE.ms"
    printf '%s' "$inherited" > "$TRACE.inherited"
fi
# Only when asked: the killed-session case needs a session that is still running when the
# signal arrives, and every other case wants the shim to be instant.
[ -n "${SHIM_SLEEP:-}" ] && { : > "$TRACE.ready"; sleep "$SHIM_SLEEP"; }
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","num_turns":1}\n'
exit 0
SHIM
chmod +x "$BIN/claude"
# SPIRA_CLAUDE, NEVER A PATH SHIM: conf.sh replaces $PATH outright when aeon.sh sources it, so
# a fake `claude` placed first on PATH is thrown away and the REAL model runs, against the
# operator's account, for as long as the suite is left alone.
export SPIRA_CLAUDE="$BIN/claude"
grep -q 'SPIRA_CLAUDE' "$HERE/aeon.sh" \
    || { echo "test-aeon-fixture: aeon.sh has no SPIRA_CLAUDE injection point — this suite would run the REAL model. Refusing." >&2; exit 1; }
export TRACE="$TMP/trace"

seed_bead() {   # seed_bead <id> <repo-name>
    testdb_reset
    printf '{"id":"%s","title":"t","status":"open","issue_type":"task","labels":["spira","plan","repo:%s"],"updated_at":"2026-09-04T00:00:00Z"}\n' "$1" "$2" \
        | testdb_seed
}
clear_trace() { rm -f "$TRACE".{ran,prompt,env,reused,ms,inherited,ready}; }

# EVERY AEON HERE IS SUMMONED BY A CALLER THAT ALREADY OWNS A FIXTURE, because that is the
# real condition and not a contrived one: the landing gate builds one and exports it to
# everything it runs, so a suite under the gate that summons an aeon hands its database
# straight through. The aeon must neither pass it on to the session — whose suites would
# reset a database owned by something else, mid-run — nor drop it at exit. A plain database
# and a plain directory are enough to hold that ground; nothing here reads either of them.
CALLER_DB="sptest_caller_$(date +%s)_$$"
CALLER_DIR="$TMP/caller-workspace"; mkdir -p "$CALLER_DIR"
testdb_sql "" "create database \`$CALLER_DB\`" >/dev/null 2>&1
as_caller() {           # as_caller <command...> — run it holding a fixture of our own
    TESTDB_SHARED=1 TESTDB_NAME="$CALLER_DB" TESTDB_DIR="$CALLER_DIR" TESTDB_BASELINE=nosuchhash \
        "$@"
}
run_aeon() { rm -rf "$SPIRA_RUN/worktree"; clear_trace
             as_caller "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1; }
sess_env()  { cat "$TRACE.env" 2>/dev/null; }
# NEVER `| grep -q` UNDER pipefail: grep exits at the first match and the writer dies of
# SIGPIPE, which pipefail reports as the pipeline's status — so a match reads as a failure.
db_present() {  # db_present <name> -> yes|no
    local all; all="$(testdb_sql "" "show databases" | tail -n +2 | tr -d '\r')"
    grep -qx "$1" <<< "$all" && echo yes || echo no
}

echo
echo "a repository with a fixture library gets one fixture, shared by the whole session:"
seed_bead sp-fx-1 withfx
run_aeon
is   "the fake session ran, not the real one" "yes" "$([ -f "$TRACE.ran" ] && echo yes || echo no)"
want "the aeon claimed and worked it"   "sp-fx-1" "$(cat "$TMP/out")"
want "the session was handed a shared fixture" "TESTDB_SHARED=1" "$(sess_env)"
FXNAME="$(sed -n 's/^TESTDB_NAME=//p' "$TRACE.env" 2>/dev/null)"
case "$FXNAME" in
    sptest_aeonspfx1_*) ok "and it is named for the bead that owns it" ;;
    *) bad "and it is named for the bead that owns it" "got [$FXNAME]" ;;
esac
want "the log names it and says what it cost" "shares one test fixture" "$(cat "$TMP/out")"
nowant "and it is the aeon's own, not the caller's" "$CALLER_DB" "$(sess_env)"

# THE CENTRAL ASSERTION, and it is the reason the whole bead exists: a suite run inside the
# session must RESET the inherited database, not build a second one. Same name means it was
# the same database; the time is what the saving actually is.
is   "a suite run inside the session reused that exact fixture" "$FXNAME" "$(cat "$TRACE.reused" 2>/dev/null)"
REUSE_MS="$(cat "$TRACE.ms" 2>/dev/null || echo 999999)"
[ "${REUSE_MS:-999999}" -lt 1000 ] \
    && ok "and it came back in under a second (${REUSE_MS}ms — a build is 27-55s)" \
    || bad "and it came back in under a second" "took ${REUSE_MS}ms, which is a rebuild"

# The brief must say what is true, and it is rendered rather than templated: an unexpanded
# {{FIXTURE}} is an instruction an aeon cannot act on.
want "the brief tells the aeon the fixture is built" "already built" "$(cat "$TRACE.prompt")"
want "and names it"        "$FXNAME"    "$(cat "$TRACE.prompt")"
nowant "with no placeholder left in it" "{{FIXTURE}}" "$(cat "$TRACE.prompt")"

# THE FIXTURE WAS THERE — asserted through the session, above, which is what makes the next
# line mean "dropped" rather than "never existed" (law-absence-needs-a-positive-control).
is "the database is gone once the aeon has exited" "no" "$(db_present "$FXNAME")"
FXDIR="$(sed -n 's/^TESTDB_DIR=//p' "$TRACE.env" 2>/dev/null)"
[ -n "$FXDIR" ] && ok "the session was told where the workspace is" \
    || bad "the session was told where the workspace is" "no TESTDB_DIR was exported"
is "and that directory is gone too" "no" "$([ -n "$FXDIR" ] && [ -e "$FXDIR" ] && echo yes || echo no)"
# THE OTHER HALF OF THE SAME FENCE. A teardown that drops on TESTDB_NAME alone would take the
# caller's database with it here, and the caller is usually the landing gate mid-run.
is "the caller's own fixture is untouched" "yes" "$(db_present "$CALLER_DB")"
is "and so is its workspace"               "yes" "$([ -d "$CALLER_DIR" ] && echo yes || echo no)"

echo
echo "a repository with no fixture library is worked without one, not refused:"
seed_bead sp-fx-2 nofx
run_aeon
is   "the session still ran" "yes" "$([ -f "$TRACE.ran" ] && echo yes || echo no)"
want "and the bead was worked" "sp-fx-2" "$(cat "$TMP/out")"
nowant "with no shared fixture in its environment" "TESTDB_SHARED" "$(sess_env)"
nowant "and none built for it"                     "TESTDB_NAME"   "$(sess_env)"
want "the brief says so plainly" "no shared test fixture" "$(cat "$TRACE.prompt")"
is   "the caller's fixture was not passed on to it" "yes" "$(db_present "$CALLER_DB")"

echo
echo "a session killed mid-run still takes its fixture with it:"
seed_bead sp-fx-3 withfx
rm -rf "$SPIRA_RUN/worktree"; clear_trace
# THE ASSIGNMENTS GO ON aeon.sh ITSELF, never through as_caller. A backgrounded shell
# FUNCTION is a subshell, so `$!` would name that subshell and the signal would kill it while
# aeon.sh — its child, and the thing under test — ran on untouched. The suite then measured a
# teardown that had never been asked to run and called it a leak.
TESTDB_SHARED=1 TESTDB_NAME="$CALLER_DB" TESTDB_DIR="$CALLER_DIR" TESTDB_BASELINE=nosuchhash \
SHIM_SLEEP=10 "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1 &
apid=$!
# Bounded, and it waits on a FILE the shim writes rather than on a clock: the fixture is built
# before the session starts, so this file appearing means there is something to drop.
for _ in $(seq 1 240); do [ -f "$TRACE.ready" ] && break; sleep 1; done
KILLED="$(sed -n 's/^TESTDB_NAME=//p' "$TRACE.env" 2>/dev/null)"
if [ -z "$KILLED" ]; then
    bad "the killed session had a fixture to lose" "the session never reported one"
    kill -TERM "$apid" 2>/dev/null; wait "$apid" 2>/dev/null
else
    is "the killed session had a fixture" "yes" "$(db_present "$KILLED")"
    kill -TERM "$apid" 2>/dev/null
    wait "$apid" 2>/dev/null
    is "and the terminated aeon dropped it" "no" "$(db_present "$KILLED")"
fi

echo
echo "and a fixture no trap could drop is collected by age:"
# SIGKILL fires no trap, so the guarantee there is not the teardown — it is that every fixture
# name carries its own birth epoch and testdb_up sweeps ones older than two hours before it
# builds. Asserted with a database that IS swept and one that is not, because a sweep that
# dropped everything would satisfy the first line alone.
OLD="sptest_aeonorphan_$(( $(date +%s) - 10800 ))_1"
NEW="sptest_aeonrecent_$(date +%s)_1"
testdb_sql "" "create database \`$OLD\`" >/dev/null 2>&1
testdb_sql "" "create database \`$NEW\`" >/dev/null 2>&1
is "the abandoned fixture exists before the sweep" "yes" "$(db_present "$OLD")"
testdb_sweep
is "the sweep collects the abandoned one" "no"  "$(db_present "$OLD")"
is "and leaves a live one alone"          "yes" "$(db_present "$NEW")"
testdb_sql "" "drop database \`$NEW\`" >/dev/null 2>&1
testdb_sql "" "drop database \`$CALLER_DB\`" >/dev/null 2>&1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
