#!/usr/bin/env bash
#
# test-requeue-cap.sh — the requeue and reclaim caps: a bead one under must not escalate,
# a bead at or over must escalate with wording distinct from poison.
#
#   ./test-requeue-cap.sh
#
# THE DEFECT THIS GUARDS. The poison threshold caps sp-attempt-N at POISON_AT; the two
# excluded counters — sp-requeue-N (the harness put finished work back) and sp-reclaim-N
# (the aeon died holding it) — were uncapped. A bead that conflicted on every rebase could
# requeue indefinitely, spending one full aeon session per cycle, with nothing stopping it
# and nothing reaching the operator. The cap sends one escalation per crossing and names
# the cause distribution; the wording is distinct from poison because the diagnosis and the
# remedy differ.
#
# EVERY CASE IS A PAIR (law-absence-needs-a-positive-control). "No escalation fired" is
# also what a check that never runs returns. Each below-cap assertion is paired with an
# at-cap assertion through the same code path, so absence has been proven detectable.
#
# The escalation text is verified for the key phrases the bead description requires:
# - requeue: "completed and requeued" + count + "never landed"
# - reclaim: "aeons died holding" + count + "never judged"
# These distinguish the escalation from a poison ask, which says "change the approach".
#
# EXISTING POISON PATH IS NOT RETESTED HERE. test-poison.sh covers it; the only thing
# asserted here is that a bead with requeue/reclaim labels at the threshold and zero
# attempts is NOT poisoned — confirming the counters are not conflated.
#
# covers: spira/sentinel.sh spira/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not not want [$2] in [$3]"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-requeue-cap
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up requeue-cap || { echo "test-requeue-cap: could not build a fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree" "$SH/chamber"

cp "$HERE/sentinel.sh" "$HERE/lib.sh" "$HERE/landing.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub pilgrimage.sh 'printf "%s" "${PILGRIMAGE_OUT:-}"'
stub strand.sh     'printf "%s" "${STRAND_OUT:-}"'
stub sending.sh    'printf "%s" "${SENDING_OUT:-}"'
stub governor.sh   'exit 0'
stub gate.sh       'exit ${GATE_RC:-0}'
stub reflect.sh    'touch "$SPIRA_RUN/reflect.fired"'
stub ask.sh        'printf "%s\n" "$*" >> "$ASK_LOG"; true'

# TWO PERSONAS to prove the check is not hardcoded to one partition.
printf 'FAYTH_LABELS="spira,plan"\nFAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL,$SPIRA_CI_LABEL"\nFAYTH_MAX_CONCURRENT=0\n' > "$SH/chamber/t.fayth"
printf 'FAYTH_LABELS="spira,incident"\nFAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL,$SPIRA_CI_LABEL"\nFAYTH_MAX_CONCURRENT=0\n' > "$SH/chamber/tinc.fayth"

B() { bd -C "$SPIRA_DB" "$@"; }
export ASK_LOG="$TMP/ask.log"; : > "$ASK_LOG"
cat > "$TMP/launch" <<'L'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCH_LOG"
exit "${LAUNCH_RC:-0}"
L
cat > "$TMP/systemctl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "${LAND_STATE:-inactive}"
S
chmod +x "$TMP/launch" "$TMP/systemctl"
export LAUNCH_LOG="$TMP/launch.log"

sentinel() {
    rm -f "$RUN/reflect.fired" "$RUN/inference.cooldown"
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" \
    SPIRA_REPO="$REPO" \
    SPIRA_GOAL=sp-goal SPIRA_FAYTHS="${ROSTER:-t}" SPIRA_INFERENCE_EVERY=0 \
    SPIRA_NOTIFY="$SH/ask.sh" \
    SPIRA_LAUNCH="$TMP/launch" SPIRA_SYSTEMCTL="$TMP/systemctl" \
    SPIRA_SUMMON="$TMP/launch" \
    SPIRA_SKIP_RECLAIM=1 \
    SPIRA_REQUEUE_AT="${SPIRA_REQUEUE_AT:-3}" \
    SPIRA_RECLAIM_AT="${SPIRA_RECLAIM_AT:-3}" \
        bash "$SH/sentinel.sh" 2>&1
}

labels_of() { B show "$1" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(" ".join(d[0].get("labels") or []))'; }

# SEED a goal epic plus one ready bead carrying specific counter labels.
# The bead must be dispatchable — labels matching a fayth's partition, no blockers.
# Clears the asked-dirs so dedup state from a prior case does not bleed in; but
# consecutive sentinel calls within one case intentionally keep that state, which is
# how the dedup assertions prove the mechanism works.
seed_bead() {   # seed_bead <id> <extra-labels...>
    testdb_reset
    rm -rf "$RUN/requeue-asked" "$RUN/reclaim-asked" "$RUN/poison-asked"
    rm -f "$ASK_LOG"; : > "$ASK_LOG"
    testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[],"updated_at":"2026-09-11T00:00:00Z"}
{"id":"$1","title":"test bead","status":"open","issue_type":"task","labels":["spira","plan"$(for l in "${@:2}"; do printf ',"%s"' "$l"; done)],"updated_at":"2026-09-11T00:00:00Z"}
JSONL
}

echo "test-requeue-cap.sh"

# --------------------------------------------------------------------------------------
# REQUEUE CAP
# --------------------------------------------------------------------------------------
echo
echo "requeue cap — below threshold, no escalation:"
# Cap is 3; at requeue-2 (one below), nothing fires.
seed_bead sp-rq-lo "sp-requeue-2-rebase-conflict"
sentinel >/dev/null 2>&1 || true
nowant "bead one under the requeue cap is not escalated" \
       "completed and requeued" "$(cat "$ASK_LOG")"
nowant "and is not poisoned"  "spira-poison" "$(labels_of sp-rq-lo)"

echo
echo "requeue cap — at threshold, escalation fires:"
seed_bead sp-rq-hi "sp-requeue-3-rebase-conflict"
sentinel >/dev/null 2>&1 || true
want   "bead at the requeue cap is escalated"            "completed and requeued" "$(cat "$ASK_LOG")"
want   "the count appears in the subject"                "3 times"                "$(cat "$ASK_LOG")"
want   "the subject says it never landed"                "never landed"           "$(cat "$ASK_LOG")"
want   "the cause distribution is named"                 "rebase-conflict"        "$(cat "$ASK_LOG")"
nowant "but it is NOT poisoned"                          "spira-poison"           "$(labels_of sp-rq-hi)"

echo
echo "requeue cap — dedup: second pass with the same count does not re-ask:"
: > "$ASK_LOG"
sentinel >/dev/null 2>&1 || true
nowant "same requeue count does not re-ask on the next pass" "completed and requeued" "$(cat "$ASK_LOG")"

echo
echo "requeue cap — new count after the threshold crosses again asks once more:"
seed_bead sp-rq-hi2 "sp-requeue-4-rebase-conflict"
sentinel >/dev/null 2>&1 || true
want   "a higher requeue count fires a new ask" "completed and requeued" "$(cat "$ASK_LOG")"
want   "naming the new count"                   "4 times"                "$(cat "$ASK_LOG")"

# --------------------------------------------------------------------------------------
# RECLAIM CAP
# --------------------------------------------------------------------------------------
echo
echo "reclaim cap — below threshold, no escalation:"
seed_bead sp-rc-lo "sp-reclaim-2"
sentinel >/dev/null 2>&1 || true
nowant "bead one under the reclaim cap is not escalated" \
       "aeons died holding" "$(cat "$ASK_LOG")"
nowant "and is not poisoned" "spira-poison" "$(labels_of sp-rc-lo)"

echo
echo "reclaim cap — at threshold, escalation fires:"
seed_bead sp-rc-hi "sp-reclaim-3"
sentinel >/dev/null 2>&1 || true
want   "bead at the reclaim cap is escalated"            "aeons died holding" "$(cat "$ASK_LOG")"
want   "the count appears in the subject"                "3 aeons"            "$(cat "$ASK_LOG")"
want   "the subject says work was never judged"          "never judged"       "$(cat "$ASK_LOG")"
nowant "but it is NOT poisoned"                          "spira-poison"       "$(labels_of sp-rc-hi)"

echo
echo "reclaim cap — dedup: second pass does not re-ask:"
: > "$ASK_LOG"
sentinel >/dev/null 2>&1 || true
nowant "same reclaim count does not re-ask on the next pass" "aeons died holding" "$(cat "$ASK_LOG")"

# --------------------------------------------------------------------------------------
# COUNTERS DO NOT CONFLATE: a bead with only requeue/reclaim counters is not poisoned
# even when those counters are large.
# --------------------------------------------------------------------------------------
echo
echo "counters do not conflate — large requeue/reclaim with zero attempts is never poisoned:"
seed_bead sp-no-poison "sp-requeue-10-rebase-conflict" "sp-reclaim-10"
SPIRA_REQUEUE_AT=999 SPIRA_RECLAIM_AT=999 sentinel >/dev/null 2>&1 || true
nowant "a bead with no attempts is never poisoned regardless of requeue/reclaim count" \
       "spira-poison" "$(labels_of sp-no-poison)"

# --------------------------------------------------------------------------------------
# POISON PATH UNCHANGED — a bead that has only attempt labels (no requeue/reclaim) is
# still poisoned at the attempt threshold and not touched by the new code.
# --------------------------------------------------------------------------------------
echo
echo "poison path unchanged — attempt-only bead is still poisoned at the threshold:"
seed_bead sp-attempts "sp-attempt-1-unlanded" "sp-attempt-2-unlanded" "sp-attempt-3-unlanded"
sentinel >/dev/null 2>&1 || true
want "a bead at the attempt threshold is still poisoned" "spira-poison" "$(labels_of sp-attempts)"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
