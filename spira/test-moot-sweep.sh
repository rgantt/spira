#!/usr/bin/env bash
#
# test-moot-sweep.sh — asks with MOOT-WHEN are resolved when the predicate clears.
#
#   ./test-moot-sweep.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# Auto-filed alerts (watchtower alerts, incident beads) carry a machine-checkable condition
# as a MOOT-WHEN line in their description. When that condition clears, moot-sweep.sh
# resolves the ask without human involvement so it does not accumulate in the session-start
# queue. Three invariants are load-bearing and verified here:
#
#   1. ask.sh --moot-when stores the command as MOOT-WHEN: in the description.
#   2. A predicate exiting 0 → moot-sweep.sh resolves the ask.
#   3. A predicate exiting non-zero → ask stays open.
#   4. A predicate that errors → ask stays open (a failed probe must not read as cleared).
#   5. An ask without MOOT-WHEN is never touched.
#
# THE POSITIVE CONTROL IS FIRST. Before asserting that a cleared predicate causes resolution,
# the suite proves that the seam through which the predicate reaches the sweep actually works —
# that MOOT-WHEN: stored by ask.sh is parsed by moot-sweep.sh, and that the bead is STILL
# OPEN before the sweep. Without this, a bead that was already closed would produce the same
# "resolved" output and every assertion below would pass on fiction.
#
# SPIRA_ASK_LABEL IS PINNED TO A NON-DEFAULT so the reader cannot satisfy these assertions
# with a hardcoded literal (law-gates-run-in-a-clean-environment). The shipped default is
# "needs-operator"; pinning to "needs-attention" would fail a hardcoded "needs-operator"
# check in the parser. Both ask.sh (which writes the label) and moot-sweep.sh (which reads
# it) source conf.sh, which honours the exported value via its `:=` pattern, so the same
# label reaches both ends without duplication.
#
# defect: sp-cr96
# covers: cockpit/ask.sh cockpit/moot-sweep.sh spira/watchtower.sh spira/incident.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT="$(cd "$HERE/../cockpit" && pwd -P)"

# PIN BEFORE testdb_up SO conf.sh HONOURS IT. conf.sh uses `: "${SPIRA_ASK_LABEL:=...}"`,
# which preserves a value that is already in the environment. A value set after conf.sh has
# run has no effect on that run.
export SPIRA_ASK_LABEL=needs-attention
export SPIRA_CONF=/nonexistent   # use shipped defaults for everything else

. "$HERE/testdb.sh"
testdb_require test-moot-sweep
testdb_up mootsweep || { echo "testdb_up failed"; exit 1; }

pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

TMP="$(mktemp -d)"
# SELF_CLOSED GOES TO TMP, not to the real cockpit/.runtime. resolve.sh writes the id it
# closes to a file so watch-answers.sh can recognise its own closes. In a test that file
# must not land in the installed cockpit directory.
export SELF_CLOSED="$TMP/self-closed"
# COCKPIT_DB is the one database. cockpit_db() and cockpit_attention_beads() read it.
export COCKPIT_DB="$SPIRA_DB"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM

ASK="${SPIRA_ASK_LABEL}"   # the label both sides use — read AFTER conf.sh ran

# ask.sh expects bd in PATH; testdb_up already arranges this via TESTDB_BIN.
ask()   { bash "$COCKPIT/ask.sh"        "$@"; }
sweep() { bash "$COCKPIT/moot-sweep.sh" "$@"; }

# bd show returns a JSON ARRAY; read index 0.
bd_show_status() {  # bd_show_status <id> -> "open" or "closed"
    bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0].get("status","?") if isinstance(r,list) else r.get("status","?"))'
}
bd_show_desc() {    # bd_show_desc <id> -> description string
    bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0].get("description","") if isinstance(r,list) else r.get("description",""))'
}
bd_show_reason() {  # bd_show_reason <id> -> close_reason string
    bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0].get("close_reason","") if isinstance(r,list) else r.get("close_reason",""))'
}
# Seed one bead with the active ASK label. testdb_seed reads from stdin.
seed1() {   # seed1 <id> <desc-json-string>
    printf '{"id":"%s","title":"t %s","description":"%s","status":"open","issue_type":"decision","labels":["%s","overseer","ask-question"]}\n' \
        "$1" "$1" "$2" "$ASK" | testdb_seed
}

echo "test-moot-sweep.sh"

# ======================================================================================
echo
echo "ask.sh --moot-when stores MOOT-WHEN: in the description:"
# ======================================================================================
# THE POSITIVE CONTROL FOR THE SEAM: if ask.sh does not write the line, moot-sweep.sh
# will never see it, and every assertion about clearing would be testing nothing.
out=$(ask add "will this land?" --default "yes" --why "blocked on landing" \
      --moot-when "exit 0" 2>&1)
moot_id=$(printf '%s' "$out" | grep -oE '\[([a-z]{2}-[a-z0-9]+)\]' | tr -d '[]' | head -1)
[ -n "$moot_id" ] && ok "bead created" || { bad "bead created" "no id in: $out"; }
if [ -n "$moot_id" ]; then
    desc=$(bd_show_desc "$moot_id")
    want "MOOT-WHEN line is in the description"            "MOOT-WHEN: exit 0"    "$desc"
    want "existing fields survive alongside MOOT-WHEN"     "What is blocked"      "$desc"
    want "and the escalation label is set"                 "$ASK"                 \
         "$(bd -C "$SPIRA_DB" show "$moot_id" --json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin); d=r[0] if isinstance(r,list) else r; print(",".join(d.get("labels",[])))')"
fi

# An insight must NOT carry MOOT-WHEN even if the caller passes the flag. An insight is
# a record, not an ask — it has no clearing condition and should never be auto-resolved.
out2=$(ask insight "something learned" --why "matters" --moot-when "exit 0" 2>&1)
insight_id=$(printf '%s' "$out2" | grep -oE '\[([a-z]{2}-[a-z0-9]+)\]' | tr -d '[]' | head -1)
if [ -n "$insight_id" ]; then
    desc2=$(bd_show_desc "$insight_id")
    nowant "insight description does not carry MOOT-WHEN" "MOOT-WHEN:" "$desc2"
fi

# ======================================================================================
echo
echo "a cleared predicate (exit 0) causes moot-sweep.sh to resolve the ask:"
# ======================================================================================
# THE SEAM: moot-sweep.sh must (a) parse the MOOT-WHEN line, (b) run the command,
# (c) resolve via resolve.sh when it exits 0. All three are tested through the real binaries
# so no gap can hide between layers.
testdb_reset  # fresh database — the beads from the previous section are gone

seed1 "sp-clear1" "nothing landing\\n\\nMOOT-WHEN: exit 0"

is "bead is open before sweep" "open" "$(bd_show_status sp-clear1)"

out=$(sweep --apply 2>&1)
want "CLEARED is reported"   "CLEARED"    "$out"
want "and names the bead"    "sp-clear1"  "$out"
want "and says resolved"     "resolved"   "$out"
is "bead is closed after sweep" "closed" "$(bd_show_status sp-clear1)"

# The reason on the closed bead names the predicate.
reason=$(bd_show_reason "sp-clear1")
want "close reason names the predicate"  "MOOT-WHEN predicate cleared"  "$reason"
want "and quotes what the command was"   "exit 0"                        "$reason"

# ======================================================================================
echo
echo "a predicate exiting non-zero leaves the ask open:"
# ======================================================================================
testdb_reset

seed1 "sp-live1" "queue paused\\n\\nMOOT-WHEN: exit 1"

sweep --apply >/dev/null 2>&1
is "a non-zero predicate leaves the ask open" "open" "$(bd_show_status sp-live1)"

out=$(sweep 2>&1)
want "non-zero is reported as 'still live'"  "still live"  "$out"
want "and names the bead"                    "sp-live1"    "$out"

# ======================================================================================
echo
echo "a predicate that errors leaves the ask open:"
# ======================================================================================
testdb_reset

# A command that does not exist errors (exit 127). Must NOT read as "cleared".
seed1 "sp-err1" "cmd gone?\\n\\nMOOT-WHEN: nonexistent-command-xyzzy 2>&1"

sweep --apply >/dev/null 2>&1
is "an erroring predicate leaves the ask open" "open" "$(bd_show_status sp-err1)"

# ======================================================================================
echo
echo "asks without MOOT-WHEN are never touched:"
# ======================================================================================
testdb_reset

seed1 "sp-nopred" "no predicate here"

sweep --apply >/dev/null 2>&1
is "an ask without MOOT-WHEN stays open" "open" "$(bd_show_status sp-nopred)"

# The count line must say 0 predicates found.
out=$(sweep 2>&1)
want "summary shows zero predicates"   "0 ask(s) carry a predicate"  "$out"

# ======================================================================================
echo
echo "already-closed asks are not re-resolved:"
# ======================================================================================
testdb_reset

# Seed a closed bead (closed at import time via a non-open status field).
printf '{"id":"sp-already","title":"t sp-already","description":"MOOT-WHEN: exit 0","status":"closed","issue_type":"decision","labels":["%s","overseer","ask-question"]}\n' \
    "$ASK" | testdb_seed

out=$(sweep 2>&1)
# A closed bead is excluded by the open-status filter in the parser.
nowant "a closed ask is not re-reported" "sp-already" "$out"
want   "and counts as 0 predicates found" "0 ask(s)" "$out"

# ======================================================================================
echo
echo "without --apply the sweep reports but does not resolve:"
# ======================================================================================
testdb_reset

seed1 "sp-dryrun" "dry run test\\n\\nMOOT-WHEN: exit 0"

out=$(sweep 2>&1)    # no --apply
want  "CLEARED is reported"          "CLEARED"    "$out"
want  "and names the bead"           "sp-dryrun"  "$out"
nowant "but the 'resolved' confirmation is absent" "    resolved" "$out"
is "bead stays open without --apply" "open" "$(bd_show_status sp-dryrun)"

# ======================================================================================
echo
echo "watchtower calls moot-sweep on a running world:"
# ======================================================================================
# The contract: the moot sweep runs whenever watchtower fires on a running world. Verified
# by injecting a mock MOOT_SH and checking it was called. The mock writes a sentinel file
# when invoked, so the test does not need a real db or a real sweep.
testdb_reset
mkdir -p "$TMP/run/landstate"
mock_moot="$TMP/mock-moot.sh"
printf '#!/usr/bin/env bash\nprintf called > "%s/moot-called"\n' "$TMP" > "$mock_moot"
chmod +x "$mock_moot"
mock_inc="$TMP/mock-inc.sh"
printf '#!/usr/bin/env bash\ncat > /dev/null\n' > "$mock_inc"
chmod +x "$mock_inc"
rm -f "$TMP/moot-called"
env -i PATH="$PATH" HOME="$TMP" \
    SPIRA_CONF=/nonexistent SPIRA_RUN="$TMP/run" \
    SPIRA_WATCH_GATE_WINDOW=3600 \
    SPIRA_INCIDENT_SH="$mock_inc" \
    SPIRA_MOOT_SH="$mock_moot" \
    bash "$HERE/watchtower.sh" >/dev/null 2>&1
is "watchtower calls the moot sweep on a running world" "called" \
   "$(cat "$TMP/moot-called" 2>/dev/null || echo "")"

# A HALTED WORLD MUST NOT CALL THE MOOT SWEEP. The halt guard exits before the sweep, so
# this is structural rather than explicit — but it is worth asserting because the halt's
# contract is "file nothing; change nothing".
printf '2026-09-08T01:23:45Z\nwhy: testing\n' > "$TMP/run/world.halted"
rm -f "$TMP/moot-called"
env -i PATH="$PATH" HOME="$TMP" \
    SPIRA_CONF=/nonexistent SPIRA_RUN="$TMP/run" \
    SPIRA_WATCH_GATE_WINDOW=3600 \
    SPIRA_INCIDENT_SH="$mock_inc" \
    SPIRA_MOOT_SH="$mock_moot" \
    bash "$HERE/watchtower.sh" >/dev/null 2>&1
is "a halted world does not call the moot sweep" "" \
   "$(cat "$TMP/moot-called" 2>/dev/null || echo "")"

# ======================================================================================
echo
echo "incident.sh undeclared-repo predicate: clears when incident bead gets repo: label:"
# ======================================================================================
# Verifies the MOOT-WHEN predicate that incident.sh writes when filing an undeclared-repo
# ask. Three properties are load-bearing:
#   1. The predicate exits non-zero while the incident bead carries no repo: label.
#   2. The predicate exits 0 once a repo: label is added.
#   3. The predicate exits non-zero when bd show returns nothing (bead missing or DB
#      unreachable), leaving the ask open rather than silently clearing it.
#
# The predicate is constructed with a heredoc, exactly as incident.sh does, so the same
# quoting behaviour is under test. $INC_ID expands now (the specific bead to watch);
# $COCKPIT_DB remains a variable reference that expands at sweep time.
testdb_reset

INC_ID="sp-tinc1"
printf '{"id":"%s","title":"test incident","status":"open","issue_type":"bug","labels":["spira","incident"]}\n' \
    "$INC_ID" | testdb_seed

inc_pred=$(cat <<PREDEOF
_d=\$(bd -C "\$COCKPIT_DB" show $INC_ID --json 2>/dev/null); [ -n "\$_d" ] || { echo 'probe: no output from bd show — database may be unreachable'; exit 1; }; printf '%s\n' "\$_d" | python3 -c 'import json,sys; t=sys.stdin.read().strip(); d=(json.loads(t) if t else []); r=(d[0] if isinstance(d,list) and d else (d if isinstance(d,dict) and d else None)); valid=r is not None and "id" in r; s=r.get("status","?") if valid else "?"; ll=(r.get("labels") or []) if valid else []; rp=[x for x in ll if x.startswith("repo:")]; ok=valid and (s!="open" or bool(rp)); msg=("cleared: "+(rp[0] if rp else "bead "+s)) if ok else ("live: status="+s+", no repo: label") if valid else "probe failed: bd show returned error or no valid bead"; print(msg); sys.exit(0 if ok else 1)'
PREDEOF
)

# File the ask via ask.sh so the predicate is stored and parsed exactly as it would be
# in production (ask.sh handles JSON encoding; a manual seed cannot do this safely).
ask_out=$(ask add "undeclared repo for $INC_ID" \
    --default "add repo:<name> to $INC_ID" \
    --why "no repo: label on $INC_ID" \
    --moot-when "$inc_pred" 2>&1)
inc_ask_id=$(printf '%s' "$ask_out" | grep -oE '\[([a-z]{2}-[a-z0-9]+)\]' | tr -d '[]' | head -1)
[ -n "$inc_ask_id" ] && ok "ask filed with predicate" || { bad "ask filed with predicate" "no id in: $ask_out"; }

if [ -n "$inc_ask_id" ]; then
    desc=$(bd_show_desc "$inc_ask_id")
    want "description carries MOOT-WHEN" "MOOT-WHEN:" "$desc"
    want "predicate names the incident bead id" "$INC_ID" "$desc"

    # No repo: label yet — predicate must not clear.
    out=$(sweep 2>&1)
    nowant "predicate does not clear before repo: label is added" "CLEARED" "$out"
    is "ask stays open before repo: label" "open" "$(bd_show_status "$inc_ask_id")"

    # Add repo: label to the incident bead — predicate must now clear.
    bd -C "$SPIRA_DB" set-state "$INC_ID" "repo=spira" >/dev/null 2>&1
    out=$(sweep 2>&1)
    want "CLEARED after repo: label added"  "CLEARED"    "$out"
    want "and names the ask bead"           "$inc_ask_id" "$out"

    # With --apply, the ask is resolved.
    sweep --apply >/dev/null 2>&1
    is "ask is closed after --apply" "closed" "$(bd_show_status "$inc_ask_id")"
fi

# CLOSED INCIDENT BEAD also clears the ask (the second clearing condition).
testdb_reset
INC_ID2="sp-tinc2"
printf '{"id":"%s","title":"test incident 2","status":"open","issue_type":"bug","labels":["spira","incident"]}\n' \
    "$INC_ID2" | testdb_seed

inc_pred2=$(cat <<PREDEOF
_d=\$(bd -C "\$COCKPIT_DB" show $INC_ID2 --json 2>/dev/null); [ -n "\$_d" ] || { echo 'probe: no output from bd show — database may be unreachable'; exit 1; }; printf '%s\n' "\$_d" | python3 -c 'import json,sys; t=sys.stdin.read().strip(); d=(json.loads(t) if t else []); r=(d[0] if isinstance(d,list) and d else (d if isinstance(d,dict) and d else None)); valid=r is not None and "id" in r; s=r.get("status","?") if valid else "?"; ll=(r.get("labels") or []) if valid else []; rp=[x for x in ll if x.startswith("repo:")]; ok=valid and (s!="open" or bool(rp)); msg=("cleared: "+(rp[0] if rp else "bead "+s)) if ok else ("live: status="+s+", no repo: label") if valid else "probe failed: bd show returned error or no valid bead"; print(msg); sys.exit(0 if ok else 1)'
PREDEOF
)
ask_out2=$(ask add "undeclared repo for $INC_ID2" \
    --default "add repo:<name> to $INC_ID2" \
    --why "no repo: label on $INC_ID2" \
    --moot-when "$inc_pred2" 2>&1)
inc_ask_id2=$(printf '%s' "$ask_out2" | grep -oE '\[([a-z]{2}-[a-z0-9]+)\]' | tr -d '[]' | head -1)
if [ -n "$inc_ask_id2" ]; then
    bd -C "$SPIRA_DB" close "$INC_ID2" --reason "resolved" >/dev/null 2>&1
    out=$(sweep 2>&1)
    want "CLEARED when incident bead is closed" "CLEARED" "$out"
fi

# MISSING/UNREACHABLE BEAD: bd show returns nothing — predicate must exit non-zero.
# A bead id that does not exist in the test db causes bd show to return [] or nothing.
# The predicate must not read this as "condition cleared" — the ask stays open.
testdb_reset
MISSING_ID="sp-doesnotexistXXX"
missing_pred=$(cat <<PREDEOF
_d=\$(bd -C "\$COCKPIT_DB" show $MISSING_ID --json 2>/dev/null); [ -n "\$_d" ] || { echo 'probe: no output from bd show — database may be unreachable'; exit 1; }; printf '%s\n' "\$_d" | python3 -c 'import json,sys; t=sys.stdin.read().strip(); d=(json.loads(t) if t else []); r=(d[0] if isinstance(d,list) and d else (d if isinstance(d,dict) and d else None)); valid=r is not None and "id" in r; s=r.get("status","?") if valid else "?"; ll=(r.get("labels") or []) if valid else []; rp=[x for x in ll if x.startswith("repo:")]; ok=valid and (s!="open" or bool(rp)); msg=("cleared: "+(rp[0] if rp else "bead "+s)) if ok else ("live: status="+s+", no repo: label") if valid else "probe failed: bd show returned error or no valid bead"; print(msg); sys.exit(0 if ok else 1)'
PREDEOF
)
ask_out3=$(ask add "undeclared repo for missing incident" \
    --default "add repo:<name>" \
    --why "no repo: label" \
    --moot-when "$missing_pred" 2>&1)
inc_ask_id3=$(printf '%s' "$ask_out3" | grep -oE '\[([a-z]{2}-[a-z0-9]+)\]' | tr -d '[]' | head -1)
if [ -n "$inc_ask_id3" ]; then
    sweep --apply >/dev/null 2>&1
    is "ask stays open when bd show returns nothing for the incident bead" "open" \
       "$(bd_show_status "$inc_ask_id3")"
fi

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
