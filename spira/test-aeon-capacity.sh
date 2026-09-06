#!/usr/bin/env bash
#
# test-aeon-capacity.sh — the acceptance criterion, end to end through the real aeon.sh.
#
#   ./test-aeon-capacity.sh
#
# The bead this suite was written for states its acceptance in one sentence: with the API
# refusing the session, a claimed bead is returned unchanged and carries no new attempt; the
# harness stops summoning until the window resets; and a bead that genuinely fails three
# times still poisons. test-capacity.sh holds the detector and test-fayth.sh holds the summon
# gate, both in isolation. This suite is the one that runs `aeon.sh` itself against a real
# `bd`, a real git repository and a real claim, because the property is about what a session
# LEAVES BEHIND — and the three earlier attempts at this bug class in this harness were all
# defects in code that looked right function by function.
#
# WHAT IS FAKED, AND WHY ONLY THIS. `claude` is a shim on PATH that prints a prepared session
# trace and exits non-zero. That is the one thing that cannot be arranged on demand: an
# account cannot be made to run out of capacity for a test. Everything else — the database,
# the claim, the lease, the worktree, the labels — is the real thing
# (law-prefer-the-real-dependency).
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
testdb_require test-aeon-capacity

TMP="$(mktemp -d)"
cleanup_all() { testdb_drop; rm -rf "$TMP"; }
trap cleanup_all EXIT INT TERM
# THE FIXTURE COMES FROM testdb_up, NEVER A DIRECT `bd init`. The landing gate builds one
# database for the whole run and exports TESTDB_SHARED; testdb_up honours an inherited one by
# resetting it to its baseline instead of building a second, which is the same isolation this
# suite already relies on between its own cases. Measured: 63s when it builds its own against
# 26s when it inherits, so an edit that reaches past testdb_up to build a database directly
# adds that difference to every gate run and nothing anywhere reports that it did.
testdb_up aeoncap || { echo "test-aeon-capacity: could not build a fixture database"; exit 1; }

RESETS="$(( $(date +%s) + 3600 ))"

# ---- a real repository, a real chamber, a real runtime ---------------------------------
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo seed > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm seed

export SPIRA_HOME="$TMP/home"; mkdir -p "$SPIRA_HOME/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/aeon.sh" "$SPIRA_HOME/"
cp -r "$HERE/actors" "$SPIRA_HOME/" 2>/dev/null || true
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_CAPACITY_PAUSE="$SPIRA_RUN/capacity-pause"
export SPIRA_REPO_MAP="$TMP/repo-map"
printf 'fixture | %s | push | main | |\n' "$REPO" > "$SPIRA_REPO_MAP"

cat > "$SPIRA_HOME/chamber/builder.fayth" <<FAYTH
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
FAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=600
FAYTH
printf 'work {{BEAD_ID}} in {{REPO}} on {{BRANCH}}\n' > "$SPIRA_HOME/chamber/builder.md"

# ---- the shim ---------------------------------------------------------------------------
# It writes whatever $TMP/trace holds and exits non-zero — the SAME exit code for a refusal
# and for a genuine failure, because that identity is the whole bug: the harness could not
# tell them apart from the exit status, and this suite must not be able to either.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'SHIM'
#!/usr/bin/env bash
# The marker is the suite's proof that THIS ran and not something else. Without it, a suite
# whose shim was never reached passes every "no attempt was charged" assertion, because a
# session that never happened charges nothing either.
: > "$TRACE.ran"
cat /dev/stdin >/dev/null 2>&1
cat "$TRACE"
exit 1
SHIM
chmod +x "$BIN/claude"
# SPIRA_CLAUDE, NEVER A PATH SHIM. conf.sh replaces $PATH outright when aeon.sh sources it,
# so a fake `claude` placed first on PATH is thrown away and the REAL model runs — against
# the operator's own account, for as long as the suite is left alone. The first draft of this
# file did exactly that and had to be killed by hand; the injection point exists because of
# it. Asserted below rather than merely used, because the failure is silent and expensive.
export SPIRA_CLAUDE="$BIN/claude"
grep -q 'SPIRA_CLAUDE' "$HERE/aeon.sh" \
    || { echo "test-aeon-capacity: aeon.sh has no SPIRA_CLAUDE injection point — this suite would run the REAL model. Refusing." >&2; exit 1; }

rl_event() {
    printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s}}},"uuid":"u","session_id":"s"}\n' \
        "$1" "$RESETS" "${2:-1}" "$RESETS"
}
trace_refused() { { rl_event rejected 1
    printf '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets 12pm (UTC)","num_turns":1}\n'; } > "$TMP/trace"; }
trace_failed()  { { rl_event allowed 0.1
    printf '{"type":"result","subtype":"success","is_error":true,"result":"Error: could not do the work","num_turns":9}\n'; } > "$TMP/trace"; }

export TRACE="$TMP/trace"

seed_bead() {   # seed_bead <id> — one open plan bead in the fixture repository
    testdb_reset
    printf '{"id":"%s","title":"t","status":"open","issue_type":"task","labels":["spira","plan","repo:fixture"],"updated_at":"2026-09-04T00:00:00Z"}\n' "$1" \
        | testdb_seed
}
run_aeon() { rm -rf "$SPIRA_RUN/worktree" "$TRACE.ran"; "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1; }
shim_ran() { [ -f "$TRACE.ran" ] && echo yes || echo no; }
labels()   { bd -C "$SPIRA_DB" label list "$1" 2>/dev/null | tr -d ' '; }
status_of(){ bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' \
             | python3 -c 'import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("status",""))' 2>/dev/null; }

echo
echo "a session the account refused costs the bead nothing:"
rm -f "$SPIRA_CAPACITY_PAUSE"
seed_bead sp-cap-1
trace_refused
run_aeon
is   "the fake session ran, not the real one" "yes" "$(shim_ran)"
want "the aeon claimed and worked it" "sp-cap-1" "$(cat "$TMP/out")"
# THE HEARTBEAT READS $LOGF FROM A SUBSHELL THAT FORKS BEFORE IT. It was assigned 150 lines
# below that fork, so every beat expanded an unbound variable under `set -u`, `now` came back
# empty, empty compared equal to the previous empty, and the stall counter read "no progress"
# on a session doing nothing but progress — so every aeon stopped heartbeating after 20
# minutes however hard it was working, lost its lease, and was ghost-reclaimed WITH AN
# ATTEMPT CHARGED. That is this bead's harm through a second door, and the tell is one line
# on stderr that nothing was reading.
nowant "the heartbeat reads no unbound variable" "unbound variable" "$(cat "$TMP/out")"
# THE CENTRAL ASSERTION. Under the old code this bead came back carrying sp-attempt-1.
is   "no attempt was charged"        "" "$(labels sp-cap-1 | grep -o 'sp-attempt-[0-9]*' | tr '\n' ' ')"
is   "the bead is open again"        "open" "$(status_of sp-cap-1)"
want "and the log says why"          "ran out of capacity" "$(cat "$TMP/out")"
[ -f "$SPIRA_CAPACITY_PAUSE" ] && ok "the pause is recorded" \
    || bad "the pause is recorded" "no $SPIRA_CAPACITY_PAUSE"
is   "and runs to the epoch the account named" "$RESETS" "$(awk 'NR==1{print $1}' "$SPIRA_CAPACITY_PAUSE")"
want "the ledger records the pause once" "CAPACITY paused until" "$(cat "$SPIRA_RUN/aeon-ledger.log")"

# THE PAUSE MUST BIND THE AEON ITSELF, not only the sentinel that usually summons it:
# spira-ops.service starts one directly, so a guard on one caller binds the disciplined
# caller and misses the other (law-guard-binds-the-caller).
echo
echo "a paused account stops the next aeon before it claims anything:"
seed_bead sp-cap-2
run_aeon
is   "the bead was never claimed" "open" "$(status_of sp-cap-2)"
is   "and carries no attempt"     "" "$(labels sp-cap-2 | grep -o 'sp-attempt-[0-9]*' | tr '\n' ' ')"
want "and the aeon says why"      "out of capacity" "$(cat "$TMP/out")"
want "the ledger counts it as a live aeon that declined" "awake builder paused" "$(cat "$SPIRA_RUN/aeon-ledger.log")"

echo
echo "a genuine failure still charges an attempt, three times over:"
rm -f "$SPIRA_CAPACITY_PAUSE"
seed_bead sp-fail-1
trace_failed
for i in 1 2 3; do
    run_aeon
    is "attempt $i is charged" "$i" "$(bd -C "$SPIRA_DB" label list sp-fail-1 2>/dev/null \
        | grep -oE 'sp-attempt-[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)"
done
[ ! -f "$SPIRA_CAPACITY_PAUSE" ] && ok "and no capacity pause was invented" \
    || bad "and no capacity pause was invented" "a pause was written for an ordinary failure"
# CHECK 4's threshold is 3, and it reads exactly this label. A bead that reaches it is one
# the sentinel will poison — which is the property a too-eager detector would have removed.
is "the bead has reached the poison threshold" "3" "$(bd -C "$SPIRA_DB" label list sp-fail-1 2>/dev/null \
    | grep -oE 'sp-attempt-[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)"

# ---- every attempt's trace survives -----------------------------------------------------
# aeon.sh opened the session log with `>`, so an attempt erased its predecessor and only the
# LAST session of a bead had a trace. On the day a capacity outage killed 121 sessions in
# three to seven seconds each, three traces survived — and with them went the only record of
# why any of the others died (the operator, verbatim: "I don't want to miss any insights from
# here on").
#
# The whole risk of appending is on the other side: the file now holds sessions that are
# over, and a reader that takes an old segment for the live one does real harm. So the two
# attempts here are ordered REFUSED then FAILED, which is the pairing where a reader with no
# sense of the boundary gets it wrong — it would find attempt 1's refusal, hand back the
# attempt attempt 2 has just earned, and pause the harness against a window already reopened.
#
# The library is sourced in a subshell rather than at the top of this file: the suite runs
# aeon.sh as a program in an explicit minimal environment, and that must stay the thing being
# measured (law-gates-run-in-a-clean-environment).
in_lib() { ( . "$SPIRA_HOME/lib.sh" >/dev/null 2>&1 || exit 9; "$@" ); }
tool_line() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$1"; }

echo
echo "two attempts on one bead leave two traces, and the newest is what the harness reads:"
rm -f "$SPIRA_CAPACITY_PAUSE"
seed_bead sp-keep-1
KEEP="$SPIRA_RUN/sp-keep-1.log"
rm -f "$KEEP"

{ tool_line "the first attempt ran"; rl_event rejected 1
  printf '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your session limit · resets 12pm (UTC)","num_turns":1}\n'; } > "$TMP/trace"
run_aeon
is   "the fake session ran for attempt 1" "yes" "$(shim_ran)"
[ -s "$KEEP" ] && ok "attempt 1 left a trace" || bad "attempt 1 left a trace" "no $KEEP"
size1="$(stat -c %s "$KEEP" 2>/dev/null || echo 0)"

# The window reopens and the bead is worked again — this time the session fails at its own
# work. No reseed: that would reset the fixture and take the first attempt's evidence with it.
rm -f "$SPIRA_CAPACITY_PAUSE"
{ tool_line "the second attempt ran"; rl_event allowed 0.1
  printf '{"type":"result","subtype":"success","is_error":true,"result":"Error: could not do the work","num_turns":9}\n'; } > "$TMP/trace"
run_aeon
size2="$(stat -c %s "$KEEP" 2>/dev/null || echo 0)"

want "attempt 1's trace is still there"  "the first attempt ran"  "$(cat "$KEEP")"
want "and attempt 2's is there too"      "the second attempt ran" "$(cat "$KEEP")"
is   "each attempt opened its own segment" "2" "$(grep -c '^=== spira attempt ' "$KEEP")"
# THE HEARTBEAT'S SIGNAL IS THIS FILE GROWING. It decides a session is wedged by watching
# `stat -c %s` on this exact path, which is why the trace is appended to one file per bead
# rather than written to a new name per attempt: a name that changed would leave the beat
# staring at a file nobody writes, and cost the bead its lease for working.
[ "$size2" -gt "$size1" ] && ok "the log grew rather than restarting, so the beat still sees progress" \
    || bad "the log grew rather than restarting" "was $size1 bytes, now $size2"

# THE BOUNDARY IS DOING THE WORK, shown from both sides: the refusal IS in the file, and is
# NOT in the segment the harness reads. Without the first half, the second passes just as
# well on a suite whose attempt 1 never happened.
want "the refusal is in the file"            "hit your session limit" "$(cat "$KEEP")"
nowant "but not in the segment now read"     "hit your session limit" "$(in_lib attempt_trace "$KEEP")"
in_lib capacity_reset_at "$KEEP" >/dev/null
is   "so capacity_reset_at judges attempt 2, not attempt 1" "1" "$?"
is   "and the heartbeat sees attempt 2's last action" "Bash the second attempt ran" "$(in_lib trace_last "$KEEP")"

# WHAT THAT VERDICT COST THE BEAD. Attempt 2 failed at its own work, so it is charged — and
# a reader fooled by attempt 1's refusal would have charged nothing and stopped summoning.
is   "attempt 2 is charged, and only attempt 2" "1" "$(labels sp-keep-1 | grep -oE 'sp-attempt-[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)"
[ ! -f "$SPIRA_CAPACITY_PAUSE" ] && ok "and no stale pause was written from the older segment" \
    || bad "and no stale pause was written from the older segment" "$(cat "$SPIRA_CAPACITY_PAUSE")"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
