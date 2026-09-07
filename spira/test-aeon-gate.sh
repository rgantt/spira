#!/usr/bin/env bash
#
# test-aeon-gate.sh — what an aeon's exit path does about a gate that is still deciding.
#
#   ./test-aeon-gate.sh
#
# THE BEAD THIS SUITE WAS WRITTEN FOR states its acceptance in one sentence: a session that
# ends while a background task holds its gate verdict must not leave the bead in_progress
# with an attempt charged. The gate outgrew the ceiling an agent's tool puts on one command,
# so the tool moved it to the background and handed the session a task id; ending the turn to
# wait for that ended the session; the bead was released, the attempt was charged, and a fresh
# aeon was summoned onto the same bead ninety-three seconds later to run the same long gate
# again. Seventeen sessions ended that way.
#
# So this runs the REAL aeon.sh against a real bd, a real git repository and a real claim,
# because the property is about what a session LEAVES BEHIND. test-gate-run.sh holds the
# runner in isolation; this is the half that says the exit path consults it.
#
# WHAT IS FAKED, AND WHY ONLY THIS. `claude` is a shim, injected through SPIRA_CLAUDE, that
# behaves like the sessions that produced the bug — it starts a gate that will not finish and
# then ends. That is the one thing that cannot be arranged on demand. The gate it starts is a
# stub that sleeps, because the property is wall clock and a real thirteen-minute gate would
# make this suite thirteen minutes long. Everything else — the database, the claim, the
# lease, the attempt labels, the worktree, the detached run and its process — is real
# (law-prefer-the-real-dependency).
#
# covers: spira/aeon.sh spira/chamber/*
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-aeon-gate

TMP="$(mktemp -d)"
# The gate runs are detached ON PURPOSE, so deleting the scratch tree is not enough: a suite
# that only did that would leave stub gates sleeping against a directory that is gone.
cleanup_all() {
    local d p
    for d in "$TMP"/run/gate-run/*; do
        [ -f "$d/pid" ] || continue
        p="$(cat "$d/pid" 2>/dev/null)"; [ -n "${p:-}" ] || continue
        kill -KILL "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null
    done
    testdb_drop; rm -rf "$TMP"
}
trap cleanup_all EXIT INT TERM
testdb_up aeongate || { echo "test-aeon-gate: could not build a fixture database"; exit 1; }

# ---- a real repository, a real chamber, a real runtime ---------------------------------
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo seed > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm seed

export SPIRA_HOME="$TMP/home"; mkdir -p "$SPIRA_HOME/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/aeon.sh" "$HERE/gate-run.sh" "$SPIRA_HOME/"
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_REPO_MAP="$TMP/repo-map"
printf 'fixture | %s | push | main | |\n' "$REPO" > "$SPIRA_REPO_MAP"

cat > "$SPIRA_HOME/chamber/builder.fayth" <<FAYTH
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
FAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=600
FAYTH
printf 'work {{BEAD_ID}} in {{REPO}} on {{BRANCH}}\n\n{{GATE}}\n' > "$SPIRA_HOME/chamber/builder.md"

# The gate the runner runs. It sleeps for as long as the case asks and records that it ran.
cat > "$SPIRA_HOME/gate.sh" <<'STUB'
#!/usr/bin/env bash
echo "ran $1" >> "$GATE_LOG"
sleep "${GATE_SLEEP:-0}"
exit "${GATE_RC:-0}"
STUB
chmod +x "$SPIRA_HOME/gate.sh"
export GATE_LOG="$TMP/gate.log"; : > "$GATE_LOG"

# ---- the shim --------------------------------------------------------------------------
# It reproduces the session that produced the bug: start the gate, get back "still deciding",
# end the turn. SESSION_MODE picks which of the shapes under test it plays.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'SHIM'
#!/usr/bin/env bash
# The marker is the suite's proof that THIS ran and not something else. Without it a suite
# whose shim was never reached passes every "no attempt was charged" assertion, because a
# session that never happened charges nothing either.
cat /dev/stdin > "$TRACE.prompt"
: > "$TRACE.ran"
br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "${SESSION_MODE:-idle}" in
    gate-then-exit)
        SPIRA_GATE_POLL=1 SPIRA_GATE_TICK=1 \
            bash "$SHIM_HOME/gate-run.sh" "$br" fixture >> "$TRACE.gate" 2>&1
        ;;
    unmanaged-then-exit)
        # Straight at gate.sh, exactly as a session does when it has not been told about the
        # runner: no state directory anywhere, and the process table is the only witness.
        setsid bash "$SHIM_HOME/gate.sh" "$br" fixture </dev/null >/dev/null 2>&1 &
        echo $! > "$TRACE.unmanaged"
        sleep 1
        ;;
    gate-then-close)
        SPIRA_GATE_POLL=1 SPIRA_GATE_TICK=1 \
            bash "$SHIM_HOME/gate-run.sh" "$br" fixture >> "$TRACE.gate" 2>&1
        echo work > gated.txt && git add -A && git commit -qm "feat: $BEAD_UNDER_TEST — work"
        bd -C "$SPIRA_DB" close "$BEAD_UNDER_TEST" --reason "done" >/dev/null 2>&1
        ;;
esac
exit 0
SHIM
chmod +x "$BIN/claude"
# SPIRA_CLAUDE, NEVER A PATH SHIM. conf.sh replaces $PATH outright when aeon.sh sources it,
# so a fake `claude` placed first on PATH is thrown away and the REAL model runs — against
# the operator's own account, for as long as the suite is left alone. Asserted rather than
# merely used, because the failure is silent and expensive.
export SPIRA_CLAUDE="$BIN/claude"
grep -q 'SPIRA_CLAUDE' "$HERE/aeon.sh" \
    || { echo "test-aeon-gate: aeon.sh has no SPIRA_CLAUDE injection point — this suite would run the REAL model. Refusing." >&2; exit 1; }
export TRACE="$TMP/trace" SHIM_HOME="$SPIRA_HOME"

seed_bead() {   # seed_bead <id> — one open plan bead in the fixture repository
    testdb_reset
    printf '{"id":"%s","title":"t","status":"open","issue_type":"task","labels":["spira","plan","repo:fixture"],"updated_at":"2026-09-04T00:00:00Z"}\n' "$1" \
        | testdb_seed
}
run_aeon() {    # run_aeon <id> <mode> <gate-seconds>
    export BEAD_UNDER_TEST="$1" SESSION_MODE="$2" GATE_SLEEP="$3" GATE_RC=0
    rm -rf "$SPIRA_RUN/worktree" "$TRACE.ran" "$TRACE.gate" "$TRACE.unmanaged"
    "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1
}
kill_gates() {
    local d p
    for d in "$SPIRA_RUN"/gate-run/*; do
        [ -f "$d/pid" ] || continue
        p="$(cat "$d/pid" 2>/dev/null)"; [ -n "${p:-}" ] || continue
        kill -KILL "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null
    done
    if [ -f "$TRACE.unmanaged" ]; then
        p="$(cat "$TRACE.unmanaged")"; kill -KILL "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null
    fi
    rm -rf "$SPIRA_RUN/gate-run"
}
shim_ran()  { [ -f "$TRACE.ran" ] && echo yes || echo no; }
attempts()  { bd -C "$SPIRA_DB" label list "$1" 2>/dev/null \
              | grep -oE 'sp-attempt-[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1; }
status_of() { bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' \
              | python3 -c 'import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("status",""))' 2>/dev/null; }
# `bd show` word-wraps a note to the terminal width, so a needle longer than one wrapped
# line never matches however exactly right the note is. Folding the whitespace first asserts
# about the TEXT rather than about the renderer.
notes_of()  { bd -C "$SPIRA_DB" show "$1" 2>/dev/null | tr -s ' \n' ' '; }

echo "test-aeon-gate.sh"

# --------------------------------------------------------------------------------------
# THE BRIEF SAYS HOW. A placeholder that never expands leaves the literal `{{GATE}}` in front
# of the aeon, which is worse than saying nothing — and that has happened here before, to
# {{PARK}}. The rendered brief is part of the deliverable.
# --------------------------------------------------------------------------------------
echo
echo "the brief tells the session how to run the gate:"
seed_bead sp-brief
run_aeon sp-brief idle 0
is     "the fake session ran, not the real one" "yes" "$(shim_ran)"
want   "the brief names the runner"    "gate-run.sh spira/sp-brief fixture" "$(cat "$TRACE.prompt")"
nowant "with no placeholder left in it" "{{GATE}}" "$(cat "$TRACE.prompt")"
kill_gates

# --------------------------------------------------------------------------------------
# THE CONTROL, FIRST. A session that ends without closing its bead and with NO gate in flight
# is an ordinary failed attempt and must still be charged for one — otherwise the exemption
# below is not an exemption, it is the removal of poison (law-absence-needs-a-positive-control).
# --------------------------------------------------------------------------------------
echo
echo "a session that just ends, with nothing in flight:"
seed_bead sp-plain
run_aeon sp-plain idle 0
is   "the bead is open again"      "open" "$(status_of sp-plain)"
is   "and an attempt was charged"  "1"    "$(attempts sp-plain)"
want "and the log says so"         "not closed (attempt 1)" "$(cat "$TMP/out")"
kill_gates

# --------------------------------------------------------------------------------------
# THE BEAD'S CASE. The session started a gate that will not finish inside its budget, was
# told so, and ended anyway. The bead must come back with NO attempt charged: it lost a race
# it was never given a chance to run.
# --------------------------------------------------------------------------------------
echo
echo "a session that ends while its gate is still deciding:"
seed_bead sp-mid
run_aeon sp-mid gate-then-exit 45
want "the session really started a gate" "still running"  "$(cat "$TRACE.gate" 2>/dev/null)"
is   "the gate really ran"               "1"             "$(grep -c '^ran spira/sp-mid$' "$GATE_LOG")"
is   "the bead is open again"            "open"          "$(status_of sp-mid)"
is   "and NO attempt was charged"        ""              "$(attempts sp-mid)"
want "the log names the reason"          "released with its gate still running" "$(cat "$TMP/out")"
want "and the ledger records it as its own outcome" "status=gate-unfinished" \
     "$(cat "$SPIRA_RUN/aeon-ledger.log")"
want "and the bead carries the reason, not just a log" "the session ended while its landing gate was still running" \
     "$(notes_of sp-mid)"
kill_gates

# --------------------------------------------------------------------------------------
# AND IT BINDS THE MISTAKE, NOT THE WELL-BEHAVED PATH. A session that reached past the runner
# and ran `gate.sh` in its own foreground leaves no state directory at all — which is exactly
# the shape that produced the bug, since the runner did not exist then. The check must see it
# anyway (law-guard-binds-the-caller).
# --------------------------------------------------------------------------------------
echo
echo "a session that ran the gate itself and ended:"
seed_bead sp-raw
run_aeon sp-raw unmanaged-then-exit 45
is   "the bead is open again"     "open" "$(status_of sp-raw)"
is   "and NO attempt was charged" ""     "$(attempts sp-raw)"
want "and the reason names it"    "outside this runner" "$(cat "$TMP/out")"
kill_gates

# --------------------------------------------------------------------------------------
# A CLOSE REACHED WITHOUT A VERDICT IS NOT REOPENED, BUT IT IS NOT SILENT EITHER. The work is
# committed and the landing pass gates the branch again before it merges, so reopening here
# would spend a whole session to re-derive what landing is about to check. What must not
# happen is for the bead to record a verdict the session never held with nothing to say so.
# --------------------------------------------------------------------------------------
echo
echo "a session that closes its bead with the gate still running:"
seed_bead sp-closed
run_aeon sp-closed gate-then-close 45
is   "the bead stays closed"  "closed" "$(status_of sp-closed)"
want "and says the close carries no gate verdict" "The close carries no gate verdict" \
     "$(notes_of sp-closed)"
want "and the log says it too" "closed with its gate still running" "$(cat "$TMP/out")"
kill_gates

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
