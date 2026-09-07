#!/usr/bin/env bash
#
# test-sentinel.sh — the sentinel's action accounting, and the judgement gate it feeds.
#
#   ./test-sentinel.sh
#
# ONE CLAIM UNDER TEST: a write that moves nothing must not silence CHECK 8. That check is
# the only one that notices the harness is stuck, and every regression so far has taken the
# same shape — some earlier check reports an action it did not achieve, `acted` is therefore
# never 0, and starvation detection is disabled while the log reads as a busy harness. The
# reclaim probe matching its own idle message did it, the re-landed branch did it, and
# `recompute-blocked` — which fires on exactly CHECK 8's precondition and exits 0 whether or
# not it changed a flag — did it on every starved pass.
#
# So the assertions are mostly NEGATIVE: given a pass that wrote, did judgement still fire?
# A suite that only checked the happy path would have passed against every one of those bugs.
#
# The database is a REAL bd on a fixture created for the run and dropped by a trap: a model
# of a dependency is a second implementation of it, and the two disagreeing is a bug in
# neither and a failure in both. CHECK 2's idle message and CHECK 3's stale is_blocked flag
# are things `bd` decides, and a fake that merely echoes them proves only that the author
# remembered them correctly. The sub-programs (pilgrimage, strand, sending, reflect, and the
# landing worker) ARE stubs whose output the test dictates: each has its own suite, and what
# is under test here is how the sentinel COUNTS what they report.
#
# LANDING IS NO LONGER ONE OF THE THINGS THIS SUITE DRIVES END TO END. It ran inside the
# pass until sp-gatecost; it is now a separate process the pass dispatches and never waits
# on, so what it DOES belongs to test-landing.sh and what is left here is the seam — the
# dispatch, the mutex, the mailbox, and the positive control that keeps a worker which
# stopped working from reading as a quiet week.
#
# covers: spira/sentinel.sh spira/landing.sh spira/sending.sh spira/strand.sh spira/pilgrimage.sh spira/reflect.sh spira/chamber/*
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
judged()    { [ -f "$RUN/reflect.fired" ] && ok "$1" || bad "$1" "CHECK 8 did not fire"; }
notjudged() { [ ! -f "$RUN/reflect.fired" ] && ok "$1" || bad "$1" "CHECK 8 fired"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-sentinel
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up sentinel || { echo "test-sentinel: could not build a fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree" "$SH/chamber"

# The program under test, run out of its own directory so it sources the real lib.sh but
# finds stubbed sub-programs beside it.
cp "$HERE/sentinel.sh" "$HERE/lib.sh" "$HERE/landing.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub pilgrimage.sh 'printf "%s" "${PILGRIMAGE_OUT:-}"'
stub strand.sh     'printf "%s" "${STRAND_OUT:-}"'
stub sending.sh    'printf "%s" "${SENDING_OUT:-}"'
stub gate.sh       'exit ${GATE_RC:-0}'
stub reflect.sh    'touch "$SPIRA_RUN/reflect.fired"'
# The ask is RECORDED, not merely swallowed. Half of what this suite asserts about the
# landing leg is that a failure reaches the operator, and an ask.sh that exits 0 without a trace
# would pass whether or not it was ever called.
stub ask.sh        'printf "%s\n" "$*" >> "$ASK_LOG"'
# Concurrency 0, so CHECK 7 never reaches systemd-run: this suite is about accounting, and a
# summon in a test would put a real aeon on a real database.
#
# TWO PERSONAS, EACH WITH A PARTITION OF ITS OWN. The reaper and the closed-not-landed sweep
# ask the chamber which partitions exist, and a single-persona chamber cannot tell a sweep of
# the chamber apart from a sweep of one hardcoded partition — which is what both of them were.
printf 'FAYTH_LABELS="spira,plan"\nFAYTH_MAX_CONCURRENT=0\n'     > "$SH/chamber/t.fayth"
printf 'FAYTH_LABELS="spira,incident"\nFAYTH_MAX_CONCURRENT=0\n' > "$SH/chamber/tinc.fayth"

B() { bd -C "$SPIRA_DB" "$@"; }
status_of() { B show "$1" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(d[0].get("status") or "")'; }
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
launched() { cat "$LAUNCH_LOG" 2>/dev/null; }
sentinel() {
    rm -f "$RUN/reflect.fired" "$RUN/inference.cooldown"
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" \
    SPIRA_REPO="$REPO" \
    SPIRA_GOAL=sp-goal SPIRA_FAYTHS="${ROSTER:-t tinc}" SPIRA_INFERENCE_EVERY=0 \
    SPIRA_NOTIFY="$SH/ask.sh" \
    SPIRA_LAUNCH="$TMP/launch" SPIRA_SYSTEMCTL="$TMP/systemctl" \
        bash "$SH/sentinel.sh" 2>&1
}

# CHECK 8's precondition: one open bead under the goal that nothing can claim, and nothing
# else moving. `unready` is a REAL blocking dependency on an open bead outside the goal —
# not a flag the fixture asserts — so `bd ready` reaches its verdict the way it does in
# production, and `recompute-blocked` on this database correctly changes nothing.
#
# Parenthood is a `parent-child` dependency, which is how the live database expresses it:
# `bd children` is an alias for `bd list --parent`, and a bare "parent" field on an import
# row creates no edge at all.
seed() {   # seed  — the whole database: the goal, its one unclaimable child, the blocker
    testdb_reset
    testdb_seed <<'JSONL'
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[],"updated_at":"2026-09-04T00:00:00Z"}
{"id":"sp-block","title":"the blocker","status":"open","issue_type":"task","labels":[],"updated_at":"2026-09-04T00:00:00Z"}
{"id":"sp-open","title":"blocked","status":"open","issue_type":"task","labels":["spira","plan"],"updated_at":"2026-09-04T00:00:00Z","dependencies":[{"issue_id":"sp-open","depends_on_id":"sp-goal","type":"parent-child"},{"issue_id":"sp-open","depends_on_id":"sp-block","type":"blocks"}]}
JSONL
}

# A GENUINELY STALE is_blocked FLAG, which is the only thing CHECK 3 exists for. bd's own
# documentation names the cause — a scoped post-pull recompute that was skipped — so the
# fixture reproduces the state rather than a fake's willingness to say it changed something.
# The write must be COMMITTED: `recompute-blocked` refuses a dirty working set outright, and
# a refusal here would test the sentinel against a check that never ran.
stale_block() {   # stale_block <id> — mark it blocked behind nothing
    testdb_sql "$TESTDB_NAME" \
        "update issues set is_blocked=1 where id='$1'; \
         call dolt_commit('-A','-m','stale is_blocked','--skip-empty');" >/dev/null 2>&1
}

echo "test-sentinel.sh"

# --------------------------------------------------------------------------------------
# The predicate itself. A starved harness writes on every pass — recompute-blocked runs on
# exactly this state — and must still reach judgement.
# --------------------------------------------------------------------------------------
seed; out="$(sentinel)"
want   "recompute runs on a starved pass" "recomputed is_blocked" "$out"
nowant "and is not counted as progress"   "freed" "$out"
want   "the pass reports zero progress"   "0 progress" "$out"
judged "judgement fires despite the write"

# The reclaim idle message is not an action. This is the first bug that blinded CHECK 8.
nowant "the reclaim idle message counts nothing" "reclaimed" "$out"

# --------------------------------------------------------------------------------------
# A recompute that actually frees work IS progress — and then CHECK 7 owns the pass.
# --------------------------------------------------------------------------------------
seed; B close sp-block --reason-file - <<< "the blocker is done" >/dev/null 2>&1
stale_block sp-open
out="$(sentinel)"
want       "a recompute that frees work is progress" "recompute-blocked freed 1 bead(s)" "$out"
notjudged  "and ready work is not starvation"

# --------------------------------------------------------------------------------------
# strand.sh: reclaiming moves a bead, escalating does not. An escalation says something is
# STUCK, so counting it as progress would mute judgement at the worst possible moment.
# --------------------------------------------------------------------------------------
seed; out="$(STRAND_OUT='STRANDED sp-open ready, no aeon' sentinel)"
want   "a strand escalation is a write" "escalated 1 stranded item(s)" "$out"
nowant "not a movement"                 "handled" "$out"
judged "and does not mute judgement"

seed; out="$(STRAND_OUT='RECLAIMED sp-open ghost lease' sentinel)"
want      "a reclaimed ghost is progress" "handled 1 stranded item(s)" "$out"
notjudged "and defers judgement one pass"

# --------------------------------------------------------------------------------------
# A reap is tidying, not movement: nothing landed that had not already landed.
# --------------------------------------------------------------------------------------
seed; out="$(SENDING_OUT='REAPED spira/sp-gone branch+worktree' sentinel)"
want   "a reap is counted as an action" "reaped 1 landed branch(es)" "$out"
judged "but does not mute judgement"

# ======================================================================================
# EVERY PARTITION IN THE CHAMBER, NOT THE BUILDER'S. CHECK 2 reclaimed with `--label
# spira,plan` and CHECK 5 listed closed beads the same way, so an aeon of any other persona
# that died left its bead in_progress with no time-based reaper looking at it, and a bead of
# any other persona could close with nothing on the commit graph naming it and pass the one
# sweep that exists to catch that. Both checks returned clean over exactly that state, which
# is indistinguishable from a healthy harness (law-absence-needs-a-positive-control).
#
# So each case here is a PAIR: the incident work is seen with the incident persona in the
# roster, and NOT seen with the roster narrowed to the plan — which is the shape of the bug,
# and the proof that the passing half could have failed.
# ======================================================================================
echo

# The plan's own fixture, plus an incident bead held under a lease that died. The lease is a
# REAL one taken by `bd ready --claim` and then backdated: `bd reclaim` reaps only leases
# this replica granted, so an imported lease_expires_at is not a lease at all and the check
# would pass over it for a reason that has nothing to do with the partition.
seed_dead_incident() {
    seed
    testdb_seed <<'JSONL'
{"id":"sp-inc","title":"an incident","status":"open","issue_type":"task","labels":["spira","incident"],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
    B ready --claim --limit 0 --label spira,incident >/dev/null 2>&1
    testdb_sql "$TESTDB_NAME" \
        "update leases set granted_at='2026-09-01 00:00:00', lease_expires_at='2026-09-01 00:00:00', \
                           heartbeat_at='2026-09-01 00:00:00' where issue_id='sp-inc'; \
         update issues set lease_expires_at='2026-09-01 00:00:00', heartbeat_at='2026-09-01 00:00:00' \
                           where id='sp-inc'; \
         call dolt_commit('-A','-m','a dead lease','--skip-empty');" >/dev/null 2>&1
}

seed_dead_incident
is   "the fixture starts with the incident held" "in_progress" "$(status_of sp-inc)"
out="$(ROSTER=t sentinel)"
nowant "a roster of the plan alone reaps nothing" "reclaimed" "$out"
is     "and the incident bead is still held"      "in_progress" "$(status_of sp-inc)"
out="$(sentinel)"
want "the reaper sweeps the incident partition too" "reclaimed 1 stale lease(s)" "$out"
is   "and the bead is claimable again"              "open" "$(status_of sp-inc)"

# A closed bead with no commit naming it, in a partition that is not the plan's. Only beads
# an aeon worked are judged, which is what the session log stands for.
seed_closed_incident() {
    seed
    testdb_seed <<'JSONL'
{"id":"sp-incx","title":"an incident, closed","status":"closed","issue_type":"task","labels":["spira","incident"],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
    : > "$RUN/sp-incx.log"
}

seed_closed_incident
out="$(ROSTER=t sentinel)"
nowant "a roster of the plan alone judges no incident bead" "sp-incx" "$out"
is     "and it stays closed on a lie"                       "closed" "$(status_of sp-incx)"
out="$(sentinel)"
want "closed-not-landed sweeps the incident partition too" "reopened sp-incx — closed without landing" "$out"
is   "and the bead is open again"                          "open" "$(status_of sp-incx)"

# A SUPERSEDED BEAD IS THE ONE CLOSE THAT IS RIGHT TO HAVE NO COMMIT NAMING IT. Its work
# landed under the successor's id, so CHECK 5's question — "does any commit name this bead?"
# — is answered "no" by a bead that is perfectly finished. The exemption reads the
# `supersedes` dependency `bd supersede` records.
#
# THE DEPENDENCY IS RECORDED BY `bd supersede`, NOT SEEDED AS A LITERAL, because the defect
# this covers was entirely in the SHAPE bd returns: `bd show` names the field
# "dependency_type" and `bd list` names it "type", and the sentinel read the show spelling
# off a list row. Every dependency therefore looked like None, `sup` was 0 for every bead in
# the database, and the exemption had never fired once — sp-dvlq, superseded by sp-35pl, was
# reopened as closed-without-landing every two minutes until someone read the log. A seeded
# literal would encode whichever spelling the author had in mind and pass against the bug.
seed_superseded() {
    seed_closed_incident
    testdb_seed <<'JSONL'
{"id":"sp-supx","title":"the successor that actually landed","status":"closed","issue_type":"task","labels":["spira","incident"],"updated_at":"2026-09-04T00:00:00Z"}
{"id":"sp-oldx","title":"the duplicate it replaced","status":"open","issue_type":"task","labels":["spira","incident"],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
    : > "$RUN/sp-oldx.log"
    B supersede sp-oldx --with sp-supx >/dev/null 2>&1
}

seed_superseded
is   "the fixture's duplicate is closed by the supersede" "closed" "$(status_of sp-oldx)"
# THE POSITIVE CONTROL FOR THIS BLOCK. sp-incx is seeded identically and carries no
# supersedes edge; it MUST still be reopened in the same pass. Without it, an exemption that
# had grown to swallow every bead — or a pass that judged nothing at all — would look exactly
# like the fix working (law-absence-needs-a-positive-control).
out="$(sentinel)"
want   "a closed bead with no supersedes edge is still reopened" "reopened sp-incx — closed without landing" "$out"
nowant "but the superseded one is not judged for landing"        "sp-oldx" "$out"
is     "and it stays closed"                                     "closed" "$(status_of sp-oldx)"

# ...and a chamber that declares no partition at all says so, rather than sweeping nothing
# quietly. A reaper with nothing to reap over and a harness with no dead leases write the
# same empty output.
seed_dead_incident; out="$(ROSTER=nosuchfayth sentinel)"
want "a chamber with no partition says the reaper is idle" "no lease is being reaped" "$out"
want "and that nothing is being checked for landing"       "no closed bead is being checked" "$out"

# ======================================================================================
# CHECK 6 — DISPATCH, NOT LANDING. The landing worker is its own program with its own suite
# (test-landing.sh). What is under test here is the seam: that the pass hands off and does
# not wait, that it refuses to start a second worker over a running one, that it counts what
# the previous run reported exactly once, and that a worker which has stopped working is
# reported rather than read as a quiet week.
#
# The dispatch itself is stubbed through SPIRA_LAUNCH and systemd through SPIRA_SYSTEMCTL,
# for the same reason `bd` and `gh` are stubbed elsewhere: there is no other way to ask a
# suite to produce "the unit is already active" or "systemd-run refused".
# ======================================================================================

seed; : > "$LAUNCH_LOG"; out="$(sentinel)"
want "the pass dispatches a landing"          "landing dispatched as spira-landing" "$out"
want "as a transient unit with a fixed name"  "--unit=spira-landing" "$(launched)"
want "which is the mutex, so it is collected on failure" "--collect" "$(launched)"
want "and it runs landing.sh"                 "/landing.sh" "$(launched)"
want "the environment is passed explicitly"   "--setenv=SPIRA_DB=" "$(launched)"
# law-gates-run-in-a-clean-environment, and the exact variable that produced the scar: a
# sentinel exporting its roster into a transient unit had it reach a suite asserting
# defaults, and correct work was rejected on every retry with nothing naming the cause.
nowant "and the pass's own roster is NOT forwarded" "SPIRA_FAYTHS" "$(launched)"

# --------------------------------------------------------------------------------------
# The unit name is the mutex. A pass arriving while a landing is still in flight declines —
# and must not report that as a failure, because it is the wanted behaviour.
# --------------------------------------------------------------------------------------
seed; : > "$LAUNCH_LOG"; out="$(LAND_STATE=active sentinel)"
want  "a landing in flight is not restarted" "already in flight" "$out"
is    "and nothing is dispatched"            ""                  "$(launched)"
nowant "and it is not reported as a failure" "WARN"              "$out"

# --------------------------------------------------------------------------------------
# THE MAILBOX. Landing no longer runs inside the pass, so a movement it made is counted by
# the NEXT pass — and counted exactly once, or a landed branch mutes the judgement tier for
# as long as the file survives. This is the same defect as the re-landed branch, arriving by
# a new route: the worker is now on the other side of a file.
# --------------------------------------------------------------------------------------
seed; : > "$LAUNCH_LOG"
printf 'landed spira/sp-x\n' > "$RUN/landing.progress"
out="$(sentinel)"
want      "a landing reported by the worker is counted" "ACT landed spira/sp-x" "$out"
want      "and counted as progress, not just a write"   "1 progress" "$out"
notjudged "so a real landing defers judgement one pass"

out="$(sentinel)"
nowant "the same line is never counted twice" "ACT landed spira/sp-x" "$out"
want   "the pass reports zero progress"       "0 progress" "$out"
judged "so a drained mailbox cannot blind judgement"

# The mailbox is drained by RENAME, so a pass that dies between the rename and the read
# leaves a drain file holding movements the DAG really made. Losing them is the same class
# of bug as counting them twice, arriving from the other side: the next pass judges itself
# starved when it was not.
seed; printf 'landed spira/sp-orphan\n' > "$RUN/landing.progress.drain.999"
out="$(sentinel)"
want      "a drain file left by a dead pass is picked up" "ACT landed spira/sp-orphan" "$out"
notjudged "and its movement still counts"
[ -e "$RUN/landing.progress.drain.999" ] \
    && bad "and is not left to rot" "the file survived" \
    || ok "and is not left to rot"

# --------------------------------------------------------------------------------------
# THE POSITIVE CONTROL. Fire and forget means nothing in the pass observes the worker, so
# "nothing landed" and "the worker has not run since Tuesday" are the same silence unless
# the worker's own report is read back and said out loud every pass
# (law-absence-needs-a-positive-control).
# --------------------------------------------------------------------------------------
land_status() {          # land_status <age-seconds> <rc> <branches> <moved>
    printf 'SP_LAND_AT=%s\nSP_LAND_RC=%s\nSP_LAND_BRANCHES=%s\nSP_LAND_MOVED=%s\n' \
        "$(( $(date +%s) - $1 ))" "$2" "$3" "$4" > "$RUN/landing.status"
}

seed; land_status 30 0 4 0; out="$(sentinel)"
# The AGE is not asserted to the second: the fixture is written and the pass then takes
# however long bd takes, so a literal "30s" is a test that fails on a slow box for a reason
# that has nothing to do with the claim. What must be there is that the age is reported.
want "every pass says when landing last ran" "s ago — rc=0" "$out"
want "and how many branches it saw"          "4 branch(es) seen"    "$out"
nowant "a run that saw branches and moved none is not an alarm" "WARN" "$out"

seed; rm -f "$RUN/landing.status" "$RUN/landing.dispatched"; out="$(sentinel)"
want "a host that has never landed says so" "no landing has ever completed" "$out"

# A worker that exits non-zero is a broken landing leg. It reaches the operator, because aeons go on
# closing beads either way and the board reads as healthy while nothing reaches a base branch.
seed; land_status 30 1 4 0; rm -f "$RUN/landing.escalated"; : > "$ASK_LOG"
printf 'landing: gate.sh blew up\n' >> "$RUN/landing.log"
out="$(sentinel)"
want "a worker that exited non-zero is a WARN"  "WARN: the last landing exited 1" "$out"
want "and reaches the operator"                         "Spira is landing nothing" "$(cat "$ASK_LOG")"
want "with the decision's default beside it"    "--default" "$(cat "$ASK_LOG")"
# THE EVIDENCE IS IN THE ASK, not a path to it. the operator answers in a tmux pane and cannot open
# a file from it (law-escalations-carry-their-evidence). This assertion is also the guard on
# a specific mistake already made once here: landing.log is plain text, and `trace_tail` —
# the helper every other escalation in this file uses — renders stream-json and drops every
# line that does not start with `{`, so it returns the empty string and the ask arrives
# looking complete with nothing in it.
want "and carries the worker's own output"      "gate.sh blew up" "$(cat "$ASK_LOG")"
# An escalation says something is STUCK. Counting it as movement would mute the one check
# that notices paralysis, at the worst possible moment.
want   "the escalation is a write" "escalated: the landing leg is not running" "$out"
want   "and not a movement"        "0 progress" "$out"
judged "so it does not mute judgement"

# ...and it is rate limited, because a dead leg stays dead until someone fixes it and a
# check that says so every two minutes is a check the operator learns to scroll past.
: > "$ASK_LOG"; out="$(sentinel)"
is "a second pass does not re-ask" "" "$(cat "$ASK_LOG")"

# A leg that has completed nothing in half an hour, with nothing in flight, is broken even
# though its last completed run was clean. This is the case the status file exists for.
seed; land_status 4000 0 0 0; rm -f "$RUN/landing.escalated"; : > "$ASK_LOG"
out="$(sentinel)"
want "a silent landing leg is caught by its own clock" "and none is running" "$out"
want "and reaches the operator"                                "Spira is landing nothing" "$(cat "$ASK_LOG")"

# ...but not while one is genuinely running. A long landing is slow, not broken.
seed; land_status 4000 0 0 0; rm -f "$RUN/landing.escalated"; : > "$ASK_LOG"
out="$(LAND_STATE=active sentinel)"
nowant "a landing in flight is never called stale" "no landing has completed" "$out"
is     "and nothing is escalated"                  "" "$(cat "$ASK_LOG")"

# --------------------------------------------------------------------------------------
# A dispatch that systemd refuses, with no unit active to explain it, is the failure with no
# other reader: nothing waits on the worker, so a launcher that silently stopped launching
# would leave every finished branch standing and every pass reading clean.
# --------------------------------------------------------------------------------------
seed; rm -f "$RUN/landing.status" "$RUN/landing.escalated"; : > "$ASK_LOG"
out="$(LAUNCH_RC=1 sentinel)"
want "a refused dispatch is a WARN"     "could not dispatch the landing worker" "$out"
want "and reaches the operator"                 "the landing worker will not start" "$(cat "$ASK_LOG")"

# The race is not a failure: the unit went active between the check and the launch.
seed; rm -f "$RUN/landing.escalated"; : > "$ASK_LOG"
out="$(LAUNCH_RC=1 LAND_STATE=active sentinel)"
nowant "a launch lost to a race is not reported as broken" "WARN" "$out"
is     "and is not escalated"                              "" "$(cat "$ASK_LOG")"

# ======================================================================================
# THE STRUCTURAL REGRESSIONS. Both bugs this suite exists for were one word in one line, and
# both can be reintroduced by an edit that reads as a simplification.
# ======================================================================================
gate_line="$(grep -n 'n_open" -gt 0 \] &&' "$HERE/sentinel.sh" | head -1)"
want   "CHECK 8 is gated on progressed" 'progressed" -eq 0' "$gate_line"
nowant "and never on acted"             'acted" -eq 0'      "$gate_line"

# THE EXPENSIVE WORK IS NOT IN THE LOOP, and this is the whole of sp-gatecost. A pass that
# runs a repository's landing gate or fetches from a remote is a pass whose period is set by
# its slowest step, and CHECK 7 — dispatch, about a second — sits below it. Measured before
# the split: 21s for an ordinary pass, 5m30s for one that landed, with a free aeon slot and
# 15 ready beads waiting out the whole of it.
nowant "the sentinel never runs a landing gate" 'gate.sh' "$(cat "$HERE/sentinel.sh")"
nowant "and never fetches from a remote"        'git -C "$repo" fetch' "$(cat "$HERE/sentinel.sh")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
