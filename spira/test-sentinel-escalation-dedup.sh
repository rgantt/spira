#!/usr/bin/env bash
#
# test-sentinel-escalation-dedup.sh — sentinel.sh escalations carry --ref and --moot-when
#
#   ./test-sentinel-escalation-dedup.sh
#
# WHAT THIS GUARDS. sentinel.sh must pass --ref "escalation:<kind>:<id>" to every $SPIRA_NOTIFY
# add call so ask.sh deduplicates repeated escalations for the same bead, and --moot-when so
# moot-sweep.sh auto-resolves asks whose subject bead has closed. Without both, every sentinel
# pass files a fresh ask (filling the operator's pane with duplicates) and those asks outlive
# the bead they were about (sp-1wrlk).
#
# ACCEPTANCE CRITERIA (all sides paired — law-absence-needs-a-positive-control):
#   1. Same bead, same kind, three different counts → exactly ONE open ask.
#   2. Two different beads, same kind → TWO asks (dedup must not over-merge).
#   3. Same bead, requeue vs reclaim → TWO asks (kind is part of the ref).
#   4. Close the subject bead, run moot-sweep --apply → the ask auto-resolves.
#   5. Subject bead still open, run moot-sweep --apply → the ask survives. (Control.)
#   6. Probe fails (broken DB path) → the ask survives and the sweep does not resolve it.
#
# REAL DEPENDENCIES, NOT MOCKS. The defect lives in the seam between sentinel, ask.sh and
# moot-sweep.sh; a mock of either downstream tool seals over exactly that seam
# (law-prefer-the-real-dependency).
#
# covers: spira/sentinel.sh cockpit/ask.sh cockpit/moot-sweep.sh
# hermetic-ok: uses a fixture database, no systemd or gh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT="$(cd "$HERE/../cockpit" && pwd -P)"
. "$HERE/testdb.sh"
testdb_require test-sentinel-escalation-dedup
testdb_up sentinel-escalation-dedup || { echo "testdb_up failed"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
no()   { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did NOT want [$2] in [$3]"; }

TMP="$(mktemp -d)"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

BD="${TESTDB_BD:-bd}"
bdt() { "$BD" -C "$SPIRA_DB" "$@"; }
ask() { COCKPIT_DB="$SPIRA_DB" bash "$COCKPIT/ask.sh" "$@"; }
sweep() { COCKPIT_DB="$SPIRA_DB" SPIRA_RESOLVE_SH="$COCKPIT/resolve.sh" bash "$COCKPIT/moot-sweep.sh" "$@"; }
sweep_bad_db() { COCKPIT_DB="/tmp/does-not-exist-$$" SPIRA_RESOLVE_SH="$COCKPIT/resolve.sh" bash "$COCKPIT/moot-sweep.sh" "$@"; }

count_open_asks() {
    # Count open beads carrying the ask label only (not work beads).
    local label="${SPIRA_ASK_LABEL:-needs-operator}"
    "$BD" -C "$SPIRA_DB" list --status open --label "$label" --limit 0 --json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get("issues",[]); print(len(d))' 2>/dev/null || echo 0
}

# Build the moot predicate the same way sentinel.sh does: $SPIRA_DB is expanded NOW (it is the
# fixture db throughout the test); \$COCKPIT_DB would expand at sweep time, but since the test
# sets COCKPIT_DB=SPIRA_DB we use the literal path for clarity. The probe logic is identical.
make_moot_pred() {  # make_moot_pred <bead-id>
    local bid="$1"
    printf '%s' "_d=\$(bd -C \"\$COCKPIT_DB\" show $bid --json 2>/dev/null); [ -n \"\$_d\" ] || { printf 'probe: bd show returned nothing\\n'; exit 1; }; printf '%s\\n' \"\$_d\" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=(d[0] if isinstance(d,list) else d); s=r.get(\"status\",\"?\") if r else \"?\"; sys.exit(0 if s != \"open\" else 1)'"
}

# Create a work bead in the fixture database. Prints the bead id.
create_work_bead() {
    bdt create --title "$1" --type task --label "plan,spira" --json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("id",""))' 2>/dev/null || echo ""
}

echo "test-sentinel-escalation-dedup.sh"

# ======================================================================================
echo
echo "positive control — count_open_asks detects a creation"
# ======================================================================================
before="$(count_open_asks)"
ask add "positive-control-ask" --default "do it" >/dev/null 2>&1 || true
after="$(count_open_asks)"
[ "$after" -gt "$before" ] \
    && ok "count_open_asks increases on creation" \
    || bad "count_open_asks increases on creation" "before=$before after=$after"

testdb_reset

# ======================================================================================
echo
echo "1. same bead, same kind, three counts → exactly ONE open ask"
# ======================================================================================
work_a="$(create_work_bead "work-bead-A-reclaim-test")"
[ -n "$work_a" ] \
    && ok  "work bead A created: $work_a" \
    || { bad "work bead A created" "create returned empty id"; work_a="sp-fake-a"; }

moot_a="$(make_moot_pred "$work_a")"

before="$(count_open_asks)"
out5="$(ask  add "Spira bead $work_a — 5 aeons died holding it" \
    --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" \
    --why "reclaim count hit threshold" \
    --moot-when "$moot_a" 2>&1)"
out6="$(ask  add "Spira bead $work_a — 6 aeons died holding it" \
    --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" \
    --why "reclaim count hit threshold" \
    --moot-when "$moot_a" 2>&1)"
out24="$(ask add "Spira bead $work_a — 24 aeons died holding it" \
    --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" \
    --why "reclaim count hit threshold" \
    --moot-when "$moot_a" 2>&1)"
after="$(count_open_asks)"

# Exactly one new open ask (not three).
is "same ref, three calls: exactly one ask created" "$((before+1))" "$after"
want "count=5 call says 'asked'"    "asked"    "$out5"
want "count=6 call says 'recurred'" "recurred" "$out6"
want "count=24 call says 'recurred'" "recurred" "$out24"

testdb_reset

# ======================================================================================
echo
echo "2. two different beads, same kind → TWO asks"
# ======================================================================================
work_a="$(create_work_bead "work-bead-A-two-beads-test")"
work_b="$(create_work_bead "work-bead-B-two-beads-test")"
[ -n "$work_a" ] && [ -n "$work_b" ] \
    && ok  "work beads A ($work_a) and B ($work_b) created" \
    || bad "work beads A and B created" "a=$work_a b=$work_b"

moot_a="$(make_moot_pred "$work_a")"
moot_b="$(make_moot_pred "$work_b")"

before="$(count_open_asks)"
ask add "bead $work_a reclaim" --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" --why "threshold" --moot-when "$moot_a" >/dev/null 2>&1
ask add "bead $work_b reclaim" --ref "escalation:reclaim:$work_b" \
    --default "check cgroups" --why "threshold" --moot-when "$moot_b" >/dev/null 2>&1
after="$(count_open_asks)"

is "different beads: two asks created (not one)" "$((before+2))" "$after"

testdb_reset

# ======================================================================================
echo
echo "3. same bead, requeue vs reclaim → TWO asks (kind is part of the ref)"
# ======================================================================================
work_a="$(create_work_bead "work-bead-A-kind-test")"
[ -n "$work_a" ] \
    && ok  "work bead A created: $work_a" \
    || { bad "work bead A created" "create returned empty id"; work_a="sp-fake-a"; }

moot_a="$(make_moot_pred "$work_a")"

before="$(count_open_asks)"
ask add "bead $work_a requeue" --ref "escalation:requeue:$work_a" \
    --default "fix rebase" --why "threshold" --moot-when "$moot_a" >/dev/null 2>&1
ask add "bead $work_a reclaim" --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" --why "threshold" --moot-when "$moot_a" >/dev/null 2>&1
after="$(count_open_asks)"

is "requeue and reclaim for same bead: two asks" "$((before+2))" "$after"

# Second call with each kind must recur on its own ask, not the other's.
out_rq2="$(ask add "bead $work_a requeue again" --ref "escalation:requeue:$work_a" \
    --default "fix rebase" --why "threshold" --moot-when "$moot_a" 2>&1)"
out_rc2="$(ask add "bead $work_a reclaim again" --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" --why "threshold" --moot-when "$moot_a" 2>&1)"
after2="$(count_open_asks)"

is   "second requeue/reclaim calls recur, not create" "$((before+2))" "$after2"
want "requeue second call says 'recurred'" "recurred" "$out_rq2"
want "reclaim second call says 'recurred'" "recurred" "$out_rc2"

testdb_reset

# ======================================================================================
echo
echo "4. close the subject bead, run moot-sweep --apply → ask auto-resolves"
# ======================================================================================
work_a="$(create_work_bead "work-bead-A-moot-test")"
[ -n "$work_a" ] \
    && ok  "work bead A created: $work_a" \
    || { bad "work bead A created" "create returned empty id"; work_a="sp-fake-a"; }

moot_a="$(make_moot_pred "$work_a")"

ask add "bead $work_a reclaim" --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" --why "threshold" --moot-when "$moot_a" >/dev/null 2>&1

before_open="$(count_open_asks)"
[ "$before_open" -gt 0 ] \
    && ok  "ask is open before closing subject bead" \
    || bad "ask is open before closing subject bead" "count=$before_open"

# Close the subject bead (simulating the work getting done).
bdt close "$work_a" --reason "test: bead resolved" --force >/dev/null 2>&1 \
    && ok  "subject bead $work_a closed" \
    || bad "subject bead $work_a closed" "bd close failed"

# moot-sweep should resolve the ask: the predicate exits 0 (bead not open).
sweep_out="$(sweep --apply 2>&1)"
want "sweep reports ask CLEARED" "CLEARED" "$sweep_out"

after_open="$(count_open_asks)"
is "ask count decreases after moot-sweep" "$((before_open-1))" "$after_open"

testdb_reset

# ======================================================================================
echo
echo "5. subject bead still open → ask survives moot-sweep (control)"
# ======================================================================================
work_a="$(create_work_bead "work-bead-A-survive-test")"
[ -n "$work_a" ] \
    && ok  "work bead A created: $work_a" \
    || { bad "work bead A created" "create returned empty id"; work_a="sp-fake-a"; }

moot_a="$(make_moot_pred "$work_a")"

ask add "bead $work_a reclaim" --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" --why "threshold" --moot-when "$moot_a" >/dev/null 2>&1

before_open="$(count_open_asks)"

# work_a is still open — moot predicate exits 1, ask must NOT be resolved.
sweep --apply >/dev/null 2>&1

after_open="$(count_open_asks)"
is "ask survives when subject bead is still open" "$before_open" "$after_open"

testdb_reset

# ======================================================================================
echo
echo "6. probe fails (broken DB path) → ask survives, sweep does not resolve it"
# ======================================================================================
# File an ask with a predicate that will fail because the DB path is wrong.
# hermetic-ok: bd is inside a string literal passed as --moot-when; moot-sweep evaluates it, not this suite. Path is non-existent by design.
broken_moot="_d=\$(bd -C \"/tmp/does-not-exist-$$\" show sp-fake --json 2>/dev/null); [ -n \"\$_d\" ] || { printf 'probe: bd show returned nothing\n'; exit 1; }; printf 'unreachable'; exit 0"

ask add "bead with failing probe" --ref "escalation:reclaim:sp-broken-probe-$$" \
    --default "check cgroups" --why "threshold" --moot-when "$broken_moot" >/dev/null 2>&1 || true

before_open="$(count_open_asks)"
[ "$before_open" -gt 0 ] \
    && ok  "ask with broken probe is open" \
    || bad "ask with broken probe is open" "count=$before_open"

# Run moot-sweep against the fixture DB (where the ask lives) but the PREDICATE itself
# uses a broken DB path — so bash -c of the predicate exits 1.
sweep_out="$(sweep --apply 2>&1)"
no "sweep does not report broken-probe ask as CLEARED" "CLEARED" "$sweep_out"

after_open="$(count_open_asks)"
is "ask with broken probe survives sweep" "$before_open" "$after_open"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
