#!/usr/bin/env bash
#
# test-gate-run.sh — the gate runner: can one call ever outlive its budget, and does the
# caller always hold either a verdict or the knowledge that there is not one yet?
#
#   ./test-gate-run.sh
#
# THE PROPERTY UNDER TEST IS WALL CLOCK, so the gate here is a stub that sleeps for a stated
# number of seconds and the budget is driven down to seconds with it. Scaling both is the
# only way to assert the real shape — a call that returns "still deciding" rather than being
# truncated — without a suite that takes a quarter of an hour to say so. The one number
# checked at its SHIPPED value is the default budget, because that is the constant the whole
# mechanism rests on: a default above an agent's tool ceiling defeats it silently.
#
# `gate.sh` is the stub and nothing else is. It has its own suite, and what is under test
# here is what the runner does with a verdict and with the absence of one, not how a verdict
# is reached. Everything the runner reasons about is real: a git repository with real
# commits, because the cache key is an object id; real processes, because liveness is read
# from /proc; a really detached run, because surviving the call that started it is the point.
#
# No database is used, so this suite runs whether or not one is reachable.
#
# covers: spira/gate-run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
atmost() { [ "$3" -le "$2" ] && ok "$1" || bad "$1" "wanted at most ${2}s, took ${3}s"; }

TMP="$(mktemp -d)"
# Kill anything this suite left running before the directory goes: the runs are detached on
# purpose, so a suite that merely deleted its scratch tree would leave gates running against
# a repository that no longer exists.
cleanup_all() {
    local d p
    for d in "$TMP"/run/gate-run/*; do
        [ -f "$d/pid" ] || continue
        p="$(cat "$d/pid" 2>/dev/null)"; [ -n "${p:-}" ] || continue
        kill -KILL "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup_all EXIT INT TERM
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; SH="$TMP/spira"; RUN="$TMP/run"
mkdir -p "$SH" "$RUN"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
for b in pass fail slow left unmanaged; do git -C "$REPO" branch "spira/$b"; done

# conf.sh travels with lib.sh: lib.sh resolves every path through it and refuses to run
# without it, so a fixture that copies one and not the other fails at source time and every
# case reads as the runner being broken rather than the fixture being incomplete.
cp "$HERE/gate-run.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$SH/"
printf 'fixture | %s | push | main | |\n' "$REPO" > "$SH/repo-map"

# The stub records every invocation, so "did it start a second run" is a count rather than an
# inference. It reads its behaviour from the environment, which the runner passes down.
cat > "$SH/gate.sh" <<'STUB'
#!/usr/bin/env bash
echo "ran $1" >> "$GATE_LOG"
sleep "${GATE_SLEEP:-0}"
echo "stub gate output for $1"
exit "${GATE_RC:-0}"
STUB
chmod +x "$SH/gate.sh"
export GATE_LOG="$TMP/gate.log"; : > "$GATE_LOG"
export GATE_RC=0 GATE_SLEEP=0
gate() { export GATE_RC="$1" GATE_SLEEP="$2"; }     # what the next run's gate will do
runs() { grep -c "^ran $1\$" "$GATE_LOG" 2>/dev/null; }

# AN EXPLICIT, MINIMAL ENVIRONMENT. A suite that inherited a real spira.conf would be
# asserting about one box, and SPIRA_CONF pointed at a path that does not exist is how this
# file says "read no config at all" (law-gates-run-in-a-clean-environment).
#
# The status is carried out through a FILE. `out="$(run ...)"` runs the function in a
# subshell, so a status it assigned to a variable would never reach the assertion — the
# shape where every case reads 0 whatever happened.
run() {
    SPIRA_CONF="$TMP/no.conf" SPIRA_HOME="$SH" SPIRA_RUN="$RUN" \
    SPIRA_REPO_MAP="$SH/repo-map" SPIRA_GATE_POLL="${POLL:-20}" SPIRA_GATE_TICK=1 \
        bash "$SH/gate-run.sh" "$@" 2>&1
    printf '%s' "$?" > "$TMP/rc"
}
go()    { out="$(run "$@")"; rc="$(cat "$TMP/rc")"; }
timed() { local t0; t0="$(date +%s)"; go "$@"; secs=$(( $(date +%s) - t0 )); }

echo "test-gate-run.sh"

# --------------------------------------------------------------------------------------
# THE POSITIVE CONTROL. Everything below reads a verdict out of this runner, so the first
# thing to establish is that it reaches the gate at all: a runner that never ran anything
# would satisfy several assertions here by accident (law-absence-needs-a-positive-control).
# --------------------------------------------------------------------------------------
echo
echo "a gate that finishes inside one call:"
gate 0 0; go spira/pass fixture
is   "the runner exits with the gate's pass"  "0" "$rc"
is   "and the gate really ran, once"          "1" "$(runs spira/pass)"
want "and says so"                            "PASSED spira/pass" "$out"

gate 1 0; go spira/fail fixture
is   "a failing gate is a failing runner"     "1" "$rc"
want "and the gate's own output is printed"   "stub gate output for spira/fail" "$out"

# --------------------------------------------------------------------------------------
# THE BEAD'S CASE. A gate longer than the budget must come back as "still deciding" INSIDE
# the budget — not truncated, not blocking, and not reporting a verdict nobody reached. This
# is the shape that, at the real numbers, ended seventeen sessions with an attempt charged.
# --------------------------------------------------------------------------------------
echo
echo "a gate longer than one call's budget:"
gate 0 12; POLL=2 timed spira/slow fixture
is     "the first call reports that it is still deciding" "2" "$rc"
atmost "and returns inside its budget"                    9   "$secs"
want   "and tells the caller to call again"               "run the same command again" "$out"
nowant "and reports no verdict it does not have"          "PASSED" "$out"

# NOT MERELY BACKGROUNDED — DETACHED. The call that started the gate has returned and the
# suite touches nothing while it finishes; a run that were a child of that call would be gone
# with it. Waiting here without calling the runner is what makes the next assertion mean
# something.
sleep 14
POLL=2 go --status spira/slow fixture
is "the run survived the call that started it"    "0" "$rc"
is "and it was never restarted"                   "1" "$(runs spira/slow)"

POLL=2 go spira/slow fixture
is "a later call hands back the finished verdict" "0" "$rc"
is "without running the gate again"               "1" "$(runs spira/slow)"

# --------------------------------------------------------------------------------------
# THE VERDICT BELONGS TO WHAT WAS JUDGED. A cached pass that outlived its commit is the
# failure this whole file is downstream of: a check answering confidently about the wrong
# tree.
# --------------------------------------------------------------------------------------
echo
echo "a verdict is keyed to the commit it was reached on:"
git -C "$REPO" checkout -q spira/slow
git -C "$REPO" commit -q --allow-empty -m "one more commit"
git -C "$REPO" checkout -q main
gate 0 0; go spira/slow fixture
is "a new commit starts a new run"         "2" "$(runs spira/slow)"
is "and the new run is what is reported"   "0" "$rc"

# --------------------------------------------------------------------------------------
# --status ANSWERS NOW AND CHANGES NOTHING. It is asked from an exit path, so a probe that
# killed a run or cleared a verdict would change the answer it was asked for.
# --------------------------------------------------------------------------------------
echo
echo "--status:"
go --status spira/pass fixture
is "a branch with a finished run answers with its verdict" "0" "$rc"
go --status spira/unmanaged fixture
is "a branch with nothing in flight answers 3"             "3" "$rc"

gate 0 25; POLL=1 go spira/left fixture          # start a long one and leave it running
is   "a long gate is left running"      "2" "$rc"
go --status spira/left fixture
is   "--status sees it without waiting" "2" "$rc"
want "and names what it is doing"       "still running" "$out"
go --status spira/left fixture
is   "asking again did not stop it"     "2" "$rc"
is   "and did not restart it"           "1" "$(runs spira/left)"

# FAIL CLOSED ON A RUN THAT DIED. Killed with the session that started it, out of memory, a
# reboot: the process is gone and no exit code was ever written. The two readings that must
# not happen are "passed" and "still deciding" — one lands unverified work, the other waits
# forever for something that will never answer.
D="$RUN/gate-run/$(printf 'fixture.spira/left' | tr -c 'A-Za-z0-9._-' '_')"
pid="$(cat "$D/pid" 2>/dev/null)"
[ -n "${pid:-}" ] && ok "the run recorded a pid to kill" || bad "the run recorded a pid" "none at $D/pid"
kill -KILL "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -d "/proc/$pid" ] || break; sleep 0.5; done
go --status spira/left fixture
is   "a run that died without a verdict fails closed" "1" "$rc"
want "and says what happened"                         "without recording a verdict" "$out"

# --------------------------------------------------------------------------------------
# THE UNMANAGED GATE. A session that ran `gate.sh` in its own foreground and had it moved to
# the background leaves no state directory at all, and that is precisely the mistake the
# caller's exit check is aimed at — so the runner reads the process table as a second
# witness. The control above, exit 3 for this same branch moments ago, is what makes this
# assertion mean something.
# --------------------------------------------------------------------------------------
echo
echo "a gate started outside the runner is still a gate:"
GATE_SLEEP=25 bash "$SH/gate.sh" spira/unmanaged fixture >/dev/null 2>&1 &
un=$!
sleep 1
go --status spira/unmanaged fixture
is   "--status sees it"         "2" "$rc"
want "and says whose it is not" "outside this runner" "$out"
kill "$un" 2>/dev/null; wait "$un" 2>/dev/null

# --------------------------------------------------------------------------------------
# THE SHIPPED DEFAULT, at its real value. Every case above drives the budget down to seconds,
# which is the only way to test the shape — and it is also how a default above the tool
# ceiling would go unnoticed forever. An agent's Bash tool moves a foreground command to the
# background at 600s, so a budget at or above that silently reinstates the bug.
# --------------------------------------------------------------------------------------
echo
echo "the shipped budget:"
def="$(sed -n 's/^POLL="${SPIRA_GATE_POLL:-\([0-9][0-9]*\)}".*/\1/p' "$HERE/gate-run.sh" | head -1)"
if [ -n "$def" ]; then
    ok "the default budget is a literal this suite can read"
    [ "$def" -lt 600 ] \
        && ok "and it is under the tool ceiling it exists to respect ($def < 600)" \
        || bad "the default budget is under the tool ceiling" "$def is not less than 600"
else
    bad "the default budget is a literal this suite can read" "no SPIRA_GATE_POLL default in gate-run.sh"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
