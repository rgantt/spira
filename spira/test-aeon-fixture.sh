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
#
# A BOX THAT WILL NOT BUILD A FIXTURE IS A SKIP, NEVER A FAILURE. What is measured here is a
# handoff whose every step is a real `bd init` against a server this suite does not own, so
# "the handoff is broken" and "the server is saturated" arrive looking identical — six
# assertions red at once, on a branch that changed nothing. Each stand-down below therefore
# resolves which of the two it is before any assertion reads the missing fixture, and reports
# the second as exit 77, the automake skip the gate announces as "could not check". A skip is
# refused outright once anything has already gone red, because turning a real regression into
# "could not check" is the one way this could be worse than the flakiness it replaces.
#
# covers: spira/aeon.sh spira/chamber/*
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
# The backgrounded aeon of the last case, so a stand-down does not leave a session running
# against a database this trap is about to drop.
APID=""
cleanup_all() { [ -n "${APID:-}" ] && kill -TERM "$APID" 2>/dev/null
                testdb_drop; rm -rf "$TMP"; return 0; }
trap cleanup_all EXIT INT TERM

# ---- this suite is a stopwatch, so it must say when it could not read the clock ----------
# Nearly all of its wall clock is `bd init`. It drives three REAL Dolt fixtures through
# aeon.sh by design, because the thing under test IS a fixture handoff — which makes it the
# suite most exposed to whatever else is using the same server. The exposure is not
# hypothetical: a build measured at 18-27s idle and ~55s loaded has also taken 5m26s and
# 8m51s here before failing, because `bd init` holds one connection across 61 schema
# migrations and a saturated server eventually closes it mid-run.
#
# TWO OUTCOMES, AND THEY MUST NOT BE CONFUSED. A handoff that is BROKEN is a regression and
# must be red. A box that will not produce a fixture in a plausible time has said nothing
# about the handoff at all, and reporting that as red rejects a branch for a condition it did
# not cause — which teaches everyone to re-run the gate rather than read it
# (law-alerts-must-be-actionable). The second outcome is exit 77, the automake skip the gate
# already announces as "could not check".
#
# THE BOUNDS ARE THIS SUITE'S OWN, not a guess at the caller's. FIXTURE_MAX is a statement
# about fixture builds: past it the server is saturated by definition, whatever is running on
# it. The budget is the wall clock the suite may spend before standing down, and it exists
# because a suite KILLED by a caller's timeout exits 124 — indistinguishable from a failing
# assertion out here. SPIRA_SUITE_TIMEOUT is the seam for a caller that allows something
# other than the 600s assumed here, and must never be set above what it actually allows.
FIXTURE_MAX="${SPIRA_TEST_FIXTURE_MAX:-150}"
SUITE_BUDGET=$(( ${SPIRA_SUITE_TIMEOUT:-600} - 60 ))
SUITE_T0="$(date +%s)"
spent() { echo $(( $(date +%s) - SUITE_T0 )); }
left()  { echo $(( SUITE_BUDGET - $(date +%s) + SUITE_T0 )); }

# A SKIP NEVER LAUNDERS A FAILURE THAT WAS ALREADY SEEN. Standing down after an assertion has
# gone red would turn a real regression into "could not check", which is the one way this
# could be worse than the flakiness it replaces.
cannot_measure() {      # cannot_measure <what could not be measured> — exit 77
    if [ "$fail" -gt 0 ]; then
        printf '\n%d passed, %d failed — and then: %s\n' "$pass" "$fail" "$1"
        exit 1
    fi
    printf '\nSKIP test-aeon-fixture: %s\n' "$1" >&2
    printf '  %ss spent of a %ss budget, load average %s. The handoff was not measured.\n' \
        "$(spent)" "$SUITE_BUDGET" "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" >&2
    exit 77
}

# STAND DOWN BEFORE A STEP THERE IS NO TIME FOR, rather than after being killed part way
# through it. Measured on a box under ordinary weekday load — three aeons and two other gate
# runs — a full pass is 433s of a 540s budget, and every second of that is a fixture build
# somebody else is contending for. So the margin is real and it is routinely thin.
need_budget() {         # need_budget <seconds> <what it was for>
    [ "$(left)" -ge "$1" ] || cannot_measure \
        "$(left)s of the ${SUITE_BUDGET}s budget was left and $2 needs ${1}s"
}

# A BOUNDED BUILD, which testdb_up cannot do for itself: `bd init` is a foreground child and
# the library has no clock. It runs in a subshell under `timeout` and prints its coordinates
# back — the same interface aeon.sh uses, for the same reason: the fixture library's
# functions have no business entering the process that owns the run.
#
# AN INHERITED FIXTURE STILL PASSES STRAIGHT THROUGH. Under a landing gate TESTDB_SHARED is
# already set, testdb_up resets rather than builds, and the same three values come back — so
# this is a bound on the slow path and changes nothing on the fast one.
#
# A build killed at the bound leaves its half-built database on the server, which is already
# the accepted cost of a fixture no trap could drop: every name carries its own birth epoch
# and testdb_up sweeps ones older than two hours before it builds.
fixture_build() {       # fixture_build <tag> — sets TESTDB_*; 0 built, 1 could not
    local out
    out="$( timeout -k 5 "$FIXTURE_MAX" bash -c '
        . "$1/testdb.sh" && testdb_up "$2" >&2 &&
        printf "%s\n%s\n%s\n" "$TESTDB_NAME" "$TESTDB_DIR" "$TESTDB_BASELINE"' _ "$HERE" "$1" )"
    [ -n "$out" ] || return 1
    { read -r TESTDB_NAME; read -r TESTDB_DIR; read -r TESTDB_BASELINE; } <<< "$out"
    export SPIRA_DB="$TESTDB_DIR"; unset SPIRA_BD
    return 0
}

# The phrase the landing gate's own narrow retry keys on is kept verbatim, so a genuinely
# transient refusal is still retried once before this becomes a skip.
fixture_build aeonfx || cannot_measure \
    "could not build a fixture database inside ${FIXTURE_MAX}s"

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
# BOUNDED, AND THE BOUND IS DISTINGUISHABLE FROM A FAILURE. A summon here builds a real
# fixture inside aeon.sh, which nothing out here can time — so an unbounded one can sit for
# minutes past the caller's own per-suite timeout, and being killed by THAT is exit 124 on a
# branch that changed nothing. Killed at this bound is 124 or 137 from `timeout` and is read
# below as "the session never started", never as an assertion about the handoff.
AEON_MAX=$(( FIXTURE_MAX + 60 ))
AEON_RC=0
run_aeon() { need_budget "$AEON_MAX" "another aeon summon"
             rm -rf "$SPIRA_RUN/worktree"; clear_trace
             as_caller timeout -k 5 "$AEON_MAX" "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1
             AEON_RC=$?; return 0; }
summoned() {            # summoned <which case> — or stand down, having exercised nothing
    case "$AEON_RC" in 124|137) cannot_measure \
        "the $1 aeon was still running after ${AEON_MAX}s and was killed — the session it summons never started" ;;
    esac
}
sess_env()  { cat "$TRACE.env" 2>/dev/null; }
# NEVER `| grep -q` UNDER pipefail: grep exits at the first match and the writer dies of
# SIGPIPE, which pipefail reports as the pipeline's status — so a match reads as a failure.
db_present() {  # db_present <name> -> yes|no
    local all; all="$(testdb_sql "" "show databases" | tail -n +2 | tr -d '\r')"
    grep -qx "$1" <<< "$all" && echo yes || echo no
}

# WHEN THE SESSION IS HANDED NO FIXTURE, WHOSE FAULT IS IT? aeon.sh writes this one line only
# after it has FOUND the fixture library in the worktree and the build has failed, and it
# quotes the library's own diagnosis into it. So the line's presence says the handoff ran,
# and the diagnosis says the database server is what refused — which is the box, not the code.
#
# BOTH HALVES ARE REQUIRED. A handoff broken so that it produced nothing would log the same
# line with an empty reason, and standing down on that would hide the regression this suite
# exists to catch. The three phrases are testdb.sh's own failure messages, matched exactly:
# a skip widened until the noise stops is how a real failure becomes a pass
# (law-alerts-must-be-actionable).
server_refused() {      # server_refused <the aeon's log> -> 0 if the SERVER would not build one
    case "$1" in *"has no shared test fixture"*) ;; *) return 1 ;; esac
    case "$1" in
        *"bd init failed"*|*"could not reset shared fixture"*|*"no baseline commit"*) return 0 ;;
    esac
    return 1
}
# A CHECK THAT FINDS NOTHING MUST FIRST PROVE IT COULD HAVE FOUND SOMETHING. Every stand-down
# below runs through that matcher, so a matcher that never fires would silently restore the
# behaviour this bead removed — six assertions failing at random — and a matcher that always
# fires would skip the suite forever while reading as healthy.
echo
echo "a contended database server is told apart from a broken handoff:"
_R="builder: sp-x has no shared test fixture — its suites will each build their own:"
is "a build the server refused is not the branch's fault" "yes" \
   "$(server_refused "$_R testdb: bd init failed (rc=1) for sptest_x" && echo yes || echo no)"
is "nor is a shared fixture it could not reset"           "yes" \
   "$(server_refused "$_R testdb: could not reset shared fixture sptest_x" && echo yes || echo no)"
is "but a handoff that produced nothing and said why not is" "no" \
   "$(server_refused "$_R " && echo yes || echo no)"
is "and so is a session that never mentioned a fixture"      "no" \
   "$(server_refused "builder: sp-x claimed and worked it" && echo yes || echo no)"
# The other two stand-downs, driven the same way. 77 is the whole point of each of them: a
# guard that has never been seen to fire is a guard nobody can tell from an absent one, and
# these two fire only on a box too loaded to reach in a test.
is "an aeon killed at its own bound stands the suite down" "77" \
   "$( ( AEON_RC=124; summoned first ) >/dev/null 2>&1; echo $? )"
is "and one that merely failed is left to the assertions"   "0" \
   "$( ( AEON_RC=1; summoned first ) >/dev/null 2>&1; echo $? )"
is "a budget that cannot hold the next step stands it down" "77" \
   "$( ( SUITE_T0=$(( SUITE_T0 - SUITE_BUDGET )); need_budget 60 "a step" ) >/dev/null 2>&1; echo $? )"

echo
echo "a repository with a fixture library gets one fixture, shared by the whole session:"
seed_bead sp-fx-1 withfx
run_aeon
summoned first
AEONLOG="$(cat "$TMP/out")"
FXNAME="$(sed -n 's/^TESTDB_NAME=//p' "$TRACE.env" 2>/dev/null)"
# ASKED BEFORE ANY ASSERTION READS IT. Six of the lines below are the same missing fixture
# seen six ways — the shared flag, the name, the log line, the reuse timing, the brief and
# the workspace — so a server that would not build one reports as six independent
# regressions, and the aeon's own exit code says nothing, because a fixture that will not
# build is deliberately not a refusal to work.
if [ -z "$FXNAME" ] && server_refused "$AEONLOG"; then
    # THE STAND-DOWN CARRIES WHAT THE SERVER SAID. A skip whose reason is "it was contended"
    # is a skip nobody can act on, and this is the only place the library's diagnosis is
    # visible from — the aeon quotes it into that one line and then deletes the file.
    _why="${AEONLOG##*its suites will each build their own: }"
    _why="${_why%%$'\n'*}"
    [ -n "$_why" ] || _why="$AEONLOG"
    cannot_measure "the aeon's own fixture build was refused: $_why"
fi
is   "the fake session ran, not the real one" "yes" "$([ -f "$TRACE.ran" ] && echo yes || echo no)"
want "the aeon claimed and worked it"   "sp-fx-1" "$AEONLOG"
want "the session was handed a shared fixture" "TESTDB_SHARED=1" "$(sess_env)"
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
#
# AND THE BOX MUST BE ABLE TO DO IT AT ALL BEFORE THE TIME MEANS ANYTHING. A reset is a
# `dolt_reset --hard` at ~73ms, so a second is already two orders of magnitude of slack — but
# a saturated server cannot always manage even that, and then "took 1400ms" is a fact about
# the server rather than about the handoff. The control is the SUITE'S OWN reset, timed
# against the same server moments later: fast here and slow in the session is a rebuild and
# is red; slow in both is a server nothing can be measured through.
REUSE_MS="$(cat "$TRACE.ms" 2>/dev/null || echo 999999)"
case "$REUSE_MS" in ''|*[!0-9]*) REUSE_MS=999999 ;; esac
if [ "$REUSE_MS" -lt 1000 ]; then
    ok "and it came back in under a second (${REUSE_MS}ms — a build is 27-55s)"
else
    _t0="$(date +%s%3N)"; testdb_reset; _ctl=$(( $(date +%s%3N) - _t0 ))
    if [ "$_ctl" -lt 1000 ]; then
        bad "and it came back in under a second" \
            "took ${REUSE_MS}ms against ${_ctl}ms for the same reset here, which is a rebuild"
    else
        cannot_measure "a fixture reset costs ${_ctl}ms on this server, so the session's ${REUSE_MS}ms cannot be told from a rebuild"
    fi
fi

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
summoned "no-fixture-library"
is   "the session still ran" "yes" "$([ -f "$TRACE.ran" ] && echo yes || echo no)"
want "and the bead was worked" "sp-fx-2" "$(cat "$TMP/out")"
nowant "with no shared fixture in its environment" "TESTDB_SHARED" "$(sess_env)"
nowant "and none built for it"                     "TESTDB_NAME"   "$(sess_env)"
want "the brief says so plainly" "no shared test fixture" "$(cat "$TRACE.prompt")"
is   "the caller's fixture was not passed on to it" "yes" "$(db_present "$CALLER_DB")"

echo
echo "a session killed mid-run still takes its fixture with it:"
# THIS CASE COSTS ANOTHER WHOLE FIXTURE BUILD, so it is not begun on a budget that cannot
# hold one. Starting it anyway is how the suite gets killed by its caller's timeout at 124,
# which out here is indistinguishable from a failing assertion.
need_budget "$AEON_MAX" "the killed-session case, which builds another fixture"
seed_bead sp-fx-3 withfx
rm -rf "$SPIRA_RUN/worktree"; clear_trace
# THE ASSIGNMENTS GO ON aeon.sh ITSELF, never through as_caller. A backgrounded shell
# FUNCTION is a subshell, so `$!` would name that subshell and the signal would kill it while
# aeon.sh — its child, and the thing under test — ran on untouched. The suite then measured a
# teardown that had never been asked to run and called it a leak.
#
# THE SHIM SLEEPS LONGER THAN THE SIGNAL CAN TAKE TO ARRIVE. It must still be running when
# the kill lands, and between the ready file and the kill sits a `show databases` against the
# very server this suite is contending with. Ten seconds was shorter than that query has
# taken here, and a session that finished on its own dropped its fixture the ordinary way —
# so the teardown under test was never signalled and the suite called a clean exit a failure.
# The trap kills this process, so a long sleep costs nothing.
TESTDB_SHARED=1 TESTDB_NAME="$CALLER_DB" TESTDB_DIR="$CALLER_DIR" TESTDB_BASELINE=nosuchhash \
SHIM_SLEEP=180 "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1 &
apid=$!; APID="$apid"
# BOUNDED BY THE BUILD THIS BOX ACTUALLY PAID, not by a constant. The session cannot report
# anything until aeon.sh has built its fixture, and the first case above measured exactly
# that build, on this server, under this load — so the wait is derived from a measurement
# rather than from a number chosen on an idle machine. A fixed 240s was marginal against a
# build measured at 153s, and the load it was marginal against is load the gate itself
# creates. It still waits on a FILE the shim writes rather than on a clock: that file
# appearing is what means there is something to drop.
BUILD_MS=0
[[ "$AEONLOG" =~ built\ in\ ([0-9]+)ms ]] && BUILD_MS="${BASH_REMATCH[1]}"
WAIT_S=$(( BUILD_MS / 1000 * 3 + 30 ))
[ "$WAIT_S" -gt "$FIXTURE_MAX" ] && WAIT_S="$FIXTURE_MAX"
[ "$WAIT_S" -gt "$(left)" ]      && WAIT_S="$(left)"
for _ in $(seq 1 "$WAIT_S"); do [ -f "$TRACE.ready" ] && break; sleep 1; done
KILLED="$(sed -n 's/^TESTDB_NAME=//p' "$TRACE.env" 2>/dev/null)"
if [ -z "$KILLED" ]; then
    _ran="$([ -f "$TRACE.ran" ] && echo yes || echo no)"
    kill -TERM "$apid" 2>/dev/null; wait "$apid" 2>/dev/null; APID=""
    # NOTHING WAS EXERCISED, so this is not a verdict on the teardown. `$TRACE.ran` is the
    # discriminator and it is the only one that works here: a session still inside `bd init`
    # has written no log line to classify, so asking the log whether the server refused
    # cannot tell "still building" from "built and handed nothing over".
    [ "$_ran" = yes ] || cannot_measure \
        "the aeon was still building its fixture after ${WAIT_S}s — the session whose teardown this measures never started"
    server_refused "$(cat "$TMP/out")" && cannot_measure \
        "the killed session's fixture build was refused by the database server"
    bad "the killed session had a fixture to lose" "the session never reported one"
else
    is "the killed session had a fixture" "yes" "$(db_present "$KILLED")"
    kill -TERM "$apid" 2>/dev/null
    wait "$apid" 2>/dev/null; APID=""
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
