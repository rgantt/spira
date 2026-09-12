#!/usr/bin/env bash
#
# test-escalation-edges.sh — escalation asks create typed dependency edges to work beads
#
#   ./test-escalation-edges.sh
#
# WHAT THIS GUARDS. When sentinel.sh files an escalation via ask.sh with
# --ref "escalation:<kind>:<work_id>", ask.sh must write a `tracks` dependency edge
# from the ask bead to the work bead.  A typed edge is traversable with `bd graph`,
# `bd dep` and `bd blocked`.  An external_ref string is not.
#
# ACCEPTANCE CRITERIA (all sides paired — law-absence-needs-a-positive-control):
#   1. POSITIVE: ask with escalation ref → tracks edge exists from ask to work bead.
#   2. POSITIVE: bd dep list --direction up --type tracks shows ask bead.
#   3. NEGATIVE: no bead carries a label whose value starts with "thread:" or "escalation:".
#      (Relationships are edges; labels like "thread:sp-abc" are the anti-pattern.)
#   4. NON-ESCALATION ref: a plain --ref that is not "escalation:*:*" must NOT create
#      an unintended edge.
#   5. DEDUP PRESERVED: a second ask with the same ref deduplicates (recurs) rather
#      than creating a second edge.
#
# covers: cockpit/ask.sh
# hermetic-ok: uses a fixture database, no systemd or gh
# timeout: 120
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT="$(cd "$HERE/../cockpit" && pwd -P)"
. "$HERE/testdb.sh"
testdb_require test-escalation-edges
testdb_up escalation-edges || { echo "testdb_up failed"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
no()   { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did NOT want [$2] in [$3]"; }

trap 'testdb_drop' EXIT INT TERM

BD="${TESTDB_BD:-bd}"
bdt() { "$BD" -C "$SPIRA_DB" "$@"; }
ask() { COCKPIT_DB="$SPIRA_DB" bash "$COCKPIT/ask.sh" "$@"; }

# Scan all beads and return any whose LABELS array contains a value that
# starts with "thread:" or "escalation:".  Returns: one "label BEADID" per
# match, or nothing when clean.  The positive control below plants a bead
# with a synthetic label so a silent result is not an empty-set false pass.
labels_with_bad_prefix() {
    bdt list --all --limit 0 --json 2>/dev/null \
        | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = rows if isinstance(rows, list) else rows.get("issues", [])
for r in rows:
    for lbl in (r.get("labels") or []):
        if lbl.startswith("thread:") or lbl.startswith("escalation:"):
            print(lbl, r.get("id","?"))
'
}

echo "test-escalation-edges.sh"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "positive control — labels_with_bad_prefix detects a planted label"
# ─────────────────────────────────────────────────────────────────────────────
ctrl_bead="$(bdt create "ctrl-positive-control-label-detector" --type task \
    --labels "escalation:sp-ctrl-work" --silent 2>/dev/null)"
ctrl_out="$(labels_with_bad_prefix)"
want "planted escalation: label is detected" "escalation:sp-ctrl-work" "$ctrl_out" \
    || { printf '  FATAL: positive control failed — the check is broken\n'; exit 1; }

# Remove the planted label so it does not pollute later assertions.
bdt label remove "$ctrl_bead" "escalation:sp-ctrl-work" >/dev/null 2>&1 || true
post_ctrl="$(labels_with_bad_prefix)"
is "after removing the planted label the detector is quiet" "" "$post_ctrl"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "1. ask with escalation ref → tracks edge from ask to work bead"
# ─────────────────────────────────────────────────────────────────────────────
work_a="$(bdt create "work-bead-A-edge-test" --type task --labels "plan,spira" \
    --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("id",""))' 2>/dev/null)"
[ -n "$work_a" ] \
    && ok  "work bead A created: $work_a" \
    || { bad "work bead A created" "create returned empty id"; work_a="sp-fake-a"; }

ask_out="$(ask add "sp-mkn test: bead $work_a stuck" \
    --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" \
    --why "reclaim count hit threshold" 2>&1)"
ask_id="$(printf '%s' "$ask_out" | sed -n 's/^asked \[\([^]]*\)\].*/\1/p')"
want "ask was created"          "asked [" "$ask_out"
[ -n "$ask_id" ] \
    && ok "ask id extracted: $ask_id" \
    || bad "ask id extracted" "could not parse from: $ask_out"

# The tracks edge — from ask to work bead.  dep list --direction down from the ask
# shows what the ask DEPENDS ON, which is the work bead via tracks.
edges_down="$(bdt dep list "$ask_id" --direction down --type tracks --json 2>/dev/null \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
d = d if isinstance(d,list) else d.get("issues",[])
for r in d: print(r.get("id",""))
' 2>/dev/null)"
want "tracks edge down from ask → work bead" "$work_a" "$edges_down"

# The tracks edge — from the work bead's perspective (up direction).
edges_up="$(bdt dep list "$work_a" --direction up --type tracks --json 2>/dev/null \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
d = d if isinstance(d,list) else d.get("issues",[])
for r in d: print(r.get("id",""))
' 2>/dev/null)"
want "tracks edge up from work bead → ask bead" "$ask_id" "$edges_up"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "2. bd dep list shows the ask bead as a tracker of the work bead"
# ─────────────────────────────────────────────────────────────────────────────
trackers="$(bdt dep list "$work_a" --direction up --type tracks --json 2>/dev/null \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
d = d if isinstance(d,list) else d.get("issues",[])
print(len(d))
' 2>/dev/null || echo 0)"
is "exactly one tracker for work bead A" "1" "$trackers"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "3. no bead carries a thread: or escalation: label"
# ─────────────────────────────────────────────────────────────────────────────
bad_labels="$(labels_with_bad_prefix)"
is "no thread: or escalation: labels anywhere" "" "$bad_labels"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "4. plain --ref (not escalation:*:*) does NOT create an unintended tracks edge"
# ─────────────────────────────────────────────────────────────────────────────
work_b="$(bdt create "work-bead-B-plain-ref" --type task --labels "plan,spira" \
    --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("id",""))' 2>/dev/null)"
[ -n "$work_b" ] && ok "work bead B created: $work_b" || { bad "work bead B created" "create returned empty id"; work_b="sp-fake-b"; }

ask add "sp-mkn test: plain ref" \
    --ref "plain-key-not-escalation" \
    --default "do it" \
    --why "testing non-escalation ref" >/dev/null 2>&1 || true

# work_b should have zero tracks edges; we never filed an escalation for it.
edges_b="$(bdt dep list "$work_b" --direction up --type tracks --json 2>/dev/null \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
d = d if isinstance(d,list) else d.get("issues",[])
print(len(d))
' 2>/dev/null || echo 0)"
is "plain ref: no unintended tracks edge to work_b" "0" "$edges_b"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "5. dedup preserved: second ask with same ref recurs rather than creating a second edge"
# ─────────────────────────────────────────────────────────────────────────────
ask add "sp-mkn test: bead $work_a stuck again" \
    --ref "escalation:reclaim:$work_a" \
    --default "check cgroups" \
    --why "reclaim count hit threshold again" >/dev/null 2>&1 || true

trackers_after="$(bdt dep list "$work_a" --direction up --type tracks --json 2>/dev/null \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
d = d if isinstance(d,list) else d.get("issues",[])
print(len(d))
' 2>/dev/null || echo 0)"
is "still exactly one tracker after dedup recurrence" "1" "$trackers_after"

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
