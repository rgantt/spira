#!/usr/bin/env bash
#
# aeon.sh — summon one aeon from a fayth: claim a bead, work it, close or fail it, exit.
#
#   aeon.sh <fayth>            summon one aeon (no-op if at concurrency cap or no work)
#   aeon.sh <fayth> --dry-run  show what would be claimed, claim nothing
#
# WHY STATELESS AND SHORT-LIVED
# -----------------------------
# Gas Town's agents are long-lived tmux sessions holding mailboxes, and a session that
# dies takes its work with it — nothing else knows what it held. An aeon holds a LEASE
# instead: if it dies, the lease goes stale and `bd reclaim` returns the bead to ready.
# Crash recovery becomes a property of the substrate rather than of the agent.
#
# WHY `bd ready --claim` AND NOT SELECT-THEN-CLAIM
# ------------------------------------------------
# Selecting and then claiming is a race with every other aeon. `--claim` is atomic and is
# the documented primitive; hand-rolling it would be the "read the manual first" mistake.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

FAYTH="${1:-}"; [ -n "$FAYTH" ] || die "usage: aeon.sh <fayth> [--dry-run]"
DRY=0; [ "${2:-}" = "--dry-run" ] && DRY=1
F="$SPIRA_HOME/chamber/$FAYTH.fayth"
[ -f "$F" ] || die "no such fayth: $F"
# shellcheck disable=SC1090
. "$F"

# ---- the fence -----------------------------------------------------------------------
# Bound to the actor that would do the damage. An installation that imported a predecessor's
# beads has a ready queue full of work that predecessor is still doing, and the only thing
# that has ever kept an aeon off them is a config string in a fayth being right. A predicate
# that omits `spira` claims somebody else's work, so refuse to claim at all rather than trust
# the string.
fayth_fenced "$FAYTH" "${FAYTH_LABELS:-}" || die "$FAYTH: refusing to claim behind an unfenced predicate"

# ---- the ledger ----------------------------------------------------------------------
# Two lines per aeon, and the GAP BETWEEN THEM is the measurement. `born` is written within
# milliseconds of exec; `awake` is written once the claim has resolved, which is the first
# thing here that takes real time.
#
# The first aeon this harness ever summoned was killed inside the same second: the sentinel
# service is Type=oneshot with the default KillMode=control-group, so systemd tore down the
# whole cgroup the moment the pass finished, after 1.6s of CPU. The sentinel went on
# reporting "summoned" every two minutes into an empty log, and nothing anywhere counted the
# difference between a summon and a worker. Born-without-awake is that failure and no other,
# which is what makes it a number instead of a story. The cockpit reads it.
#
# Written HERE rather than at the summoning site because aeons arrive from two places — the
# sentinel's CHECK 7 and spira-ops.service — and a ledger kept by one of them would report
# the other's aeons as never having existed.
#
# Append-only, one short line, no locking: O_APPEND is atomic for a write this size, and the
# alternative is an aeon that cannot start because a lock outlived a killed one.
LEDGER="$SPIRA_RUN/aeon-ledger.log"
# A DRY RUN INSPECTS; IT DOES NOT SUMMON. The muzzle lives in the writer rather than at each
# call site because the capacity check sits above the --dry-run branch: an inspection run
# while an aeon is working exits at capacity, so guarding only the birth left a disposition
# with no birth behind it — the born/awake ledger with its two halves swapped, written by
# the one command a human types by hand.
ledger() {
    [ "$DRY" = 1 ] && return 0
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LEDGER"
}
# Bounded here rather than by logrotate: this file is read in full on every cockpit pass,
# and an unbounded input to something that runs every minute is a slow leak with a deadline.
# The -f test is not redundant with wc's own error: `< "$LEDGER"` is the SHELL's redirection
# and it reports a missing file on the shell's stderr, which wc's 2>/dev/null cannot reach.
[ -f "$LEDGER" ] && [ "$(wc -l < "$LEDGER")" -gt 20000 ] \
    && { tail -n 5000 "$LEDGER" > "$LEDGER.trim" && mv -f "$LEDGER.trim" "$LEDGER"; }
ledger "born $FAYTH $$"

# ---- concurrency ---------------------------------------------------------------------
have="$(aeon_count "$FAYTH")"
if [ "$have" -ge "${FAYTH_MAX_CONCURRENT:-1}" ]; then
    log "$FAYTH: at capacity ($have/${FAYTH_MAX_CONCURRENT:-1}), not summoning"
    # A healthy no-op, and it must read as one: an aeon that declined to summon LIVED, it
    # simply had nothing to do. Counting it as stillborn would put a permanent false
    # reading on the panel every time the harness was correctly at capacity.
    ledger "awake $FAYTH capacity"
    exit 0
fi

# ---- the account ----------------------------------------------------------------------
# BOUND HERE AS WELL AS AT summon_fayth, because aeons arrive from two places — the
# sentinel's CHECK 7 and spira-ops.service — and a guard on one of them binds whichever
# caller is most disciplined about using it rather than the one that does the damage
# (law-guard-binds-the-caller). Both doors reach this line; the ready queue is behind it.
#
# Checked BEFORE the claim, never after: the whole point is that no bead is holding a lease
# while the window is shut, so there is nothing to hand back and nothing to charge.
if capacity_paused; then
    log "$FAYTH: the account is out of capacity for another ${SPIRA_CAPACITY_LEFT}s — claiming nothing"
    # LIVED, did not work. Same reading as the concurrency cap above and for the same
    # reason: an aeon that correctly declined is not a stillbirth, and counting it as one
    # would put a false number on the panel for the whole of every outage.
    ledger "awake $FAYTH paused"
    exit 0
fi

# ---- claim ---------------------------------------------------------------------------
# --exclude-type epic: the goal epic is itself "ready" (it has no blockers) and would
# otherwise be claimed and "implemented", which is not a thing an epic means.
claim_args=(ready --claim --limit 0 --exclude-type epic
            --label "$FAYTH_LABELS" --exclude-label "$FAYTH_EXCLUDE_LABELS")

if [ "$DRY" = 1 ]; then
    log "$FAYTH: dry run — candidates:"
    bdq ready --limit 0 --exclude-type epic --label "$FAYTH_LABELS" \
        --exclude-label "$FAYTH_EXCLUDE_LABELS" 2>/dev/null | grep -vE '^💡|^warning|^  Fix|^  Or' | head -10
    exit 0
fi

# THIS AEON'S NAME. Held for the life of the session and written beside its pidfile, so
# the pane, `bd` history and the commit graph all name the same instance.
AEON="$(aeon_name_take "$FAYTH")"
export SPIRA_AEON="$AEON"
export BEADS_ACTOR="aeon-$AEON"
export GIT_AUTHOR_NAME="aeon-$AEON" GIT_AUTHOR_EMAIL="aeon-$AEON@spira.local"
export GIT_COMMITTER_NAME="aeon-$AEON" GIT_COMMITTER_EMAIL="aeon-$AEON@spira.local"
# RESUMPTION BEATS INITIATION. `bd ready --claim` takes the first row, and priority was
# the only ordering — so a bead carrying 21 commits and an open pull request lost to a
# bead with nothing started, twice. That is not untidy, it is expensive: an unfinished
# branch decays, its base moves under it, and every pass it sits costs another rebase.
#
# So look for resumable work FIRST: a ready bead whose recorded branch exists and is ahead
# of its base. Claim that one by id, atomically, with `bd update --claim`. Only when there
# is none do we fall back to taking the head of the queue.
resume_id=""
for cand in $(bdjson ready --limit 0 --exclude-type epic --label "$FAYTH_LABELS" \
                  --exclude-label "$FAYTH_EXCLUDE_LABELS" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in (d if isinstance(d, list) else [d]):
    labs = i.get("labels") or []
    br = next((l[7:] for l in labs if l.startswith("branch:")), "")
    repo = next((l[5:] for l in labs if l.startswith("repo:")), "")
    print("%s|%s|%s" % (i["id"], br, repo))' 2>/dev/null); do
    cid="${cand%%|*}"; rest="${cand#*|}"; cbr="${rest%%|*}"; crepo="${rest##*|}"
    [ -n "$cbr" ] || cbr="spira/$cid"
    croot="$(repo_root "${crepo:-}" 2>/dev/null)" || continue
    [ -d "$croot/.git" ] || continue
    cbase="$(spira_landref "$croot")"
    # Ahead of its base is the test — a branch that exists but adds nothing is not
    # resumable work, it is a leftover.
    n="$(git -C "$croot" rev-list --count "$cbase..$cbr" 2>/dev/null || echo 0)"
    if [ "${n:-0}" -gt 0 ]; then resume_id="$cid"; break; fi
done

if [ -n "$resume_id" ]; then
    claimed="$(bdq update "$resume_id" --claim --json 2>/dev/null | json_only)"
    if [ -n "$claimed" ]; then
        log "$FAYTH/$AEON: resuming $resume_id — it already has work on its branch"
    else
        claimed="$(bdq "${claim_args[@]}" --json 2>/dev/null | json_only)"
    fi
else
    claimed="$(bdq "${claim_args[@]}" --json 2>/dev/null | json_only)"
fi
# THE ID AND THE REPOSITORY, FROM THE SAME PAYLOAD. `bd ready --claim` already handed us
# the bead's labels, so asking the database again for the one it just gave us would be a
# second, racier opinion of the same fact.
read -r BEAD_ID BEAD_REPO <<< "$(printf '%s' "$claimed" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
d = d if isinstance(d, list) else [d]
if not d: sys.exit(0)
repo = next((l[5:] for l in (d[0].get("labels") or []) if l.startswith("repo:")), "")
print(d[0]["id"], repo)' 2>/dev/null)"

if [ -z "${BEAD_ID:-}" ]; then
    log "$FAYTH: nothing ready to claim"
    ledger "awake $FAYTH idle"
    exit 0
fi
log "$FAYTH/$AEON: claimed $BEAD_ID"
ledger "awake $FAYTH $BEAD_ID"

# ---- the workspace -------------------------------------------------------------------
# THE REPOSITORY COMES FROM THE BEAD. A fayth supplies the persona, the statutes and the
# tool allowlist; the bead supplies the workspace, through the same `repo:<name>` partition
# every imported Gas Town bead carries. FAYTH_REPO was a constant per persona and every
# fayth pointed at the home checkout, so the harness could not touch any other
# repositories whose beads it had just spent a design collapsing into one database.
#
# AND AN UNKNOWN NAME IS REFUSED, never defaulted. Falling back to the home repo would put
# one repository's fix on a branch cut in another, and every downstream check would pass it:
# the aeon committed, the commit names the bead, the gate ran, the branch landed. Nothing
# after this point can tell that the work went to the wrong disk, so it has to stop here.
REPO_NAME="${BEAD_REPO:-$(spira_home_repo)}"
if ! REPO="$(repo_root "$REPO_NAME")" || [ ! -e "$REPO/.git" ]; then
    log "$FAYTH: $BEAD_ID names repo:$REPO_NAME, which repo-map does not resolve to a checkout"
    bdq note "$BEAD_ID" "Released by aeon.sh: this bead carries repo:$REPO_NAME, and $SPIRA_REPO_MAP has no entry for it (or its path is not a git checkout). Add one, or correct the label. Refusing to work it in the home repo — a fix landed in the wrong repository passes every check downstream." >/dev/null 2>&1
    bdq unclaim "$BEAD_ID" --if-assignee "$BEADS_ACTOR" >/dev/null 2>&1
    ledger "done $FAYTH $BEAD_ID rc=1 status=unmapped-repo"
    exit 1
fi
REPO_LAND="$(repo_land "$REPO_NAME")"
log "$FAYTH: $BEAD_ID works repo:$REPO_NAME at $REPO (land=$REPO_LAND)"
# THE BRANCH IS A PROPERTY OF THE WORK, RECORDED ON THE BEAD — not a string derived from
# its id (the operator, verbatim: "it seems like there's a needed affinity between bead and
# branch"). Derivation is a convention, and it breaks the moment work outlives the bead
# that began it: sp-pd-ci-green cut its own branch for a deliverable sp-pd-ci-collapse had
# already built, and opened a second pull request for the same nineteen commits.
#
# Recorded, the affinity survives all three cases that matter: an aeon dying and another
# resuming (same bead, same branch); a bead reopened after a failed gate; and work handed
# to a SUCCESSOR bead, which inherits the branch by copying one label rather than starting
# a parallel history.
BRANCH="$(bdq label list "$BEAD_ID" 2>/dev/null | sed -n 's/^ *- branch:\(.*\)$/\1/p' | head -1)"
if [ -z "$BRANCH" ]; then
    BRANCH="spira/$BEAD_ID"
    bdq label add "$BEAD_ID" "branch:$BRANCH" >/dev/null 2>&1
    log "$FAYTH/$AEON: $BEAD_ID takes branch $BRANCH"
else
    log "$FAYTH/$AEON: $BEAD_ID resumes recorded branch $BRANCH"
fi
PIDFILE="$SPIRA_RUN/aeon-$FAYTH-$BEAD_ID.pid"
# DEFINED HERE, ABOVE THE HEARTBEAT, because the heartbeat reads it. It used to be assigned
# beside the session that writes it, 150 lines below the subshell that forks with a copy of
# the environment as it stands HERE — so `stat -c %s "$LOGF"` expanded an unbound variable
# under `set -u` on every beat. That does not kill the beat: the error dies inside the
# command substitution, `now` comes back empty, and empty compares equal to the previous
# empty, so the stall counter read "no progress" on a session doing nothing but progress.
# Every aeon therefore stopped heartbeating after STALL_BEATS beats — 20 minutes — however
# hard it was working; its lease expired, strand.sh reclaimed it as a ghost and BUMPED ITS
# ATTEMPT. That is the same harm this bead is about (an attempt spent on something that is
# not the work's fault) arriving through a second door, and it left 94 `line 257: LOGF:
# unbound variable` lines in the user journal in six hours to say so.
#
# ONE FILE PER BEAD, HELD ACROSS ATTEMPTS, and the heartbeat's growth check is why it is one
# file and not one per attempt: it watches this exact path grow, so a name that changed each
# time would leave it staring at a file nobody writes — which reads as a wedged session and
# costs the bead its lease. Every attempt appends a segment behind a mark line; lib.sh's
# attempt_trace is the only thing that knows how to find the newest one.
LOGF="$SPIRA_RUN/$BEAD_ID.log"
echo $$ > "$PIDFILE"
printf '%s' "$AEON" > "${PIDFILE%.pid}.name"

# THE SEGMENT OPENS HERE, ABOVE THE TRAP AND ABOVE THE HEARTBEAT, and not beside the session
# that fills it. Both of those read the log to decide what is happening NOW, and between this
# line and the session there are three ways to leave — an unresolvable base ref and two
# worktree failures — every one of which lands in the teardown below. With no mark of its own
# yet, this attempt's readers would find the PREVIOUS attempt's segment and answer about it:
# a predecessor refused for want of capacity would make a worktree failure read as a refusal,
# so no attempt would be charged and summoning would pause against an epoch from a session
# that is over. Opening the segment first costs a mark line on an attempt that never ran a
# session, which is worth having anyway — it is the record that the attempt happened at all.
spira_trace_mark "$LOGF" "$AEON" >> "$LOGF"

# ---- teardown ------------------------------------------------------------------------
HB_PID=""
FIXTURE_LIB=""
# THE FIXTURE IS DROPPED FIRST, ahead of every branch below — one of them exits on its own,
# and a teardown that returns before reaching its last step is how a database survives the
# process that owned it. It shares a server with live data, so litter there is never noticed
# until it is a problem.
#
# `TESTDB_SHARED=0` is what makes testdb_drop stop being a no-op: a BORROWER must never drop
# a fixture the lender's other readers are still using, so the owner clears the flag to say it
# is the owner. In a subshell, because the drop is the last thing this fixture is for and
# sourcing the library into the teardown of a supervisor buys nothing.
#
# ONLY A FIXTURE THIS PROCESS BUILT. FIXTURE_LIB is set nowhere but the successful build
# below, so it doubles as the record of ownership — and it has to, because TESTDB_NAME can
# arrive from OUTSIDE: the landing gate exports one shared fixture to everything it runs,
# and a suite under it that summons an aeon would hand that name straight to this function.
# Dropping there would delete the database the rest of the gate's suites are still using,
# mid-run, and every one of them would fail for a reason none of them could name.
fixture_drop() {
    [ -n "${FIXTURE_LIB:-}" ] && [ -n "${TESTDB_NAME:-}" ] || return 0
    # The library is read from the worktree, which an aeon may have deleted or renamed out
    # from under us by the time it exits; the installed copy answers the same question.
    [ -f "$FIXTURE_LIB" ] || FIXTURE_LIB="$SPIRA_HOME/testdb.sh"
    [ -f "$FIXTURE_LIB" ] || return 0
    ( TESTDB_SHARED=0; . "$FIXTURE_LIB" && testdb_drop ) >/dev/null 2>&1
    return 0
}
cleanup() {
    local rc=$? reset_at
    [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null
    fixture_drop
    rm -f "$PIDFILE" "${PIDFILE%.pid}.name"
    cd "$REPO" 2>/dev/null || true
    # If the bead is still ours and still open, hand it back rather than holding a lease
    # nobody is working. Lease expiry would do this eventually; doing it now is honest.
    #
    # `--if-assignee "$BEADS_ACTOR"`, NEVER "aeon-$FAYTH". --if-assignee is a compare-and-swap
    # against the CURRENT holder, and the holder is this aeon's own name — `aeon-mindy`, not
    # `aeon-builder` — because the claim is made under BEADS_ACTOR, which took a per-instance
    # name the day aeons got identities. So the swap compared against a string no bead has
    # ever carried: every release silently no-opped, `bd` exited non-zero into >/dev/null, and
    # the bead sat in_progress until its lease expired and strand.sh ghost-reclaimed it —
    # CHARGING A SECOND ATTEMPT for the release this line was supposed to perform. "Returned
    # unchanged" is not achievable without this: a bead still in_progress has not been
    # returned at all.
    st="$(bdjson show "$BEAD_ID" 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
d=d if isinstance(d,list) else [d]
print(d[0].get("status","") if d else "")' 2>/dev/null)"
    if [ "$st" != "closed" ]; then
        # ASK-AGAIN-LATER IS NOT THIS-BEAD-IS-HARD. A non-zero exit code has meant "the work
        # failed" since the first version of this script, and an attempt is charged on it —
        # but the API refusing to serve the session at all produces the same non-zero exit
        # as a genuine failure, so an outage was being written into the bead as evidence
        # about its work. Attempts poison, so that is permanent state manufactured from a
        # transient condition: a bead touched during an outage must end up exactly where it
        # started. The whole requirement is to wait for capacity to come back without
        # self-imploding in the meantime.
        #
        # capacity_reset_at is deliberately conservative — anything it cannot positively
        # identify as an account refusal falls through to the ordinary path below, so a bead
        # that genuinely fails three times still poisons.
        if reset_at="$(capacity_reset_at "$LOGF")"; then
            capacity_pause_set "$reset_at" "$BEAD_ID"
            bdq unclaim "$BEAD_ID" --if-assignee "$BEADS_ACTOR" >/dev/null 2>&1
            bdq note "$BEAD_ID" "Returned unchanged by aeon.sh: the account's capacity window was spent mid-session, so this bead was never judged. No attempt was charged and nothing about the work is implied. Summoning is paused until the window reopens." >/dev/null 2>&1
            log "$FAYTH: $BEAD_ID returned unchanged — the account ran out of capacity, no attempt charged"
            ledger "done $FAYTH $BEAD_ID rc=$rc status=capacity"
            exit $rc
        fi
        # SLAIN IS NOT FAILED. slay.sh writes this marker before it stops the unit; an
        # operator stopping an aeon says nothing about whether the bead is hard, so no
        # attempt is charged toward poison, the same reading as a spent capacity window.
        if [ -f "$SPIRA_RUN/$BEAD_ID.slain" ]; then
            bdq unclaim "$BEAD_ID" --if-assignee "$BEADS_ACTOR" >/dev/null 2>&1
            log "$FAYTH: $BEAD_ID slain — released, no attempt charged"
            ledger "done $FAYTH $BEAD_ID rc=$rc status=slain"
            exit $rc
        fi
        n="$(bump_attempt "$BEAD_ID")"
        bdq unclaim "$BEAD_ID" --if-assignee "$BEADS_ACTOR" >/dev/null 2>&1
        log "$FAYTH: $BEAD_ID not closed (attempt $n), released"
    fi
    ledger "done $FAYTH $BEAD_ID rc=$rc status=${st:-?}"
    exit $rc
}
trap cleanup EXIT INT TERM

# ---- heartbeat: PROVE WORK, NOT MERE EXISTENCE ---------------------------------------
# An aeon runs until it finishes. There is no wall-clock ceiling, because a clock cannot
# tell SLOW from STUCK: a bead whose CI takes four rounds is not failing, and killing it at
# an arbitrary hour burned an attempt toward the poison threshold for the crime of being
# legitimately long (the operator, verbatim: "why would aeons have a time limit? they should
# exist until they finish their work").
#
# What the timeout was actually guarding is real but narrower: an unconditional heartbeat
# proves the PROCESS is alive, not that WORK is happening, so a wedged session would beat
# forever and hold its lease. So the heartbeat is conditional. It fires only when something
# observably moved — CPU consumed by the session, the worktree touched, or the log grown —
# and when nothing has moved for STALL_BEATS consecutive checks it stops beating. The lease
# then expires on its own and `bd reclaim` returns the bead, which is the substrate's own
# recovery path rather than a second mechanism competing with it.
#
# Waiting on CI is not stalling: polling burns CPU and writes output, so a `gh run watch`
# keeps the beat alive.
STALL_BEATS="${FAYTH_STALL_BEATS:-10}"   # x heartbeat interval; 10 x 120s = 20 min idle
(
    prev=""; idle=0; grants=0
    while sleep "${FAYTH_HEARTBEAT_SECONDS:-120}"; do
        # THE TRACE IS THE SIGNAL. stream-json appends an event per message and per tool
        # call, so a log that has stopped growing is a session that has stopped acting —
        # which is exactly the question, and a far better answer than CPU ticks (a session
        # blocked on an API read burns none) or worktree mtimes (a session can think for
        # minutes without touching a file).
        now="$(stat -c %s "$LOGF" 2>/dev/null || echo 0)"
        if [ "$now" = "$prev" ]; then idle=$((idle+1)); else idle=0; fi
        prev="$now"
        if [ "$idle" -ge "$STALL_BEATS" ]; then
            # SILENCE IS NOT THE SAME AS STUCK. A session blocked on `gh run watch` emits
            # nothing for the whole of a CI run, and killing it there would reopen a bead
            # whose work was minutes from landing. Ask what it was last doing before taking
            # its lease away: pattern first, a small model only if the pattern has no
            # answer. Each reprieve is granted once and re-earned, so a genuinely stuck
            # session cannot buy silence indefinitely — and the reprieves are capped.
            if [ "$grants" -lt "${FAYTH_STALL_GRANTS:-6}" ] && still_waiting "$LOGF"; then
                grants=$((grants+1))
                idle=0
                log "$FAYTH: $BEAD_ID quiet but waiting on \"$(trace_last "$LOGF" | cut -c1-70)\" — extending ($grants/${FAYTH_STALL_GRANTS:-6})"
                continue
            fi
            log "$FAYTH: $BEAD_ID shows no progress for $((idle * ${FAYTH_HEARTBEAT_SECONDS:-120} / 60))m and is not waiting on anything — releasing the lease to the reaper"
            exit 0
        fi
        bdq heartbeat "$BEAD_ID" >/dev/null 2>&1 || exit 0
    done
) & HB_PID=$!

# ---- workspace -----------------------------------------------------------------------
# A WORKTREE, never a checkout in $REPO. The first supervised run checked its branch out
# in the shared tree and moved the interactive session's HEAD out from under it — two
# agents on one working copy, where the second one's next commit lands on the first one's
# branch. A worktree gives the aeon its own directory against the same object store.
WORK="$SPIRA_RUN/worktree/$BEAD_ID"

# THE BASE IS A FRESHLY FETCHED REMOTE-TRACKING REF, NEVER THE LOCAL BRANCH. Nothing in this
# harness advances the shared checkout's default branch — the sentinel lands by pushing from
# the .landing worktree and never pulls the home checkout — so the local ref is however stale
# the last human left it. Every Spira bead edits the same few files under .claude/spira and
# the queue is serialised at one aeon, so a branch cut from that stale ref collides with
# whatever landed while the previous aeon worked, by construction, every time: sp-poison-retry
# was based at 8ed6cca with main already at 5da8438 and conflicted in sentinel.sh, lib.sh,
# gate.sh and log.md, none of which it had touched.
#
# AND IT IS NOT NECESSARILY NAMED `main`. Some repositories default to `master` and
# have no ref named `main` anywhere; the old answer named a branch that does not exist, so
# `git worktree add -b spira/<id> "$WORK" "$BASE"` below failed and NO AEON COULD GET A
# WORKSPACE in either of them. A base that cannot be resolved is fatal rather than guessed —
# working a bead against a branch nobody chose is worse than not working it.
#
# Resolved before the fetch and the fetch aimed at the base's own remote: `git fetch origin`
# was literal here, and a remote need not be called `origin`. The failure is not silent by
# design — a stale base is exactly the defect above, so say so in the log.
BASE="$(spira_landref "$REPO")" || {
    log "$FAYTH: $BEAD_ID names repo:$REPO_NAME, whose land ref cannot be resolved"
    bdq note "$BEAD_ID" "Released by aeon.sh: repo:$REPO_NAME has no resolvable default branch — $SPIRA_REPO_MAP declares no \`base\` for it, its remote publishes no HEAD, and it is not a local-only repository. Give it a base column. Refusing to guess: a branch cut from a guessed base rebases onto a ref nobody chose, and \`main\` is a guess that is wrong wherever a repository still uses \`master\`." >/dev/null 2>&1
    exit 1; }   # the EXIT trap unclaims it and writes the ledger line
BASE_BRANCH="$(ref_branch "$BASE")"
BASE_REMOTE="$(ref_remote "$BASE")" || BASE_REMOTE=""
if [ -n "$BASE_REMOTE" ]; then
    git -C "$REPO" fetch -q "$BASE_REMOTE" 2>/dev/null \
        || log "$FAYTH: fetch of $BASE_REMOTE failed — basing on a possibly stale $BASE"
fi

if [ ! -d "$WORK/.git" ] && [ ! -f "$WORK/.git" ]; then
    mkdir -p "$(dirname "$WORK")"
    # Through the chokepoint. A bare prune drops the registration of any worktree whose
    # `.git` link is unreadable even when the directory is intact and full of work, which
    # frees that branch for deletion and leaves a live tree registered nowhere. Here that
    # tree could be another aeon's, since one prune covers the whole repository.
    spira_prune_worktrees "$REPO" >/dev/null 2>&1
    if git -C "$REPO" show-ref --verify -q "refs/heads/$BRANCH"; then
        # A retry: the branch survives from a previous attempt. Reuse it rather than
        # refusing, and bring it current below.
        git -C "$REPO" worktree add -q "$WORK" "$BRANCH" 2>/dev/null \
            || die "could not attach a worktree at $WORK to existing branch $BRANCH"
    else
        git -C "$REPO" worktree add -q -b "$BRANCH" "$WORK" "$BASE" 2>/dev/null \
            || die "could not create a worktree at $WORK from $BASE"
    fi
fi

# A RETRY inherits whatever base its first attempt was cut from, so a branch created before
# this rule existed — or one that sat while other work landed — is still stale here. Rebase
# it now, while the bead is claimed and nothing else can be inside: the claim is atomic and
# this process is the only holder, so there is no live aeon to rewrite commits beneath.
#
# A conflict is NOT an escalation and NOT a reason to refuse the bead. It is handed to the
# aeon as work, with the colliding paths named, because resolving it is exactly the kind of
# judgement an aeon is for and the alternative is a branch that fails its landing three
# times and poisons a bead nobody needed to look at.
REBASE_BRIEF=""
if ! rebase_branch "$BRANCH" "$BASE" "$REPO" "$REPO_NAME"; then
    log "$FAYTH: $BRANCH does not rebase onto $BASE — conflicts in ${REBASE_CONFLICTS:-unknown}"
    REBASE_BRIEF="## Rebase your branch first

\`$BRANCH\` is behind \`$BASE\` and does not rebase onto it cleanly. It will not land until
it does, so this is part of the bead, not a reason to stop:

    git -C $WORK rebase $BASE

conflicts in: ${REBASE_CONFLICTS:-unknown}

Resolve every conflict, \`git add\` each file, \`git rebase --continue\`, then do the work.
A merge conflict is not an escalation — do not close the bead and do not ask about it.
"
fi

# ---- one test fixture for the whole session -------------------------------------------
# WAITING ON TESTS WAS 43% OF A SESSION'S WALL CLOCK and 73% of its tool time, and the
# suites here are not CPU-bound, they are database-bound: `bd init` is nearly all of the
# ~27s (55s under load) each suite spends building its fixture. The landing gate already
# builds ONE and lets every suite reset it instead — 0.2s — but an aeon running suites by
# hand got none, so each of its ~15 single-suite runs paid the full build.
#
# So the aeon builds one too, here, once, and exports it into the session. Every Bash call
# the session makes inherits it, which is the whole mechanism: a suite that sources the
# fixture library sees TESTDB_SHARED and resets rather than rebuilds, with no argument to
# pass and nothing for the session to remember (law-gate-once-fixture-shared).
#
# BUILT FROM THE WORKTREE'S OWN COPY, not the installed one. The tree whose suites will
# consume the fixture is the tree that should build it — the same rule the landing gate
# follows — so a bead that changes what a baseline means changes both halves together.
# A repository with no such file gets no fixture and no error; that is what decides which
# repositories this applies to, rather than a list of names.
#
# AND ALWAYS ITS OWN. Whatever the caller had is cleared before anything else, and only what
# this aeon builds is put back — the landing gate exports one shared fixture to everything it
# runs, so a suite under it that summons an aeon hands that database straight through. Passed
# on, the session would reset a database it does not own, mid-run, while the caller's own
# suites were still reading it, and every one of them would fail for a reason none could name.
# TESTDB_HOST and TESTDB_PORT survive on purpose: those are the server's coordinates, not the
# fixture's identity, and a caller that named a different server means it.
#
# THE COST IS ONE BUILD PER SESSION, PAID EVEN BY A BEAD THAT RUNS NO TESTS, and the log
# line below is the meter that says when that stops being a good trade (the number to watch
# is this build against the count of suite runs in the session's own trace).
unset TESTDB_SHARED TESTDB_NAME TESTDB_DIR TESTDB_BASELINE
fixture_ms=0
if [ -f "$WORK/$SPIRA_TESTDB_LIB" ]; then
    fixture_err="$(mktemp)"
    fixture_t0="$(date +%s%3N)"
    # A subshell, so the fixture library's functions never enter the supervisor: this is
    # branch code, and aeon.sh is the process that decides whether the branch's bead may be
    # reclaimed. The five values it prints are the whole interface.
    fixture_out="$(
        . "$WORK/$SPIRA_TESTDB_LIB" && testdb_up "aeon${BEAD_ID//[^a-zA-Z0-9]/}" >&2 &&
        printf '%s\n%s\n%s\n%s\n%s\n' \
            "$TESTDB_NAME" "$TESTDB_DIR" "$TESTDB_BASELINE" "$TESTDB_HOST" "$TESTDB_PORT"
    )" 2>"$fixture_err"
    fixture_ms=$(( $(date +%s%3N) - fixture_t0 ))
    if [ -n "$fixture_out" ]; then
        { read -r TESTDB_NAME; read -r TESTDB_DIR; read -r TESTDB_BASELINE
          read -r TESTDB_HOST; read -r TESTDB_PORT; } <<< "$fixture_out"
        export TESTDB_SHARED=1 TESTDB_NAME TESTDB_DIR TESTDB_BASELINE TESTDB_HOST TESTDB_PORT
        FIXTURE_LIB="$WORK/$SPIRA_TESTDB_LIB"
        log "$FAYTH: $BEAD_ID shares one test fixture $TESTDB_NAME, built in ${fixture_ms}ms"
    else
        # A FIXTURE THAT WILL NOT BUILD IS NOT A REFUSAL TO WORK. The suites fall back to
        # building their own, which is slow and correct; what must not happen is a bead going
        # unworked because a database server was busy. The reason is logged rather than
        # swallowed, because "slower than it should be" is otherwise invisible.
        log "$FAYTH: $BEAD_ID has no shared test fixture — its suites will each build their own: $(tail -3 "$fixture_err" | tr '\n' ' ')"
    fi
    rm -f "$fixture_err"
fi

# ---- prompt --------------------------------------------------------------------------
# HOW THIS BRANCH LANDS IS PART OF THE BRIEF. An aeon that believes its commit goes straight
# to main writes a different commit from one that knows a reviewer and a CI run stand
# between them, and the harness knows which is true because repo-map says so. Kept to one
# line: brief bloat is compensation for missing context, and this is the context.
case "$REPO_LAND" in
    pr)   LANDING_BRIEF="the sentinel pushes \`$BRANCH\` and opens a pull request against \`$BASE_BRANCH\`; $REPO_NAME's own CI is the gate, so write the commit for a reviewer" ;;
    hold) LANDING_BRIEF="Spira does not advance $REPO_NAME's \`$BASE_BRANCH\`, so the sentinel gates \`$BRANCH\` and leaves it for the operator to merge by hand" ;;
    *)    LANDING_BRIEF="the sentinel merges \`$BRANCH\` into \`$BASE_BRANCH\` and pushes it once the landing gate passes — there is no reviewer between your commit and \`$BASE\`" ;;
esac
# WHETHER THERE IS ANYTHING TO WAIT FOR IS ALSO PART OF THE BRIEF, and the same fact decides
# it. Only `pr` opens a pull request; `push` merges the branch itself and `hold` leaves it for
# a human, so in both of those the landing gate is the only gate and a park waits for an event
# that cannot occur. Because the park label is excluded from every persona's predicate AND
# from the stranded-work report — which is what stops parked work looking abandoned — such a
# park is not merely wrong, it is invisible: not claimable, not reported, and shown to the
# operator as "in CI", the one description that stops anybody looking for the real cause. One
# bead reached 22 reclaims that way, not one of them a work failure.
#
# The sweep strips a park no run can end, so this is not the guard — it is the brief that
# stops it being applied in the first place. A rule delivered only as prose is a resolution;
# the mechanism is in the sweep, and both exist because they fail differently.
if [ "$REPO_LAND" = pr ]; then
    PARK_BRIEF="## Your lifetime: do the work, cut the review, then exit

**Do not sit and watch CI.** An Opus session idling for twenty-five minutes while a test
suite runs is the most expensive way to wait that exists. When your work is pushed and its
pull request is open, your job is done for now — exit cleanly and let the harness bring the
bead back when there is something to decide.

What makes that safe is the bead, not your memory of it. Before you exit:

- push your branch, and open or update its pull request
- label the bead \`$SPIRA_CI_LABEL\` — that is the harness's signal that this is parked ON
  PURPOSE and not abandoned, so it is not treated as stalled work
- leave the bead OPEN with a note saying what state it is in and what should happen when
  the run finishes

The sweep then watches that pull request for you. Green and mergeable, it lands and closes
the bead. Red, it clears the label and raises the priority so the next aeon picks the bead
up to fix it — and that aeon is you-in-effect: same bead, same recorded branch, all your
commits, the failure waiting to be read.

A park is not open-ended. One older than \`SPIRA_CI_PARK_MAX\` (${SPIRA_CI_PARK_MAX}s) is
treated as lost rather than parked: the sweep takes the label off and the bead goes back into
the stranded-work report, because a park nothing is watching must not be the one state that
hides a bead from the report that would have found it."
else
    PARK_BRIEF="## Your lifetime: do the work, then exit

**There is no CI run to wait for in this repository.** $REPO_NAME lands by \`$REPO_LAND\`, so
nothing opens a pull request for \`$BRANCH\` and no run will ever report on it. The landing
gate is the only gate, and once it passes there is nothing further to wait for.

**So do not label the bead \`$SPIRA_CI_LABEL\`.** That label means \"parked on a run somebody
else is watching\", and it excludes the bead from every persona's predicate and from the
stranded-work report — the two mechanisms that would otherwise notice the work had stopped.
Applied where no run exists it is a permanent, invisible hold: not claimable, not reported,
and shown to the operator as \"in CI\", which is the one description that stops anybody
looking for the real cause. The sweep strips such a park; do not make it have to.

When the work is committed on your branch, close the bead with its evidence and exit. How the
branch reaches \`$BASE_BRANCH\` from there is described above, and none of it needs you."
fi

# WHAT THIS SESSION IS ACTUALLY HOLDING. The brief is read by aeons working every repository
# and most of them have no fixture library at all, so a persona that stated flatly "your
# fixture is already built" would be wrong more often than right — and an instruction that is
# visibly false about something checkable is a reason to distrust the rest of the brief.
if [ -n "$FIXTURE_LIB" ]; then
    FIXTURE_BRIEF="**The fixture is already built.** One throwaway database was created for this
session and exported into your environment (\`TESTDB_SHARED=1\`, \`TESTDB_NAME=$TESTDB_NAME\`),
so a suite that sources \`$SPIRA_TESTDB_LIB\` and calls \`testdb_up\` resets it in a fraction of
a second instead of spending the ${fixture_ms}ms that build cost. Never unset those variables
and never build a database of your own: a suite that reaches past \`testdb_up\` pays the build
again on every run, and nothing anywhere reports that it did."
else
    FIXTURE_BRIEF="This repository has no shared test fixture, so a suite that needs one builds
its own. If that turns out to be the slowest thing in your session, say so when you close the
bead — the number is worth having."
fi

BEAD_BODY="$(bdq show "$BEAD_ID" 2>/dev/null | grep -vE '^💡|^warning|^  Fix|^  Or')"
PROMPT="$(sed -e "s|{{BEAD_ID}}|$BEAD_ID|g" -e "s|{{BRANCH}}|$BRANCH|g" \
              -e "s|{{REPO}}|$WORK|g" -e "s|{{REPO_NAME}}|$REPO_NAME|g" \
              -e "s|{{LANDING}}|$LANDING_BRIEF|g" -e "s|{{DB}}|$SPIRA_DB|g" \
              "$SPIRA_HOME/chamber/$FAYTH.md")"
# PARAMETER EXPANSION, NOT sed, for the two multi-line substitutions. `s|{{X}}|<many lines>|`
# is not a thing sed will do, and a brief that silently rendered as the literal `{{PARK}}`
# would leave an aeon with no instruction at all about how its work is meant to end.
PROMPT="${PROMPT/\{\{BEAD\}\}/$BEAD_BODY}"
PROMPT="${PROMPT/\{\{PARK\}\}/$PARK_BRIEF}"
PROMPT="${PROMPT/\{\{FIXTURE\}\}/$FIXTURE_BRIEF}"

# The memory book. Every agent reads it on every session; this is the delivery mechanism
# for an aeon, standing in for the SessionStart hook an interactive session gets.
#
# WHICH book is the fayth's to declare. Statutes (`law-`) are how to behave and everyone
# reads them; SOPs (`sop-`) are how to fix and only Ops executes one. Without the filter a
# growing shelf of runbooks would be charged to every builder session and would eventually
# crowd out the law itself.
#
# This used to be `bd memories | head -400`, which was wrong twice over: `bd memories` is a
# LISTING and truncates every body at ~110 characters, so aeons have been reading
# half-sentences of the law they are held to, and the `head` then dropped whichever
# memories sorted last without saying so. render_memories reads the JSON and prints each
# one whole.
STATUTES="$(render_memories "${FAYTH_MEMORY_PREFIXES:-law-}")"
# THE LAST STEP BEFORE CLOSING IS A REBASE, AND IT IS THE AEON'S. The landing pass rebases
# too, but it cannot resolve a conflict — it reopens the bead and hands the conflict to the
# NEXT aeon, which arrives with none of the context that wrote the commits. With several
# aeons landing, the base moves between an aeon's close and its landing by construction, and
# 12 of the first 23 reopens this harness performed were exactly that. The session that
# holds the context is the one that should pay for the conflict, so it is told to, and the
# verdict step below checks that it did.
CLOSE_BRIEF="## Before you close: rebase onto \`$BASE\`

Other aeons land while you work, so \`$BASE\` has probably moved. The last thing you do
before closing the bead — after your commits, before the close — is:

    git -C $WORK fetch ${BASE_REMOTE:-origin}
    git -C $WORK rebase $BASE

Resolve any conflict yourself: you wrote these commits and you know what they mean, and the
landing pass does not — it would reopen the bead and hand the conflict to a stranger. Then
run the gate once more on the rebased tree, and close. A bead closed behind \`$BASE\` that
does not rebase cleanly is reopened by the harness, which costs a whole second session."

FULL="# Memories in force

$STATUTES

---

$PROMPT
$CLOSE_BRIEF
$REBASE_BRIEF"

# ---- work ----------------------------------------------------------------------------
# APPEND, NEVER TRUNCATE — see attempt_trace in lib.sh. A `>` here erased the previous
# attempt's trace, so a bead only ever had a record of its last session; the mark line
# written when this attempt began is what lets every reader still find where the last
# session starts.
log "$FAYTH: working $BEAD_ID on $BRANCH (log: $LOGF)"
set +e
cd "$WORK" || die "worktree missing: $WORK"
# No `timeout` here. A backstop remains available as FAYTH_TIMEOUT_SECONDS for a fayth that
# genuinely wants one, but it is unset by default: the stall detector above is what ends a
# wedged session, and it ends it by ceasing to heartbeat rather than by killing work that
# might be nearly done.
# STREAM THE SESSION: the log is a live trace, not a buffered dump (the operator, verbatim:
# "one way to gauge liveness of a claude session is to ensure it launches with full tracing
# and then watch the trace"). With the default text format nothing reaches the log until
# the session ends — a run was observed at 0 bytes eight minutes in — so the log could not
# answer "is it working". stream-json emits an event per message and per tool use, which
# makes the log the authoritative progress signal and lets the heartbeat stop guessing from
# CPU ticks and file mtimes.
# THE BINARY IS INJECTABLE, like `bd`, `gh` and `systemd-run` before it, and for the same
# reason: it is the one thing a test of this path must be able to replace. And a PATH shim
# CANNOT do it — conf.sh REPLACES $PATH outright a few lines into this script, so a suite
# that puts a fake `claude` first on PATH runs the real model against the operator's account,
# silently and at full cost. That is not hypothetical; it is how this line came to be
# written. A test overrides SPIRA_CLAUDE.
printf '%s' "$FULL" | ${FAYTH_TIMEOUT_SECONDS:+timeout $FAYTH_TIMEOUT_SECONDS} \
    "${SPIRA_CLAUDE:-claude}" -p --output-format stream-json --verbose --include-partial-messages \
           --model "${FAYTH_MODEL:-claude-opus-5}" \
           --allowedTools "${FAYTH_TOOLS:-Bash,Read,Edit,Write,Glob,Grep}" \
           --dangerously-skip-permissions \
    >> "$LOGF" 2>&1
rc=$?
set -e
log "$FAYTH: $BEAD_ID session exited rc=$rc"

# ---- verdict -------------------------------------------------------------------------
# Closed is not landed. The aeon may have closed the bead; that claim is only believed if
# a commit on its branch actually names the bead id.
st="$(bdjson show "$BEAD_ID" 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
d=d if isinstance(d,list) else [d]
print(d[0].get("status","") if d else "")' 2>/dev/null)"
# NEVER `git log | grep -q` under `set -o pipefail`. grep -q exits on the first match and
# closes the pipe; git log then dies of SIGPIPE and pipefail propagates 141 as the
# pipeline's status, so a MATCH reads as a failure. This exact line reported "closed with
# nothing committed" about sp-epic-complete, whose commit was already on the branch, and
# reopened finished work. Capture first, match second.
subjects="$(git -C "$REPO" log --format='%s%n%b' -n 50 "$BRANCH" 2>/dev/null)"
if grep -qF "$BEAD_ID" <<< "$subjects"; then committed=yes; else committed=no; fi
log "$FAYTH: $BEAD_ID status=$st committed=$committed"

if [ "$st" = "closed" ] && [ "$committed" = "no" ]; then
    bead_reopen "$BEAD_ID" "Reopened by aeon.sh: closed without a commit naming $BEAD_ID on $BRANCH. Closed is not landed."
    log "$FAYTH: $BEAD_ID REOPENED — closed with nothing committed"
fi

# CLOSED BEHIND THE BASE IS NOT FINISHED. The brief asked for a rebase as the last step; this
# is the check that it happened, and the fallback when it did not. The session is over, the
# claim is still this process's, so rewriting the branch here rewrites nothing beneath
# anyone. Three outcomes, each named in the log so the brief's effect can be measured:
#   current  — the session rebased (or nothing landed meanwhile); nothing to do
#   rebased  — it did not, but the replay was clean; the harness did it and says so
#   reopened — it did not, and the replay conflicts; the next aeon is handed the rebase
#              with the paths named, exactly as the landing pass would have, only sooner
if [ "$st" = "closed" ] && [ "$committed" = "yes" ]; then
    if [ -n "$BASE_REMOTE" ]; then
        git -C "$REPO" fetch -q "$BASE_REMOTE" 2>/dev/null \
            || log "$FAYTH: fetch of $BASE_REMOTE failed — judging currency against a possibly stale $BASE"
    fi
    if git -C "$REPO" merge-base --is-ancestor "$BASE" "refs/heads/$BRANCH" 2>/dev/null; then
        log "$FAYTH: $BEAD_ID closed current with $BASE"
    elif rebase_branch "$BRANCH" "$BASE" "$REPO" "$REPO_NAME"; then
        log "$FAYTH: $BEAD_ID closed behind $BASE — rebased by the harness after close (the session did not)"
        bdq note "$BEAD_ID" "Rebased onto $BASE by aeon.sh after the session closed the bead without doing so. The replay was clean; the landing gate judges the rebased tree." >/dev/null 2>&1
    else
        bead_reopen "$BEAD_ID" "Reopened by aeon.sh: closed behind $BASE and $BRANCH does not rebase onto it — conflicts in ${REBASE_CONFLICTS:-unknown}. The brief asked for this rebase before closing. A merge conflict is not an escalation — the next aeon is handed the rebase and must resolve it."
        log "$FAYTH: $BEAD_ID REOPENED — closed behind $BASE, conflicts in ${REBASE_CONFLICTS:-unknown}"
    fi
fi
