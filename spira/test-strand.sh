#!/usr/bin/env bash
#
# test-strand.sh — every strand kind, seen firing against a fixture.
#
# A detector nobody has watched detect anything is a hypothesis. These fixtures are the
# `bd list --json` shape verbatim, so each case asserts the same code path the sentinel runs
# every two minutes — and the negative cases matter more than the positive ones, because the
# expensive failure here is not a missed strand but a false one: reclaiming a bead an aeon is
# still working, or paging the operator about an epic that is merely waiting on them.
#
#   ./test-strand.sh          run every case
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLASSIFY="$HERE/strand-classify.py"
pass=0; fail=0

# now/expired timestamps, so the lease arithmetic is exercised rather than hardcoded
# THE ESCALATION LABEL IS PINNED TO A NON-DEFAULT VALUE HERE ON PURPOSE. Asserting against
# the shipped default would pass just as well if the classifier had the literal written in,
# which is the thing this key exists to stop; a distinctive value fails the moment one does.
export SPIRA_ASK_LABEL=needs-a-human

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LONG_AGO="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
SOON="$(date -u -d '5 minutes' +%Y-%m-%dT%H:%M:%SZ)"

run() {   # run <beads-json> <ready-json> <holders> <live> -> TSV on stdout
    BEADS="$1" READY="$2" HOLDERS="$3" LIVE="$4" GHOST_GRACE=300 python3 "$CLASSIFY"
}

check() {  # check <name> <expect-kinds|-> <beads> <ready> <holders> <live>
    local name="$1" expect="$2" got
    got="$(run "$3" "$4" "$5" "$6" | cut -f1 | sort -u | paste -sd, -)"
    [ -n "$got" ] || got=-      # `-` is the fixture vocabulary for "nothing stranded"
    if [ "$got" = "$expect" ]; then
        pass=$((pass+1)); printf '  ok    %s\n' "$name"
    else
        fail=$((fail+1)); printf '  FAIL  %s: expected [%s] got [%s]\n' "$name" "$expect" "$got"
        run "$3" "$4" "$5" "$6" | sed 's/^/          /'
    fi
}

bead() {  # bead <id> <status> [k=v ...] — emits one bead object
    python3 -c '
import json, sys
b = {"id": sys.argv[1], "status": sys.argv[2], "issue_type": "task", "labels": ["spira","plan"]}
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    b[k] = json.loads(v) if v[:1] in "[{\"" else v
print(json.dumps(b))' "$@"
}
arr() { printf '[%s]' "$(printf '%s\n' "$@" | paste -sd, -)"; }

echo "strand-classify:"

# -- ghost -----------------------------------------------------------------------------
# in_progress, lease long expired, no live holder. This is the case an assignee-based check
# cannot see: the bead says in_progress and names a worker that no longer exists.
check "ghost: dead holder, expired lease" ghost \
  "$(arr "$(bead sp-a in_progress assignee=aeon-builder "lease_expires_at=$LONG_AGO")")" '[]' 'sp-a	0' 1

# The two negatives that keep it from robbing live work.
check "ghost: live holder is not a ghost" - \
  "$(arr "$(bead sp-a in_progress assignee=aeon-builder "lease_expires_at=$LONG_AGO")")" '[]' 'sp-a	1' 1
check "ghost: unexpired lease is not a ghost" - \
  "$(arr "$(bead sp-a in_progress assignee=aeon-builder "lease_expires_at=$SOON")")" '[]' 'sp-a	0' 1
# The window between `bd ready --claim` and the pidfile being written: in_progress, no holder
# recorded yet, lease still fresh. Reclaiming here would take a bead off an aeon that is
# seconds into its work.
check "ghost: fresh claim with no pidfile yet" - \
  "$(arr "$(bead sp-a in_progress assignee=aeon-builder "lease_expires_at=$SOON")")" '[]' '' 1

# -- starved ---------------------------------------------------------------------------
check "starved: ready work, no live aeon" starved \
  "$(arr "$(bead sp-a open)")" "$(arr "$(bead sp-a open)")" '' 0
# Aeons at their concurrency cap is throughput, not starvation.
check "starved: ready work with an aeon running" - \
  "$(arr "$(bead sp-a open)" "$(bead sp-b in_progress "lease_expires_at=$SOON")")" \
  "$(arr "$(bead sp-a open)")" 'sp-b	1' 1

# -- deferred-unescalated ---------------------------------------------------------------
check "deferred without the escalation label is a strand" deferred-unescalated \
  "$(arr "$(bead sp-a deferred)")" '[]' '' 1
check "deferred WITH the escalation label is legitimate" - \
  "$(arr "$(bead sp-a deferred 'labels=["spira","plan","'"$SPIRA_ASK_LABEL"'"]')")" '[]' '' 1

# -- epic kinds -------------------------------------------------------------------------
EPIC='{"id":"sp-e","status":"open","issue_type":"epic","labels":["spira","plan"]}'
check "empty: open epic with no children" empty "$(arr "$EPIC")" '[]' '' 1

# every blocker closed, yet nothing is claimable: is_blocked went stale
DEP_CLOSED='{"id":"sp-dep","status":"closed","issue_type":"task","labels":["spira","plan"]}'
BLOCKED_BY_CLOSED="$(bead sp-a open parent=sp-e \
  'dependencies=[{"issue_id":"sp-a","depends_on_id":"sp-dep","type":"blocks"}]')"
check "stale-blocked: blockers all closed, none ready" stale-blocked \
  "$(arr "$EPIC" "$DEP_CLOSED" "$BLOCKED_BY_CLOSED")" '[]' '' 1

# blocked by a bead that is not in the partition at all — no aeon can ever clear it
BLOCKED_FOREIGN="$(bead sp-a open parent=sp-e \
  'dependencies=[{"issue_id":"sp-a","depends_on_id":"pd-999","type":"blocks"}]')"
check "blocked-external: blocker outside the partition" blocked-external \
  "$(arr "$EPIC" "$BLOCKED_FOREIGN")" '[]' '' 1

# blocked by an open in-partition bead that is itself going nowhere
STALLED_DEP='{"id":"sp-dep","status":"open","issue_type":"task","labels":["spira","plan"]}'
check "stuck: blocked by work that is not moving" stuck \
  "$(arr "$EPIC" "$STALLED_DEP" "$BLOCKED_BY_CLOSED" | sed 's/"status":"closed"/"status":"open"/')" \
  '[]' '' 1
# ...but if the blocker itself is ready, the plan is moving and this is not a strand
check "stuck: blocker is ready — not stranded" - \
  "$(arr "$EPIC" "$STALLED_DEP" "$BLOCKED_BY_CLOSED" | sed 's/"status":"closed"/"status":"open"/')" \
  "$(arr "$STALLED_DEP")" '' 1

# -- waiting / poisoned are informational, never escalated ------------------------------
WAIT_KID="$(bead sp-a open parent=sp-e 'labels=["spira","plan","'"$SPIRA_ASK_LABEL"'"]')"
check "waiting: all children need the operator" waiting "$(arr "$EPIC" "$WAIT_KID")" '[]' '' 1
POISON_KID="$(bead sp-a open parent=sp-e 'labels=["spira","plan","spira-poison"]')"
check "poisoned: all children poisoned" poisoned "$(arr "$EPIC" "$POISON_KID")" '[]' '' 1

got="$(run "$(arr "$EPIC" "$WAIT_KID")" '[]' '' 1 | cut -f3)"
if [ "$got" = info ]; then pass=$((pass+1)); printf '  ok    waiting is info, never escalate\n'
else fail=$((fail+1)); printf '  FAIL  waiting disposition: expected info got [%s]\n' "$got"; fi

# -- cycle ------------------------------------------------------------------------------
CYC_A="$(bead sp-a open 'dependencies=[{"issue_id":"sp-a","depends_on_id":"sp-b","type":"blocks"}]')"
CYC_B="$(bead sp-b open 'dependencies=[{"issue_id":"sp-b","depends_on_id":"sp-a","type":"blocks"}]')"
check "cycle: two beads blocking each other" cycle "$(arr "$CYC_A" "$CYC_B")" '[]' '' 1
# a plain chain is not a cycle
CHAIN_B='{"id":"sp-b","status":"open","issue_type":"task","labels":["spira","plan"]}'
check "cycle: a chain is not a ring" - "$(arr "$CYC_A" "$CHAIN_B")" '[]' '' 1

# -- the quiet case ---------------------------------------------------------------------
check "healthy: work in flight, nothing stranded" - \
  "$(arr "$(bead sp-a in_progress "lease_expires_at=$SOON")")" '[]' 'sp-a	1' 1
check "healthy: an empty partition strands nothing" - '[]' '[]' '' 0

# -- garbage in ---------------------------------------------------------------------------
# bd --json can print a warning before the payload; lib.sh strips it, but a classifier that
# dies on unexpected input takes the sentinel's whole pass with it.
check "malformed input yields no strands, not a crash" - 'not json' 'also not json' '' 1

# ======================================================================================
# The state machine: act once, then escalate; never both, never twice, never before the
# grace window. Driven through --from, with SPIRA_DB pointed at a path that does not exist
# so every bd call in the act path is an inert failure and the real graph is never touched.
# ======================================================================================
echo
echo "strand.sh check (state machine):"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ask.sh" <<'ASK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ASK_LOG"
ASK
chmod +x "$TMP/ask.sh"

strand() {   # strand <rows-tsv> — one `check` pass over a fixture
    printf '%s\n' "$1" | \
    SPIRA_DB=/nonexistent-spira-db SPIRA_RUN="$TMP/run" SPIRA_NOTIFY="$TMP/ask.sh" \
    ASK_LOG="$TMP/asks" SPIRA_STRAND_GRACE="${GRACE:-0}" \
    "$HERE/strand.sh" check --from - 2>&1
}
expect() {   # expect <name> <substring|-> <output>
    local name="$1" want="$2" got="$3"
    if { [ "$want" = - ] && [ -z "${got//[[:space:]]/}" ]; } || \
       { [ "$want" != - ] && [[ "$got" == *"$want"* ]]; }; then
        pass=$((pass+1)); printf '  ok    %s\n' "$name"
    else
        fail=$((fail+1)); printf '  FAIL  %s: wanted [%s] got [%s]\n' "$name" "$want" "$got"
    fi
}

mkdir -p "$TMP/run"; : > "$TMP/asks"
GHOST_ROW="ghost	sp-x	act	lease expired	bd reclaim --id sp-x"

# A mechanical fix runs on the first sighting, and only on the first.
expect "ghost is reclaimed once"        "RECLAIMED sp-x" "$(strand "$GHOST_ROW")"
expect "ghost is not reclaimed twice"   "STRANDED ghost" "$(strand "$GHOST_ROW")"
expect "ghost escalation is not repeated" -            "$(strand "$GHOST_ROW")"
expect "the escalation carries its action" "bd reclaim --id sp-x" "$(cat "$TMP/asks")"

# An escalate-disposition strand waits out the grace window; ready work with no aeon for one
# sentinel period is the normal gap between the two, not a fault.
rm -rf "$TMP/run"; mkdir -p "$TMP/run"; : > "$TMP/asks"
STARVED_ROW="starved	-	escalate	2 ready and no live aeon	check spira-sentinel.timer"
expect "starved is silent inside the grace window" - \
  "$(GRACE=99999 strand "$STARVED_ROW")"
expect "starved escalates once past it" "STRANDED starved" "$(strand "$STARVED_ROW")"
expect "starved does not escalate again" -            "$(strand "$STARVED_ROW")"

# info never reaches the operator, whatever its age. This is the alert-fatigue rule as a test: an
# epic waiting on them is already in their queue, and a second copy is what buries the first.
rm -rf "$TMP/run"; mkdir -p "$TMP/run"; : > "$TMP/asks"
expect "info is never escalated" - \
  "$(strand "waiting	sp-e	info	all children await the operator	none")"
expect "info files no ask" - "$(cat "$TMP/asks")"

# A strand that clears starts a fresh episode rather than inheriting a suppression.
rm -rf "$TMP/run"; mkdir -p "$TMP/run"; : > "$TMP/asks"
strand "$STARVED_ROW" >/dev/null
strand "" >/dev/null                       # the strand clears; state is pruned
expect "a cleared strand can escalate again" "STRANDED starved" "$(strand "$STARVED_ROW")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
