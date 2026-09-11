#!/usr/bin/env bash
#
# test-ask-dedupe.sh — ask.sh add --ref deduplicates repeated escalations
#
#   ./test-ask-dedupe.sh
#
# WHAT THIS GUARDS. cockpit/ask.sh add --ref <key> must bump a recurrence count on an
# existing open bead rather than creating a duplicate when the same key is presented again.
# Without this, every hourly pass that finds the same condition files a fresh bead, drowning
# the operator's queue in duplicates (sp-oyyx7: 441 escalations, 26 for one skew condition).
#
# ACCEPTANCE CRITERIA FROM THE BEAD
#   1. Two add calls with the same --ref produce ONE bead with a recurrence label.
#   2. Two add calls with DIFFERENT refs produce TWO beads (positive control against a
#      drop-every-second implementation).
#   3. A condition that clears (ask closed) and returns files a NEW ask.
#   4. skew.sh's DIRTY and BEHIND conditions produce distinct refs that don't collapse.
#
# covers: cockpit/ask.sh spira/skew.sh spira/strand.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT="$(cd "$HERE/../cockpit" && pwd -P)"
. "$HERE/testdb.sh"
testdb_require test-ask-dedupe
testdb_up ask-dedupe || { echo "testdb_up failed"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
no()   { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did NOT want [$2] in [$3]"; }

TMP="$(mktemp -d)"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

export COCKPIT_DB="$SPIRA_DB"
BD="${TESTDB_BD:-bd}"

bdt() { "$BD" -C "$SPIRA_DB" "$@"; }
ask() { COCKPIT_DB="$SPIRA_DB" bash "$COCKPIT/ask.sh" "$@"; }

count_beads() {
    "$BD" -C "$SPIRA_DB" list --all --limit 0 --json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d if isinstance(d,list) else d.get("issues",[])))' 2>/dev/null || echo 0
}

count_open_asks() {
    "$BD" -C "$SPIRA_DB" list --status open --limit 0 --json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d if isinstance(d,list) else d.get("issues",[])))' 2>/dev/null || echo 0
}

get_labels() {  # get_labels <id>
    "$BD" -C "$SPIRA_DB" show "$1" --json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(" ".join(d.get("labels") or []))' 2>/dev/null || echo ""
}

echo "test-ask-dedupe.sh"

# ======================================================================================
echo
echo "positive control — count_beads can detect a creation"
# ======================================================================================
before="$(count_beads)"
ask add "positive-control-ask" --default "do it" >/dev/null 2>&1 || true
after="$(count_beads)"
[ "$after" -gt "$before" ] \
    && ok "count_beads moves on creation (positive control)" \
    || bad "count_beads moves on creation (positive control)" "before=$before after=$after"

testdb_reset

# ======================================================================================
echo
echo "1. same --ref: two calls produce one bead with recurrence label"
# ======================================================================================
before="$(count_beads)"
out1="$(ask add "the harness is behind" --default "pull and install" --ref "skew:v2:BEHIND=1 DIRTY=0" 2>&1)"
out2="$(ask add "the harness is behind" --default "pull and install" --ref "skew:v2:BEHIND=1 DIRTY=0" 2>&1)"
after="$(count_beads)"

# Should have created exactly one new bead
is "same ref: one bead created (not two)" "$((before+1))" "$after"

# The first call must say "asked"
want "first call says 'asked'" "asked" "$out1"

# The second call must say "recurred"
want "second call says 'recurred'" "recurred" "$out2"

# Extract the bead id from the first call
id1="$(printf '%s' "$out1" | grep -oE '\[[a-z]+-[a-z0-9]+\]' | tr -d '[]' | head -1)"
if [ -n "$id1" ]; then
    labels="$(get_labels "$id1")"
    want "recurrence label sp-recur-1 added" "sp-recur-1" "$labels"
    ok  "bead id extracted: $id1"
else
    bad "bead id extracted" "could not parse id from: $out1"
    bad "recurrence label sp-recur-1 added" "no bead id to check"
fi

testdb_reset

# ======================================================================================
echo
echo "2. different refs: two calls produce two beads (positive control)"
# ======================================================================================
before="$(count_beads)"
ask add "the harness is behind" --default "pull and install" --ref "skew:v2:BEHIND=1 DIRTY=0" >/dev/null 2>&1
ask add "the harness is dirty"  --default "commit or stash"  --ref "skew:v2:BEHIND=0 DIRTY=1" >/dev/null 2>&1
after="$(count_beads)"

is "different refs: two beads created" "$((before+2))" "$after"

testdb_reset

# ======================================================================================
echo
echo "3. condition clears (ask closed) and returns: fresh ask filed"
# ======================================================================================
before="$(count_beads)"
out_first="$(ask add "the harness is behind" --default "pull and install" --ref "skew:v2:BEHIND=1 DIRTY=0" 2>&1)"
id_first="$(printf '%s' "$out_first" | grep -oE '\[[a-z]+-[a-z0-9]+\]' | tr -d '[]' | head -1)"

if [ -z "$id_first" ]; then
    bad "clear-and-return: first ask created" "could not parse id from: $out_first"
    bad "clear-and-return: closing first ask" "no id"
    bad "clear-and-return: second ask creates a new bead" "no id"
    bad "clear-and-return: second ask says 'asked' not 'recurred'" "no id"
else
    ok  "clear-and-return: first ask created ($id_first)"

    # Close the first ask (simulate the operator answering it)
    bdt close "$id_first" --reason "fixed: pulled" --force >/dev/null 2>&1 \
        && ok  "clear-and-return: first ask closed" \
        || bad "clear-and-return: first ask closed" "bd close failed"

    # The same condition returns: should file a NEW ask, not bump the closed one
    out_second="$(ask add "the harness is behind" --default "pull and install" --ref "skew:v2:BEHIND=1 DIRTY=0" 2>&1)"
    after="$(count_beads)"

    is "clear-and-return: second ask creates a new bead" "$((before+2))" "$after"
    want "clear-and-return: second ask says 'asked' not 'recurred'" "asked" "$out_second"
fi

testdb_reset

# ======================================================================================
echo
echo "4. skew DIRTY and BEHIND refs are distinct — don't collapse"
# ======================================================================================
# File a BEHIND ask, then file a DIRTY ask. Both should produce separate open beads.
out_behind="$(ask add "the harness is behind" --default "pull and install" --ref "skew:v2:BEHIND=1 DIRTY=0 COPY=0 STALE=0" 2>&1)"
out_dirty="$(ask add "dirty tracked files"    --default "commit or stash"  --ref "skew:v2:BEHIND=0 DIRTY=1 COPY=0 STALE=0" 2>&1)"

id_behind="$(printf '%s' "$out_behind" | grep -oE '\[[a-z]+-[a-z0-9]+\]' | tr -d '[]' | head -1)"
id_dirty="$(printf '%s'  "$out_dirty"  | grep -oE '\[[a-z]+-[a-z0-9]+\]' | tr -d '[]' | head -1)"

[ -n "$id_behind" ] && [ -n "$id_dirty" ] \
    && ok  "skew refs: both beads created" \
    || bad "skew refs: both beads created" "behind=$id_behind dirty=$id_dirty"

[ -n "$id_behind" ] && [ -n "$id_dirty" ] && [ "$id_behind" != "$id_dirty" ] \
    && ok  "skew refs: BEHIND and DIRTY are different beads" \
    || bad "skew refs: BEHIND and DIRTY are different beads" "behind=$id_behind dirty=$id_dirty"

# Now calling BEHIND again must recur on the BEHIND bead, not the DIRTY one
out_behind2="$(ask add "the harness is behind" --default "pull and install" --ref "skew:v2:BEHIND=1 DIRTY=0 COPY=0 STALE=0" 2>&1)"
want "BEHIND second call recurrs on BEHIND bead" "recurred" "$out_behind2"
[ -n "$id_behind" ] && want "BEHIND second call names BEHIND id" "[$id_behind]" "$out_behind2" || true
[ -n "$id_dirty" ]  && no   "BEHIND second call does NOT name DIRTY id" "[$id_dirty]" "$out_behind2" || true

testdb_reset

# ======================================================================================
echo
echo "5. add without --ref: unaffected — no ref means no dedupe"
# ======================================================================================
before="$(count_beads)"
ask add "unreffed ask one" --default "do x" >/dev/null 2>&1
ask add "unreffed ask one" --default "do x" >/dev/null 2>&1
after="$(count_beads)"
# Without --ref, identical titles DO create two beads (dedupe is opt-in)
is "no --ref: two calls create two beads" "$((before+2))" "$after"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
