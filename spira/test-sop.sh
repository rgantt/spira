#!/usr/bin/env bash
#
# test-sop.sh — the Ops persona's two programs, against a real bd on a throwaway database.
#
#   ./test-sop.sh
#
# WHY A FIXTURE DATABASE HERE AND A REAL REPO IN test-sending.sh
# --------------------------------------------------------------
# Every claim sending.sh makes is a claim about git's behaviour, so mocking git would have
# asserted only that the mock agrees with the author. The same argument applies to beads,
# and it is why this suite runs the REAL binary against a database created for the run and
# dropped by a trap: these programs decide whether an event becomes a new bead or a
# recurrence on an existing one, whether a malformed runbook is stored, and whether a
# payload survives an unreachable database — and each of those is a claim about what `bd`
# does, not about what a model of it does (law-prefer-the-real-dependency).
#
# What the fixture buys over the live database is the same thing a stub bought: filing here
# files no real incident and labels no real bead, and the case that matters most — the
# database being DOWN — is arranged by pointing a workspace at a dead port, which the real
# binary reports as "Dolt server unreachable" exactly as it would in production.
#
# The negatives carry the weight, as they do in the reaper. A dedupe that files a second
# bead is a queue nobody reads; a spool that drops an event loses the only record of a
# production failure, because an alert arrives once and cannot be asked for again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
rcis()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted rc=$2 got rc=$3"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-sop
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up sop || { echo "test-sop: could not build a fixture database"; exit 1; }

# The real binary against the fixture. SPIRA_BD stays unset, so lib.sh resolves plain `bd`.
B() { bd -C "$SPIRA_DB" "$@"; }
beadcount() { B list --limit 0 --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
memcount()  { B memories --json 2>/dev/null | python3 -c 'import json,sys; print(len([k for k,v in json.load(sys.stdin).items() if isinstance(v,str)]))'; }
bodyof()    { B show "$1" --json 2>/dev/null | python3 -c '
import json,sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(d[0].get("description") or "")'; }

export SPIRA_RUN="$TMP/run"
export SPIRA_SPOOL="$TMP/spool"
export SPIRA_INCIDENT_LOG="$TMP/incident.log"
export SOP_PAGE="$TMP/sops.md"
export SPIRA_ASK="$TMP/ask.sh"
printf '#!/bin/sh\necho "$@" >> %s/asks.txt\n' "$TMP" > "$SPIRA_ASK"; chmod +x "$SPIRA_ASK"

sop()      { "$HERE/sop.sh" "$@" 2>&1; }
incident() { "$HERE/incident.sh" "$@" 2>&1; }
# THE ID IS THE LAST LINE, never the whole of stdout. `ilog` tees to stdout on purpose so
# the operator's journal carries the filing, so `incident.sh file` emits a log line and then
# the bead id. A caller that captures the lot gets a two-line blob, and a substring
# assertion against a hardcoded id will not notice — which is how this suite passed while
# asserting on output it was not actually reading.
incident_id() { incident "$@" | tail -1; }

GOOD='MATCH: mtgc-diskcheck-prod\.service.*(FAILED|Result=exit-code)
SYMPTOM: the prod disk check failed because / crossed its floor
CHECK: df -h / | tail -1
FIX: find the largest scratch directory and remove it, then systemctl --user start mtgc-diskcheck-prod.service
ESCALATE: if the space is production data rather than scratch
REF: wiki/notes/tmp-own-volume-sop-2026-08-11.md'

# ======================================================================================
echo "sop.sh — the shape is enforced:"
# ======================================================================================
out="$(printf 'SYMPTOM: a thing\nCHECK: a command\n' | sop write shapeless -)"
want "write refuses an SOP with no FIX" "missing required field(s): FIX" "$out"
out="$(printf 'a paragraph about a disk that filled up once\n' | sop write prosey -)"
want "write refuses prose outright" "SYMPTOM CHECK FIX" "$out"

out="$(printf 'MATCH: [unclosed\nSYMPTOM: s\nCHECK: c\nFIX: f\n' | sop write badre -)"
want "write refuses a MATCH that will not compile" "not a valid extended regex" "$out"

out="$(SOP_WORD_CAP=10 sop write toolong - <<< "$GOOD")"
want "write refuses an SOP over the word cap" "cap is 10" "$out"

n="$(memcount)"
[ "${n:-0}" = 0 ] && ok "nothing malformed was stored" || bad "nothing malformed was stored" "$n memories exist"

# ======================================================================================
echo
echo "sop.sh — a good SOP round-trips:"
# ======================================================================================
out="$(sop write diskcheck - <<< "$GOOD")"
want "write accepts it"        "wrote sop-diskcheck" "$out"
want "write echoes the regex"  "matches: mtgc-diskcheck" "$out"
want "write regenerates the page" "sop-synth: wrote" "$out"
want "show returns the text"   "CHECK: df -h" "$(sop show diskcheck)"
want "list names it"           "sop-diskcheck" "$(sop list)"
want "list shows the symptom"  "prod disk check failed" "$(sop list)"

# ======================================================================================
echo
echo "sop.sh match — the deterministic tier:"
# ======================================================================================
cat > "$TMP/payload-hit" <<'P'
unit: mtgc-diskcheck-prod.service
Result=exit-code
Sep 05 03:14:02 gitea mtgc-diskcheck-prod.service: FAILED / at 97%
P
cat > "$TMP/payload-miss" <<'P'
unit: mtgc-catalog-refresh-prod.service
Result=timeout
Sep 05 03:14:02 gitea scryfall bulk download timed out
P
want   "match fires on the right payload"  "sop-diskcheck" "$(sop match "$TMP/payload-hit")"
want   "match says how it matched"         "MATCH" "$(sop match "$TMP/payload-hit")"
nowant "match is silent on an unrelated payload" "sop-diskcheck" "$(sop match "$TMP/payload-miss")"

# An SOP with no MATCH: line is findable but weakly, by the words in its own key. This is
# deliberately poor — it is the nudge that gets a MATCH written.
printf 'SYMPTOM: scryfall bulk download timed out\nCHECK: c\nFIX: f\n' \
    | sop write scryfall-timeout - >/dev/null
want "key-token fallback finds it" "sop-scryfall-timeout" "$(sop match "$TMP/payload-miss")"
want "and says the match was weak" "key-tokens" "$(sop match "$TMP/payload-miss")"

# ======================================================================================
echo
echo "sop.sh synth — regenerated whole, never patched:"
# ======================================================================================
want "the page carries both SOPs" "sop-scryfall-timeout" "$(cat "$SOP_PAGE")"
want "and the closing rule"       "must produce one" "$(cat "$SOP_PAGE")"
echo "A HAND EDIT THAT MUST NOT SURVIVE" >> "$SOP_PAGE"
sop synth >/dev/null
nowant "a hand edit is discarded on the next run" "MUST NOT SURVIVE" "$(cat "$SOP_PAGE")"
sop retire scryfall-timeout >/dev/null
nowant "a retired SOP leaves the page"   "sop-scryfall-timeout" "$(cat "$SOP_PAGE")"
nowant "and leaves the shelf"            "sop-scryfall-timeout" "$(sop list)"

# ======================================================================================
echo
echo "incident.sh — one incident, however many alerts:"
# ======================================================================================
first="$(incident_id file "prod diskcheck failed" "$TMP/payload-hit")"
# The id is whatever bd minted, not a literal: a fixture that hardcodes an id is asserting
# the id ALLOCATOR, which is beads' business, and it breaks the moment a test above it files
# one more bead.
[[ "$first" =~ ^sp-[a-z0-9]+$ ]] && ok "the first event files a bead" \
                                 || bad "the first event files a bead" "got [$first]"
# THE PAYLOAD, not just the bead. A spool round-trip that loses the body files an incident
# with nothing in it, which reads as a filed event right up to the moment Ops opens it —
# and that is exactly what a one-character slip in spool_body did on the first real run.
body="$(bodyof "$first")"
want "with the payload intact through the spool" "Result=exit-code" "$body"
want "and the unit that failed"                  "mtgc-diskcheck-prod.service" "$body"
second="$(incident_id file "prod diskcheck failed" "$TMP/payload-hit")"
want "the second event is the SAME bead" "$first" "$second"
want "and is counted as a recurrence" "sp-recur-2" "$(B label list "$first")"
n="$(beadcount)"
[ "$n" = 1 ] && ok "a flapping unit never files a second bead" \
             || bad "a flapping unit never files a second bead" "$n beads exist"

for _ in 1 2 3; do incident file "prod diskcheck failed" "$TMP/payload-hit" >/dev/null; done
want "past the threshold it becomes a Sin" "sin" "$(B label list "$first")"
want "and the operator is asked, with a default"   "--default" "$(cat "$TMP/asks.txt" 2>/dev/null)"
before="$(wc -l < "$TMP/asks.txt")"
incident file "prod diskcheck failed" "$TMP/payload-hit" >/dev/null
after="$(wc -l < "$TMP/asks.txt")"
[ "$before" = "$after" ] && ok "a Sin is escalated once, never again" \
                         || bad "a Sin is escalated once, never again" "$before -> $after asks"

# ======================================================================================
echo
echo "incident.sh — the write-ahead spool:"
# ======================================================================================
# A GENUINELY UNREACHABLE DATABASE, not a flag a fake honours. testdb_unreachable copies
# the fixture workspace and points it at a port nothing listens on, so the real bd fails the
# way it fails in production — "Dolt server unreachable" — which is the one condition the
# real thing cannot be asked for on demand.
DOWN="$(testdb_unreachable)"
SPIRA_DB="$DOWN" incident file "the catalog refresh died" "$TMP/payload-miss" >/dev/null 2>&1; rc=$?
rcis "a filing that cannot reach the database fails loudly" 1 "$rc"
spooled="$(find "$SPIRA_SPOOL" -maxdepth 1 -type f ! -name '*.bad' | wc -l)"
[ "$spooled" = 1 ] && ok "the payload is still on disk" \
                   || bad "the payload is still on disk" "$spooled spool entries"
want "and list says so" "still in the spool" "$(incident list)"

rm -rf "$DOWN"
out="$(incident drain)"
want "drain files it once the database is back" "drained 1" "$out"
want "and reports the ones it could not"        "still spooled 0" "$out"
spooled="$(find "$SPIRA_SPOOL" -maxdepth 1 -type f ! -name '*.bad' 2>/dev/null | wc -l)"
[ "$spooled" = 0 ] && ok "a drained entry leaves the spool" \
                   || bad "a drained entry leaves the spool" "$spooled remain"
n="$(beadcount)"
[ "$n" = 2 ] && ok "the event survived the outage as its own bead" \
             || bad "the event survived the outage as its own bead" "$n beads"

# An empty payload must still file, and must SAY it is empty. bd create refuses an empty
# --body-file, so without this the event would sit in the spool forever looking like an
# unreachable database.
: > "$TMP/empty"
empty_id="$(incident_id file "a probe that gathered nothing" "$TMP/empty")"
want "an empty payload is filed as an empty payload" "gathered NO payload" "$(bodyof "$empty_id")"

# A spool entry with no REF cannot be filed and must not be retried forever.
printf 'garbage\n' > "$SPIRA_SPOOL/malformed"
out="$(incident drain)"
want "a malformed entry is moved aside, not retried" "still spooled 0" "$out"
[ -f "$SPIRA_SPOOL/malformed.bad" ] && ok "and is kept for inspection" \
                                    || bad "and is kept for inspection" "no .bad file"

# ======================================================================================
echo
echo "render_memories — the two books stay apart:"
# ======================================================================================
. "$HERE/lib.sh"
B remember --key law-test-statute "A statute long enough that the listing form of bd memories would truncate it well before this final clause, which is the whole reason this function exists at all." >/dev/null
laws="$(render_memories "law-")"
sops="$(render_memories "sop-")"
both="$(render_memories "law-,sop-")"
want   "a builder reading law- gets the law"        "law-test-statute" "$laws"
nowant "and does not pay for the runbooks"          "sop-diskcheck"    "$laws"
want   "Ops reading sop- gets the runbooks"         "sop-diskcheck"    "$sops"
want   "Ops reading both gets both"                 "law-test-statute" "$both"
want   "..."                                        "sop-diskcheck"    "$both"
want   "and a statute is delivered WHOLE, not truncated at the listing width" \
       "this function exists at all." "$laws"
nowant "no ellipsis from the listing form leaks through" "at all...." "$laws"
budgeted="$(render_memories "law-,sop-" 80)"
want "an exceeded budget SAYS which memories it dropped" "memories omitted for budget" "$budgeted"

# ======================================================================================
echo
echo "install-intake.sh — the wiring:"
# ======================================================================================
# SPIRA_HOME defaults to the installed copy of the harness, which is
# the right default in production and the wrong one here: the test must wire the branch's
# incident.sh, not whatever is on main.
export SPIRA_HOME="$HERE"
UD="$TMP/units"; mkdir -p "$UD"
printf '[Service]\nExecStart=/bin/true\n' > "$UD/mtgc-alert-prod@.service"
export SPIRA_UNITDIR="$UD" SPIRA_SYSTEMCTL_RELOAD=0
intake() { "$HERE/install-intake.sh" "$@" 2>&1; }
want "status reports an unwired template" "UNWIRED" "$(intake status)"
want "install wires it"                   "wired    mtgc-alert-prod@.service" "$(intake install)"
[ -f "$UD/mtgc-alert-prod@.service.d/50-spira-intake.conf" ] \
    && ok "the drop-in is a sibling file, not an edit to the unit" \
    || bad "the drop-in is a sibling file, not an edit to the unit" "not written"
want "a failing intake cannot fail the alert" "ExecStart=-" \
     "$(cat "$UD/mtgc-alert-prod@.service.d/50-spira-intake.conf")"
want "the unit file itself is untouched" "ExecStart=/bin/true" "$(cat "$UD/mtgc-alert-prod@.service")"
want "a second install changes nothing"  "0 changed" "$(intake install)"
want "status now agrees"                 "1 of 1 alert template(s) wired" "$(intake status)"
want "uninstall removes it"              "removed 1" "$(intake uninstall)"
want "and status notices"                "UNWIRED" "$(intake status)"

# A drop-in that points at a script which cannot run is a wire that reports installed and
# delivers nothing — the exact defect sending.sh was written to stop.
FAKE="$TMP/fakehome"; mkdir -p "$FAKE"; printf '#!/bin/sh\n' > "$FAKE/incident.sh"; chmod -x "$FAKE/incident.sh"
out="$(SPIRA_HOME="$FAKE" intake install)"; rc=$?
want "install refuses to point at a non-executable incident.sh" "refusing" "$out"
rcis "and fails"  1 "$rc"

# ======================================================================================
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
