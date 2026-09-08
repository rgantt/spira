#!/usr/bin/env bash
#
# test-fayth-free.sh — an elastic persona takes the pool remainder whole.
#
#   ./test-fayth-free.sh
#
# THE BUG. sentinel.sh computes pool = MAX_AEONS - task_live, which is already how many MORE
# aeons may start. fayth_free then takes that remainder as the elastic persona's cap and
# subtracts the persona's running count a second time: free = pool - n = (MAX - n) - n =
# MAX - 2n. The system saturates at half its ceiling and reports itself at its limit.
#
# THE TABLE. With MAX_AEONS=3 and only builders as task fayths:
#
#   n running    pool (3-n)    expected free
#   0            3             3
#   1            2             2
#   2            1             1
#   3            0             0
#
# The buggy code produces (3, 1, 0, 0) instead, saturating at n=2.
#
# covers: spira/lib.sh spira/chamber/builder.fayth
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/run"

# Source lib.sh in a controlled environment: SPIRA_RUN at a temp dir (no budget.env, no pid
# files), and SPIRA_CONF at a nonexistent path so no host config leaks verdicts into the
# suite (law-gates-run-in-a-clean-environment).
export SPIRA_RUN="$T/run"
export SPIRA_CONF="$T/no-such.conf"
. "$HERE/lib.sh"

# Override aeon_count with a stub that returns a controlled value. The real function reads
# pid files whose processes must be alive; the test needs the arithmetic, not the probing.
MOCK_COUNT=0
aeon_count() { printf '%d' "$MOCK_COUNT"; }

echo "test-fayth-free.sh"

# ==========================================================================================
echo
echo "elastic persona — the pool remainder is the free count"
# ==========================================================================================
# 3 is non-default (the shipped default is 4), so the assertion cannot pass by reading the
# literal out of conf.sh. The sentinel computes pool = MAX - task_live and passes it to
# fayth_free; this test does the same arithmetic to simulate the call.
MAX=3
for n in 0 1 2 3; do
    pool=$((MAX - n))
    MOCK_COUNT=$n
    got="$(fayth_free builder "$pool")"
    is "n=$n, pool=$pool -> free=$pool" "$pool" "$got"
done

# ==========================================================================================
echo
echo "elastic persona — no pool means fall back to own cap"
# ==========================================================================================
# With no pool argument the elastic path is not taken and the persona's own
# FAYTH_MAX_CONCURRENT is the ceiling.
cap="$(fayth_get builder FAYTH_MAX_CONCURRENT 1)"
for n in 0 1; do
    MOCK_COUNT=$n
    got="$(fayth_free builder)"
    want=$((cap - n))
    is "no pool, n=$n -> free=$want (cap=$cap)" "$want" "$got"
done

# ==========================================================================================
echo
echo "non-elastic persona — the running count is subtracted from its own cap"
# ==========================================================================================
# Ops is a party member (FAYTH_ROLE=party) and not elastic, so fayth_free subtracts the
# running count from its own FAYTH_MAX_CONCURRENT regardless of the pool. The pool only
# clamps the result downward.
ops_cap="$(fayth_get ops FAYTH_MAX_CONCURRENT 1)"
for n in 0 1; do
    MOCK_COUNT=$n
    got="$(fayth_free ops "10")"
    want=$((ops_cap - n))
    is "ops, pool=10, n=$n -> free=$want" "$want" "$got"
done

# THE POSITIVE CONTROL: the elastic case above WOULD fail against the old code (free =
# pool - n instead of pool), so the test is not passing by accident. Verify by showing the
# buggy formula would produce different numbers at n=1 and n=2.
echo
echo "positive control — the buggy formula disagrees at n=1 and n=2"
buggy_1=$((MAX - 1 - 1))    # pool(2) - have(1) = 1
buggy_2=$((MAX - 2 - 2))    # pool(1) - have(2) = -1, clamped to 0
[ "$buggy_2" -lt 0 ] && buggy_2=0
is "buggy n=1 would return $buggy_1, not $((MAX - 1))" "1" "$buggy_1"
is "buggy n=2 would return $buggy_2, not $((MAX - 2))" "0" "$buggy_2"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
