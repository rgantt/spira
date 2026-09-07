#!/usr/bin/env bash
#
# test-aeon-priority.sh — resumption reorders within a priority and never across one.
#
#   ./test-aeon-priority.sh
#
# THE PROPERTY. aeon.sh prefers a bead whose branch is already ahead of its base over one
# with nothing started, because an unfinished branch decays and every pass it sits costs
# another rebase. That preference is correct among PEERS and a priority inversion across
# bands: the first version took the first resumable candidate at any depth, so one P1 with a
# single commit beat seven P0s with nothing started. Measured 2026-09-07 against the live
# queue, the head was sp-2tv — the bead describing this very starvation — and the selector
# reached past it to candidate twelve, sp-4vp, on every pass for hours.
#
# WHY THIS SUITE ASSERTS AGAINST THE SHIPPED PROGRAM. The candidate filter is a python
# program embedded in aeon.sh, and a copy of it pasted here would be a model of the thing
# under test: deleting the `if prio(i) != top: continue` line in aeon.sh would leave this
# suite green, which is the one outcome that matters. So the program is EXTRACTED from
# aeon.sh at run time and fed synthetic payloads. No database and no git — the property is
# about ordering, and a suite that needed a Dolt server to state it would not be run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }

# ---- the shipped selector, lifted out of aeon.sh ----------------------------------------
# Between the interpreter's own first line and the line that closes the python with a quote.
# If aeon.sh stops containing a program of this shape the extraction yields nothing and every
# assertion below fails loudly, which is the correct outcome for a suite whose subject moved.
SEL="$(mktemp)"; trap 'rm -f "$SEL"' EXIT INT TERM
awk '/^import sys, json$/{g=1} g{print} /print\("%s\|%s\|%s\|%s"/{if(g){exit}}' \
    "$HERE/aeon.sh" | sed "s/' 2>\/dev\/null.*//" > "$SEL"
[ -s "$SEL" ] && ok "the selector was found in aeon.sh" \
              || bad "the selector was found in aeon.sh" "extracted nothing"

sel() { python3 "$SEL" | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//'; }
bead() { # bead <id> <priority> [branch]
    printf '{"id":"%s","priority":%s,"labels":["spira","plan","repo:spira"%s]}' \
        "$1" "$2" "${3:+,\"branch:$3\"}"
}
payload() { printf '[%s]\n' "$(printf '%s,' "$@" | sed 's/,$//')"; }

# ---- the live shape that produced the defect --------------------------------------------
# Seven P0s with nothing started, then P1s of which one carries a branch. The selector must
# offer only the P0 band; the resumable P1 must not be reachable at all.
got="$(payload "$(bead sp-2tv 0)" "$(bead sp-n21 0)" "$(bead sp-7pi 0)" \
               "$(bead sp-auron 1)" "$(bead sp-4vp 1 spira/sp-4vp)" | sel)"
is "a resumable P1 is not offered while any P0 is ready" "sp-2tv sp-n21 sp-7pi" "$got"

# ---- resumption still works, which is the half worth keeping -----------------------------
got="$(payload "$(bead sp-a 1)" "$(bead sp-b 1 spira/sp-b)" "$(bead sp-c 2 spira/sp-c)" | sel)"
is "peers of the top band are all offered, so the branch test can pick among them" \
   "sp-a sp-b" "$got"

# ---- one band only, however many there are ----------------------------------------------
got="$(payload "$(bead sp-x 3)" "$(bead sp-y 2)" "$(bead sp-z 2)" | sel)"
is "the best priority wins even when it is not P0" "sp-y sp-z" "$got"

# ---- order is not trusted ----------------------------------------------------------------
# `bd ready` returns priority order today and nothing promises it will keep doing so. The
# filter takes a minimum rather than breaking on the first change, so a shuffled payload
# must give the same answer.
got="$(payload "$(bead sp-lo 2 spira/sp-lo)" "$(bead sp-hi 0)" "$(bead sp-mid 1)" | sel)"
is "a payload out of priority order still yields the top band" "sp-hi" "$got"

# ---- an unstated priority must never outrank a stated P0 ---------------------------------
# `min()` over a missing field is how a null becomes the best row in the queue. It sorts
# last here, deliberately: an unknown outranking a declared P0 is the defect this suite
# exists under, arriving through the back door.
got="$(printf '[{"id":"sp-null","labels":["spira"]},%s]\n' "$(bead sp-real 0)" | sel)"
is "a bead with no priority does not outrank a P0" "sp-real" "$got"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
