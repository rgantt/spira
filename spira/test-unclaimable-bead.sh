#!/usr/bin/env bash
#
# test-unclaimable-bead.sh — detect_unclaimable_ready surfaces ready beads no persona can claim
#
# THE DEFECT. sp-f8vry was closed with the detection explicitly not built: "PERMANENT FIX
# NEEDED: Add detection in sentinel CHECK 7 to identify ready beads with no claimable
# persona." The commit it cited (c87909a) asserted only "bead created successfully" — a
# tautology. Seven P1 beads carried fayth:ops on spira,plan labels for fifteen hours while
# the sentinel reported every partition empty, truthfully, on every pass.
#
# THE FIX. detect_unclaimable_ready (lib.sh) reads all ready beads without a partition
# filter, tests each against the full chamber using the same claimers() arithmetic as
# bead.sh, and emits UNCLAIMABLE for any with an empty intersection. It distinguishes an
# idle queue (no beads) from a blocked one (beads present, none claimable).
#
# TWO FAILURE MODES:
#   1. fayth:<persona> on partition labels that persona does not own — the fifteen-hour
#      strand: builder matches the labels, is excluded by the preference; the named persona
#      (ops) is excluded by its own partition. Intersection: empty.
#   2. spira with no partition label — a bead invisible to every persona by construction.
#
# BEFORE THIS FIX, running this suite printed "0 passed, 1 failed" because bd create
# rejected --status (unknown flag) and the test never reached any real assertion.
# After: all cases pass.
#
# defect: sp-9zyu1 sp-f8vry
# covers: spira/lib.sh spira/sentinel.sh
# hermetic-ok: uses a fixture database, no systemd or gh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL — %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
lacks(){ [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-unclaimable-bead
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up unclaimable || { echo "test-unclaimable-bead: could not build fixture database"; exit 1; }

export SPIRA_HOME="$HERE"
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_CONF="$TMP/no-such.conf"
acted=0; progressed=0
act()      { acted=$((acted+1)); }
progress() { progressed=$((progressed+1)); act "$@"; }
log()      { : ; }
# shellcheck disable=SC1090
. "$HERE/lib.sh"

echo "test-unclaimable-bead.sh"

# ==========================================================================================
echo
echo "case 1 — positive control: a claimable bead (builder: spira,plan) is NOT flagged"
# ==========================================================================================
# Without this, a detect-everything implementation reads as correct. A bead builder can
# claim must pass through detect_unclaimable_ready without producing a UNCLAIMABLE line.
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-unc1a","title":"claimable builder bead","status":"open","issue_type":"task","labels":["plan","repo:spira","spira"]}
JSONL

out="$(detect_unclaimable_ready 2>/dev/null)"
lacks "claimable builder bead is not flagged" "sp-unc1a" "$out"

# ==========================================================================================
echo
echo "case 2 — fayth:ops on spira,plan labels is UNCLAIMABLE (the fifteen-hour strand)"
# ==========================================================================================
# builder matches the partition but is excluded by fayth:ops; ops is excluded by its own
# partition (needs spira,incident, not spira,plan). The sentinel reported every partition
# empty for fifteen hours; this check names the bead and why.
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-unc2a","title":"unclaimable fayth:ops on plan labels","status":"open","issue_type":"task","labels":["fayth:ops","plan","repo:spira","spira"]}
JSONL

out="$(detect_unclaimable_ready 2>/dev/null)"
has  "fayth:ops on spira,plan: UNCLAIMABLE line emitted" "UNCLAIMABLE sp-unc2a" "$out"
has  "fayth:ops on spira,plan: names the preference"      "fayth:ops"            "$out"
has  "fayth:ops on spira,plan: names the rejection"       "ops"                  "$out"

# ==========================================================================================
echo
echo "case 3 — spira with no partition label is UNCLAIMABLE (the sp-bvo7 route)"
# ==========================================================================================
# No persona's partition (spira,plan; spira,incident; ...) is a subset of {spira,repo:spira}.
# Every persona reports 0, every report is truthful. This check distinguishes it from idle.
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-unc3a","title":"unclaimable no partition label","status":"open","issue_type":"task","labels":["repo:spira","spira"]}
JSONL

out="$(detect_unclaimable_ready 2>/dev/null)"
has  "spira no partition: UNCLAIMABLE line emitted"   "UNCLAIMABLE sp-unc3a" "$out"
has  "spira no partition: names a partition to add"   "plan"                 "$out"

# ==========================================================================================
echo
echo "case 4 — idle queue: no beads at all returns no UNCLAIMABLE lines (not a false alarm)"
# ==========================================================================================
# An empty queue and a blocked one both look like 'nothing ready' to CHECK 7. This check
# must be silent when the queue is genuinely empty.
testdb_reset

out="$(detect_unclaimable_ready 2>/dev/null)"
is "empty queue: no UNCLAIMABLE output" "" "$out"

# ==========================================================================================
echo
echo "case 5 — mixed queue: unclaimable bead flagged, claimable neighbour is not"
# ==========================================================================================
# The two beads sit in the same ready set. Only the unclaimable one may appear in output.
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-unc5a","title":"claimable: spira,plan","status":"open","issue_type":"task","labels":["plan","repo:spira","spira"]}
{"id":"sp-unc5b","title":"unclaimable: spira only","status":"open","issue_type":"task","labels":["repo:spira","spira"]}
JSONL

out="$(detect_unclaimable_ready 2>/dev/null)"
lacks "mixed queue: claimable bead not flagged"     "sp-unc5a" "$out"
has   "mixed queue: unclaimable bead is flagged"    "UNCLAIMABLE sp-unc5b" "$out"

# ==========================================================================================
echo
echo "case 6 — spira-poison and needs-ryan beads are excluded (have their own check)"
# ==========================================================================================
# detect_unclaimable_ready must not flag beads already handled by CHECK 4 (poison) or the
# ask taxonomy (needs-ryan). Both would otherwise produce noise on every pass.
testdb_reset
testdb_seed <<'JSONL'
{"id":"sp-unc6a","title":"poisoned: skipped","status":"open","issue_type":"task","labels":["spira-poison","repo:spira","spira"]}
{"id":"sp-unc6b","title":"needs-ryan: skipped","status":"open","issue_type":"task","labels":["needs-ryan","repo:spira","spira"]}
JSONL

out="$(detect_unclaimable_ready 2>/dev/null)"
lacks "poisoned bead not flagged by unclaimable check"   "sp-unc6a" "$out"
lacks "needs-ryan bead not flagged by unclaimable check" "sp-unc6b" "$out"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
