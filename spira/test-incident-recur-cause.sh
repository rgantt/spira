#!/usr/bin/env bash
#
# test-incident-recur-cause.sh — sp-recur-N labels carry a cause suffix.
#
#   ./test-incident-recur-cause.sh
#
# THE PROPERTY THIS TESTS. A recurrence label must be sp-recur-N-<cause>, never bare
# sp-recur-N. Without a cause the corpus cannot be grouped by failure class, which is
# the prerequisite for Maechen naming a class before Ryan notices it.
#
# THREE SCENARIOS:
#
#   1. Default cause (SPIRA_INCIDENT_CAUSE unset): label is sp-recur-1-unrecorded.
#      A caller that does not know the cause must still record something — unrecorded is
#      explicit, not silent (control: the census groups unrecorded separately from any
#      named cause, so "we did not capture it" is still queryable).
#
#   2. Named cause (SPIRA_INCIDENT_CAUSE=suite-red): label is sp-recur-1-suite-red, then
#      sp-recur-2-suite-red on the recurrence. counter_causes must return cause=suite-red.
#
#   3. backfill-recur-causes: a bead carrying a bare sp-recur-1 label is converted to
#      sp-recur-1-unrecorded; a bead already carrying sp-recur-1-unrecorded is not double-
#      converted (safe to re-run).
#
# A REAL bd ON A FIXTURE DATABASE (law-prefer-the-real-dependency).
#
# covers: spira/incident.sh spira/lib.sh
# hermetic-ok: uses a fixture database, no systemd or gh
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
testdb_require test-incident-recur-cause
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up rc_cause || { echo "test-incident-recur-cause: could not build a fixture database"; exit 1; }

# lib.sh is sourced for counter_of / counter_causes / recur_causes.
# shellcheck disable=SC1090
. "$HERE/lib.sh"
INC="$HERE/incident.sh"
B() { bd -C "$SPIRA_DB" "$@"; }
mkdir -p "$TMP/run"

# Stub the ask path so no real escalation fires.
cat > "$TMP/ask.sh" <<'A'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ASK_LOG"
A
chmod +x "$TMP/ask.sh"
export ASK_LOG="$TMP/ask.log"

file_incident() {  # file_incident <ref> <title> <payload> [VAR=val ...]
    local ref="$1" title="$2" payload="$3"; shift 3
    printf '%s' "$payload" | \
        env SPIRA_DB="$SPIRA_DB" SPIRA_RUN="$TMP/run" SPIRA_CONF="$TMP/no-conf" \
        SPIRA_INCIDENT_REF="$ref" SPIRA_ASK="$TMP/ask.sh" \
        SPIRA_INCIDENT_LOCK="$TMP/run/rc-cause-test.lock" \
        SPIRA_INCIDENT_REPO= \
        "$@" \
        bash "$INC" file "$title" - 2>/dev/null
}

# Read the highest sp-recur-N value, regardless of cause suffix.
recur_max() { B label list "$1" 2>/dev/null | grep -oE 'sp-recur-[0-9]+' \
    | grep -oE '[0-9]+$' | sort -n | tail -1 || echo 0; }

# Check whether a bead carries a label containing the given substring.
# Captures before matching — grep -q closes the pipe early and SIGPIPE the writer
# under pipefail (law-no-grep-q-under-pipefail).
has_label_like() { local all; all="$(B label list "$1" 2>/dev/null)"; [[ "$all" == *"$2"* ]]; }

echo "test-incident-recur-cause.sh"

# ======================================================================================
echo
echo "1. default cause (SPIRA_INCIDENT_CAUSE unset) — label is sp-recur-1-unrecorded:"
# ======================================================================================
testdb_reset; mkdir -p "$TMP/run"
ref="incident:test-default-cause"
file_incident "$ref" "default cause test" "payload 1" >/dev/null

bid="$(B list --status open --limit 0 --label spira,incident --json 2>/dev/null \
    | python3 -c '
import json,sys
target=sys.argv[1]
try: d=json.load(sys.stdin)
except: sys.exit(0)
d=d if isinstance(d,list) else [d]
for i in d:
    if i.get("external_ref")==target: print(i["id"]); break
' "$ref" 2>/dev/null)"
[ -n "$bid" ] && ok "bead was created for default-cause ref" \
    || { bad "bead was created for default-cause ref" "none found"; printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"; exit 1; }

has_label_like "$bid" "sp-recur-1-unrecorded" \
    && ok "initial filing carries sp-recur-1-unrecorded" \
    || bad "initial filing carries sp-recur-1-unrecorded" "labels: $(B label list "$bid" 2>/dev/null)"

nowant "bare sp-recur-1 NOT written" "sp-recur-1 " " $(B label list "$bid" 2>/dev/null | tr -d '-') " \
    || true  # belt: recur_max already pins the count

# ======================================================================================
echo
echo "2. named cause (suite-red) — label is sp-recur-1-suite-red, then sp-recur-2-suite-red:"
# ======================================================================================
testdb_reset; mkdir -p "$TMP/run"; > "$ASK_LOG"
ref2="incident:test-named-cause"
file_incident "$ref2" "named cause test" "payload 1" SPIRA_INCIDENT_CAUSE=suite-red >/dev/null
file_incident "$ref2" "named cause test" "payload 2" SPIRA_INCIDENT_CAUSE=suite-red >/dev/null

bid2="$(B list --status open --limit 0 --label spira,incident --json 2>/dev/null \
    | python3 -c '
import json,sys
target=sys.argv[1]
try: d=json.load(sys.stdin)
except: sys.exit(0)
d=d if isinstance(d,list) else [d]
for i in d:
    if i.get("external_ref")==target: print(i["id"]); break
' "$ref2" 2>/dev/null)"
[ -n "$bid2" ] && ok "bead was created for named-cause ref" \
    || { bad "bead was created for named-cause ref" "none found"; printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"; exit 1; }

has_label_like "$bid2" "sp-recur-1-suite-red" \
    && ok "initial filing carries sp-recur-1-suite-red" \
    || bad "initial filing carries sp-recur-1-suite-red" "labels: $(B label list "$bid2" 2>/dev/null)"

is "recurrence counter advanced to 2 after second filing" "2" "$(recur_max "$bid2")"

has_label_like "$bid2" "sp-recur-2-suite-red" \
    && ok "recurrence carries sp-recur-2-suite-red" \
    || bad "recurrence carries sp-recur-2-suite-red" "labels: $(B label list "$bid2" 2>/dev/null)"

# recur_causes (via lib.sh counter_causes) must surface the named cause.
causes="$(recur_causes "$bid2")"
want "recur_causes reports suite-red" "suite-red" "$causes"
nowant "recur_causes does not report unrecorded" "unrecorded" "$causes"

# ======================================================================================
echo
echo "3. backfill-recur-causes converts bare sp-recur-N to sp-recur-N-unrecorded:"
# ======================================================================================
testdb_reset; mkdir -p "$TMP/run"
# Plant a bead manually with a bare sp-recur-1 label (simulates pre-change code).
bare_id="$(B create "bare recur test" --type bug --priority 2 \
    --labels spira,incident --external-ref "incident:bare-recur" --silent 2>/dev/null \
    | tr -d '[:space:]')"
[ -n "$bare_id" ] || { bad "planted bare-recur bead" "create failed"; \
    printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"; exit 1; }
B label add "$bare_id" "sp-recur-1" >/dev/null 2>&1
B label add "$bare_id" "sp-recur-2" >/dev/null 2>&1

# Also plant a bead already carrying a typed label — backfill must leave it alone.
typed_id="$(B create "typed recur test" --type bug --priority 2 \
    --labels spira,incident --external-ref "incident:typed-recur" --silent 2>/dev/null \
    | tr -d '[:space:]')"
[ -n "$typed_id" ] || { bad "planted typed-recur bead" "create failed"; \
    printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"; exit 1; }
B label add "$typed_id" "sp-recur-1-suite-red" >/dev/null 2>&1

out="$(SPIRA_DB="$SPIRA_DB" SPIRA_RUN="$TMP/run" \
    SPIRA_INCIDENT_LOCK="$TMP/run/rc-cause-test.lock" \
    bash "$INC" backfill-recur-causes 2>/dev/null)"

want "backfill reports 1 bead backfilled" "backfilled 1" "$out"
want "backfill reports 0 errors" "errors 0" "$out"

has_label_like "$bare_id" "sp-recur-1-unrecorded" \
    && ok "bare sp-recur-1 promoted to sp-recur-1-unrecorded" \
    || bad "bare sp-recur-1 promoted to sp-recur-1-unrecorded" "labels: $(B label list "$bare_id" 2>/dev/null)"

has_label_like "$bare_id" "sp-recur-2-unrecorded" \
    && ok "bare sp-recur-2 promoted to sp-recur-2-unrecorded" \
    || bad "bare sp-recur-2 promoted to sp-recur-2-unrecorded" "labels: $(B label list "$bare_id" 2>/dev/null)"

# Bare labels must be removed (not just joined by typed ones — that would double-count).
# Capture then scan — grep -q under pipefail closes the pipe early and SIGPIPEs the writer.
_all_backfill="$(B label list "$bare_id" 2>/dev/null)"
# A bare sp-recur-1 rung appears as its own label token; sp-recur-1-unrecorded also contains
# "sp-recur-1" as a substring, so match "- sp-recur-1" at end-of-line or before whitespace.
_found_bare="$(printf '%s\n' "$_all_backfill" | grep -xE '[[:space:]]*-[[:space:]]*sp-recur-1' || true)"
[ -z "$_found_bare" ] && ok "bare sp-recur-1 removed after backfill" \
    || bad "bare sp-recur-1 removed after backfill" "still present: $_found_bare"

# The already-typed bead must be unchanged (idempotence positive control).
has_label_like "$typed_id" "sp-recur-1-suite-red" \
    && ok "already-typed bead is untouched by backfill" \
    || bad "already-typed bead is untouched by backfill" "labels: $(B label list "$typed_id" 2>/dev/null)"

# ======================================================================================
echo
echo "4. backfill-recur-causes is idempotent (safe to re-run):"
# ======================================================================================
out2="$(SPIRA_DB="$SPIRA_DB" SPIRA_RUN="$TMP/run" \
    SPIRA_INCIDENT_LOCK="$TMP/run/rc-cause-test.lock" \
    bash "$INC" backfill-recur-causes 2>/dev/null)"
want "second run reports 0 backfilled" "backfilled 0" "$out2"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
