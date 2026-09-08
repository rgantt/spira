#!/usr/bin/env bash
#
# sentinel.sh — the outer harness: compare current state to goal state, close the gap.
#
#   sentinel.sh          one pass (this is what the timer runs)
#   sentinel.sh --report print the gap, change nothing
#
# THE SHAPE (the operator's call)
# --------------------------------
# "look at the current state, the goal state, reflect on the gap between those states, and
# then take necessary actions to close that gap ... cheap, quick, and frequent to run with
# deterministic heuristics; drop down to inference when judgement is required."
#
# So every check below is a deterministic predicate over beads and the commit graph, and
# each names the single action that closes its gap. Inference is reached only by the LAST
# check, and only when the deterministic ones have all passed and the DAG is nevertheless
# not moving — which is precisely the case where there is no rule to apply, because if
# there were a rule it would already be one of the checks above.
#
# Adding a check is how this system learns: a stall we diagnose by hand once becomes a
# deterministic check, and inference stops being asked about it. Inference is a cost
# centre, not a feature.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

REPORT=0; [ "${1:-}" = "--report" ] && REPORT=1
POISON_AT="${SPIRA_POISON_AT:-3}"
# THERE IS NO $REPO HERE ANY MORE, and that is the point of this bead. The repositories
# this harness lands into are plural and come from repo-map, because a bead now names its
# own through a `repo:` label; a single module-level $REPO is exactly the constant that
# made Spira able to work one repository out of seven. `spira_repos` enumerates them and
# every check that touches a commit graph asks which one it is standing in. SPIRA_REPO
# still names the HOME repository, so the suite can drive the whole harness against a
# fixture with a real origin — the landing path was once the one part no test could reach.
# Every persona in the chamber, not a hardcoded name. A default of `builder` meant a fayth
# could land complete and never once be evaluated — ops.fayth shipped inert that way on
#. SPIRA_FAYTHS still overrides, because which personas a HOST runs is deployment
# configuration; what it must not be is the only thing that makes a persona exist.
FAYTHS="$(spira_fayths)"
# THE PARTITIONS THIS PASS SWEEPS, read from the chamber once. Every check below that asks
# the database a question about "the work" asks it once per partition: naming one of them —
# `spira,plan`, the builder's — is how reaping, stalled-work reporting and landing
# verification came to watch a single persona while reading as if they watched the harness.
PARTITIONS="$(fayth_partitions)"
COOLDOWN="$SPIRA_RUN/inference.cooldown"
INFERENCE_EVERY="${SPIRA_INFERENCE_EVERY:-3600}"   # seconds; judgement is expensive

# TWO COUNTERS, BECAUSE THEY ANSWER DIFFERENT QUESTIONS.
# `acted`      — a write happened. Used only for the pass summary.
# `progressed` — the DAG actually MOVED: a bead changed status, or a branch landed.
#
# CHECK 8 gates on `progressed` and must NEVER gate on `acted`. Gating judgement on "did
# anything write" makes every false or futile action a mute button on the one check that
# notices paralysis — and the failure is not hypothetical or rare, it is structural:
# CHECK 3's precondition (0 ready, 0 in progress, work open) IS CHECK 8's precondition,
# and `bd recompute-blocked` exits 0 whether or not it changed a flag. So a starved
# harness wrote, counted an action, and silenced its own judgement tier on EVERY pass.
# Measured: 76 passes, judgement fired zero times (SP_SINCE_JUDGEMENT='>76').
acted=0        # a write happened
progressed=0   # the DAG moved
act()      { acted=$((acted+1)); log "ACT $*"; }
progress() { progressed=$((progressed+1)); act "$@"; }

# ======================================================================================
# STATE
# ======================================================================================
open_children="$(goal_open_children)"
n_open="$(printf '%s' "$open_children" | grep -c . || true)"
# THE PLAN'S numbers, and they are named that way deliberately. These two feed CHECK 3 and
# CHECK 8, both of which reason about the DAG under $SPIRA_GOAL, so the plan predicate is
# the right one for them and the WRONG one for anything else. Reading an unqualified `ready`
# as "is there work" is what made CHECK 7 gate every persona on the builder's partition.
# Whether a persona has work is fayth_ready, asked per fayth, in CHECK 7.
plan_ready="$(ready_count spira,plan "spira-poison,$SPIRA_ASK_LABEL")"
plan_inprog="$(bdjson list --status in_progress --limit 0 --label spira,plan | json_count)"
live=0; for f in $FAYTHS; do live=$((live + $(aeon_count "$f"))); done

log "state: goal=$SPIRA_GOAL open=$n_open plan_ready=$plan_ready in_progress=$plan_inprog aeons=$live fayths=[$FAYTHS]"

# A NARROWED ROSTER SAYS SO, EVERY PASS (roster_warnings, in lib.sh).
roster_warnings "$FAYTHS"

if [ "$REPORT" = 1 ]; then
    printf '\nOpen beads under %s:\n' "$SPIRA_GOAL"
    printf '%s\n' "$open_children" | sed 's/^/  /'
    exit 0
fi

# ======================================================================================
# CHECK 1 — completed pilgrimages. An epic whose children have all closed is done: announce
# it to its subscribers, then close it. This is `gt convoy check` plus `gt convoy watch`
# rebuilt on epic beads; pilgrimage.sh holds the detection, the watcher list and the manual
# entry points (`pilgrimage.sh list|watch|unwatch`).
#
# The announcement the operator sees is an EVENT — a closed `event` bead of kind
# `pilgrimage.complete`, emitted through `ask.sh note`. Machinery writes outcomes, never
# insights: an insight is what an agent LEARNED and might become law, and mixing outcomes
# into that queue is how the one bin that survived a refresh filled with completion notices.
#
# Generalised past $SPIRA_GOAL deliberately. The goal epic is only one pilgrimage, and a
# harness that can announce exactly one of them announces nothing the moment a second
# design is in flight — which is the state Gas Town was in with six convoys open.
# ======================================================================================
completed="$("$SPIRA_HOME/pilgrimage.sh" check 2>&1)"
[ -n "$completed" ] && printf '%s\n' "$completed"
n_done="$(printf '%s' "$completed" | grep -c '^PILGRIMAGE COMPLETE' || true)"
[ "${n_done:-0}" -gt 0 ] && progress "announced and closed $n_done completed pilgrimage(s)"

GOAL_REACHED=0
if [ "$n_open" -eq 0 ]; then
    # NOT an early exit. The last bead of a pilgrimage is the one whose branch is most
    # likely to be sitting unlanded and uncleaned, because it closes in the same pass that
    # would have tidied it — so returning here is how a finished pilgrimage leaves a branch,
    # a worktree, and possibly a closed-but-unlanded bead behind it forever. Everything up
    # to CHECK 6b still applies with nothing open, and so does SUMMONING: whether a persona
    # has work is its own predicate's answer, not the plan's. Ops receives production events
    # from outside the plan entirely, so exiting here because a design finished is exactly
    # the "unreachable by construction" defect. Only JUDGEMENT does not apply, and CHECK 8
    # already declines to run with nothing open.
    log "goal reached — $SPIRA_GOAL has no open children; finishing the sending"
    GOAL_REACHED=1
fi

# ======================================================================================
# CHECK 2 — dead workers. A lease outlives the aeon that took it; reclaim is the reaper.
# Grace window ~2x the TTL so a briefly paused worker is not robbed of live work.
# ======================================================================================
# Match the SUCCESS shape, not the word. The first version counted lines containing
# "reclaim", which matches the success message AND the idle message "No stale leases to
# reclaim in the filtered scope" — so every pass reported an action it had not taken. That
# is a false alert, and it was not merely noise: `acted` was never 0, so CHECK 8 could
# never fire and the harness could never notice it was starved.
#
# ONE RECLAIM PER PARTITION, ASKED THROUGH THE CHAMBER. This named `spira,plan` — the
# builder's partition standing in for every persona — so an ops or spike aeon that died left
# its bead in_progress with a dead lease and no time-based reaper ever looked at it. The
# /proc ghost sweep in CHECK 2b catches that case faster in practice, but the backstop for
# everything /proc cannot see did not exist for those partitions at all.
n_parts=0; n_reclaimed=0
while IFS=$'\t' read -r part _; do
    [ -n "$part" ] || continue
    n_parts=$((n_parts+1))
    out="$(bdq reclaim --older-than 180m --label "$part" 2>&1)"
    grep -q 'No stale leases' <<< "$out" && continue
    n="$(grep -cE '^(✓|Reclaimed)' <<< "$out" || true)"
    n_reclaimed=$(( n_reclaimed + ${n:-0} ))
done <<< "$PARTITIONS"
# A REAPER WITH NOTHING TO REAP OVER SAYS SO. With no partition declared this writes nothing
# and returns clean, which reads exactly like a harness with no dead leases.
[ "$n_parts" -eq 0 ] && log "CHECK2 no persona in the chamber declares a partition — no lease is being reaped"
[ "$n_reclaimed" -gt 0 ] && progress "reclaimed $n_reclaimed stale lease(s)"

# ======================================================================================
# CHECK 2b — stranded work. This is `gt convoy stranded` rebuilt, and it sits here because
# its ghost case is a faster, evidence-based version of CHECK 2: reclaim above is a time
# heuristic about liveness it cannot observe, while strand.sh asks /proc whether the aeon
# that took the lease still exists. A bead in_progress with a dead holder is reclaimed in
# minutes rather than at the three-hour grace window.
#
# It acts where the fix is mechanical and escalates ONCE where it is not, so it neither
# retries forever nor pages the operator every two minutes. `strand.sh report` is the human view.
# ======================================================================================
stranded="$("$SPIRA_HOME/strand.sh" check 2>&1)"
[ -n "$stranded" ] && printf '%s\n' "$stranded"
n_strand="$(grep -cE '^(RECLAIMED|RECOMPUTED|STRANDED)' <<< "$stranded" || true)"
n_moved="$(grep -cE '^RECLAIMED' <<< "$stranded" || true)"
n_escal="$(grep -cE '^STRANDED' <<< "$stranded" || true)"
# A reclaim moved the DAG; an escalation only wrote. A standing escalation that never
# clears would otherwise count as an action on every pass and mute judgement forever.
[ "${n_moved:-0}" -gt 0 ] && progress "handled $n_moved stranded item(s)"
[ "${n_escal:-0}" -gt 0 ] && act "escalated $n_escal stranded item(s)"
# The counts above are deliberately not recomputed. A reclaimed ghost becomes ready, and the
# next pass — two minutes away — summons for it; re-querying here would duplicate three
# queries to save that.

# ======================================================================================
# CHECK 2c — orphaned claims. The third dead-worker case, and the one neither check above
# can see: a bead that is OPEN, carries an assignee, and holds no lease.
#
# CHECK 2 reverts stale-lease in_progress issues and CHECK 2b witnesses a dead holder of
# one. Both are about a lease. This is about a bead whose STATUS was already reset — by a
# reopen in the landing pass, in CHECK 5, or in the aeon's own closed-without-a-commit
# check — while its assignee was left standing. `bd ready` counts such a bead and `bd ready
# --claim` skips it, so it is ready forever and claimable never, and no lease ever expires
# to rescue it. Thirteen plan beads were stuck this way on 2026-09-06 while CHECK 7 summoned
# an aeon every two minutes to report idle within one second.
#
# bead_reopen and release_own_claim now write the two facts together, so this should find
# nothing. It stays because it is the POSITIVE CONTROL on that claim: a path that ends a
# claim without clearing it is a bug that presents as a healthy queue, and this sweep is
# what turns that silence into a visible RELEASED line
# (law-absence-needs-a-positive-control).
# ======================================================================================
released="$(release_orphan_claims "spira,plan")"
[ -n "$released" ] && printf '%s\n' "$released"
n_rel="$(grep -c '^RELEASED' <<< "$released" || true)"
if [ "${n_rel:-0}" -gt 0 ]; then
    progress "released $n_rel orphaned claim(s)"
    # Every bead the sweep freed is claimable NOW, so the count CHECK 3 and CHECK 8 reason
    # about is stale by exactly this much. Re-queried only when something actually moved.
    plan_ready="$(ready_count spira,plan "spira-poison,$SPIRA_ASK_LABEL")"
fi

# ======================================================================================
# CHECK 3 — stale blocked flags. is_blocked is a cached column and goes wrong after an
# import or a pull; a whole DAG can sit "blocked" behind dependencies that all closed.
# ======================================================================================
if [ "$plan_ready" -eq 0 ] && [ "$plan_inprog" -eq 0 ] && [ "$n_open" -gt 0 ]; then
    bdq recompute-blocked >/dev/null 2>&1
    was="$plan_ready"
    plan_ready="$(ready_count spira,plan "spira-poison,$SPIRA_ASK_LABEL")"
    # LOG it always, COUNT it only when it changed something. recompute-blocked exits 0
    # either way, so trusting its exit status made this check fire on exactly the state
    # CHECK 8 exists to detect, and mute it — every pass, for 76 passes.
    log "recomputed is_blocked"
    [ "$plan_ready" != "$was" ] && progress "recompute-blocked freed $plan_ready bead(s)"
fi

# ======================================================================================
# CHECK 4 — poison. A bead that has failed N times is not retried again; retrying it is
# how one bad bead burns tokens forever. This is mountain's skip-after-N-failures, and it
# is the property most likely to be lost silently, because nothing complains when it is
# missing.
#
# IT ITERATES WHAT THE SUMMONER CAN DISPATCH, never the goal epic's children. Those are two
# different sets and the gap between them is unpoisonable work: a bead carrying a partition's
# labels but parented outside $SPIRA_GOAL was summoned every pass, failed every time, and
# never reached the valve. dispatchable_open carries the whole argument.
#
# THE POISONED BEAD KEEPS ITS CLAIM. If a live aeon holds it, unclaiming here would cut the
# lease out from under a session that is still writing — and the aeon releases on its own
# exit path anyway. Labelling is sufficient: every fayth's partition excludes spira-poison,
# so the moment the holder lets go, CHECK 7 stops summoning for it.
# ======================================================================================
dispatchable="$(dispatchable_open)"
log "CHECK4 examining $(printf '%s' "$dispatchable" | grep -c . || true) dispatchable bead(s), threshold $POISON_AT"
for id in $dispatchable; do
    # ONLY sp-attempt-N IS READ HERE. The other counters a bead accumulates — a reclaim for
    # each worker that died holding it, a requeue for each time the harness put finished work
    # back — are diagnostic, and lib.sh says so where they are defined. That is invisible from
    # a bead's label set, which shows one undifferentiated run of counters beside the poison
    # label, so a bead carrying six reclaims and no attempt reads as poisoned-by-reclaims and
    # has been reported as a second poison door. It is not one: it cannot reach this line.
    n="$(attempts_of "$id")"; n="${n:-0}"
    [ "$n" -ge "$POISON_AT" ] || continue

    # A CLOSED BEAD NEVER POISONS AND NEVER ASKS. dispatchable_open excludes closed beads,
    # but it is a SNAPSHOT and this loop makes several bd calls per bead — so a bead the
    # landing pass finished a few seconds ago is still in the list, and the operator was
    # asked whether to change the approach on work that had already landed. Re-read the one
    # field that decides it, immediately before acting on it.
    if [ "$(spira_bead_status "$id")" = closed ]; then
        log "CHECK4 $id: $n attempts, but it closed while this pass ran — not poisoned, not asked"
        continue
    fi

    # THE POISON NAMES THE OUTCOMES THAT CHARGED IT, never just their count. A poison nobody
    # can audit takes a bead out of circulation for reasons that have already scrolled away,
    # and "three attempts" is only a reason to stop if all three were the work failing. Rungs
    # predating the cause label read `unrecorded`, which is honest rather than an assumption
    # about what they were.
    charges="$(attempt_causes "$id" | awk '{printf "%s#%s ", $1, $2}')"

    # Read the labels ONCE into a variable and match with a case. `... | grep -q` under
    # `set -o pipefail` hands back 141 when it MATCHES — grep exits at the first hit and the
    # writer dies of SIGPIPE — so `if ! ... | grep -q spira-poison` read as "not poisoned"
    # precisely when the bead was, and re-labelled and re-asked on a pass that should have
    # done nothing (law-no-grep-q-under-pipefail).
    labels="$(bdq label list "$id" 2>/dev/null)" || labels=""
    case "$labels" in
        *spira-poison*) ;;
        *)  bdq label add "$id" spira-poison >/dev/null 2>&1
            bdq note "$id" "Poisoned after $n attempts, charged by: ${charges:-unrecorded}. Not retried until a human changes the approach. Any live holder keeps its claim and releases on its own exit path; no persona can claim it again while the label stands." >/dev/null 2>&1
            progress "poisoned $id after $n attempts (${charges:-unrecorded})"
            # Inside the label guard, so it fires on the TRANSITION into poisoned and never
            # again — the bead keeps the label, and every later pass takes the other branch.
            spira_event bead.poisoned "$id" "poisoned $id after $n attempts" \
                "not retried until a human changes the approach; the ask below carries the failure" || true
            ;;
    esac

    # AT MOST ONE ASK PER (BEAD, ATTEMPT COUNT), EVER — and never "once per bead while it is
    # unpoisoned", which is what the label test above used to be doing double duty as. The
    # ask's own remedy is to clear the poison label, so keying on the label made every
    # application of the remedy re-arm the ask (poison_asked, lib.sh).
    poison_asked "$id" "$n" && continue

    # The ask carries the failure itself. A path is not evidence: the operator reads this
    # in a tmux pane and cannot open a file from it.
    # THE BEAD FIRST, THEN THE FAILURE. A log tail says what broke; it cannot say
    # what the work was for, and that is the question that has to be answered
    # before "change the approach or drop it" means anything.
    ev="$(bead_context "$id" 2>/dev/null)"
    # THE BRANCH IS LOOKED FOR IN THE BEAD'S OWN REPOSITORY. Asking the home repo
    # about another repository's bead answers "none — nothing was committed" for work that
    # is sitting on a branch in another checkout, and the operator would be deciding whether
    # to drop a bead on the strength of a fact from the wrong disk.
    r_name="$(bead_repo "$id")"; r_path="$(repo_root "$r_name")" || r_path=""
    ev="$ev

REPO      $r_name${r_path:+ ($r_path)}
ATTEMPTS  $n (poison threshold $POISON_AT) — charged by: ${charges:-unrecorded}
RECLAIMS  $(reclaims_of "$id" || true) — times the aeon died holding it; these do NOT count toward poison
REQUEUES  $(requeues_of "$id" || true) — times the harness reopened finished work over a rebase; these do NOT count toward poison
BRANCH    $( [ -n "$r_path" ] && git -C "$r_path" show-ref --verify -q "refs/heads/spira/$id" && echo "spira/$id exists, with work on it" || echo 'none — nothing was committed')

--- last session log (tail) ---
$(trace_tail "$SPIRA_RUN/$id.log" 25)"
    # MARKED ONLY IF THE ASK WAS ACCEPTED. Stamping first would let an escalation path that
    # is down silently swallow the one notification this count will ever produce.
    if "$SPIRA_NOTIFY" add \
          "Spira bead $id failed $n times — change the approach or drop it?" \
          --default "read the charges above first — an attempt is only a reason to stop if it names an outcome about the WORK. If they are genuine, rewrite the bead's description to change the approach and clear the spira-poison label; or close it if it is not worth doing" \
          --why "nothing downstream of it can proceed, and no aeon will take it again while it is poisoned" \
          --evidence "$ev" >/dev/null 2>&1; then
        poison_asked_mark "$id" "$n"
    else
        log "CHECK4 $id: the escalation path refused the ask — it stands, and the next pass retries it"
    fi
done

# ======================================================================================
# CHECK 5 — closed but not landed. A bead closed with no commit naming it unblocks its
# dependents on a lie, and everything downstream then builds on work that is not there.
# ======================================================================================
# The repository comes out of the SAME query as the id. `landed` reads the commit graph, and
# reading the wrong repository's graph gives the wrong answer confidently in both directions:
# a bead for repository A reads as never landed in repository B, so this check would reopen finished
# work on every pass. One query, both facts.
while IFS=$'\t' read -r id r_name superseded dropped; do
    [ -n "$id" ] || continue
    # Only beads an aeon worked — anything closed by hand has its own evidence.
    [ -f "$SPIRA_RUN/$id.log" ] || continue
    # A SUPERSEDED BEAD WILL NEVER HAVE A COMMIT NAMING IT, and that is correct: its work
    # was carried onto the successor's branch and lands under the successor's name. Without
    # this, two checks fought each other — the Sending reaped the branch, and this check
    # then read the missing branch as work lost and reopened a bead that was deliberately
    # retired. `bd supersede` records the relation as a `supersedes` dependency; read it
    # rather than inventing a label for something the database already models.
    # Superseded comes out of the SAME query, which already carries dependencies. Asking
    # `bd show` per bead cost 83ms x 36 closed beads for a fact the list had already
    # returned — the third time tonight a per-item call was made for something a bulk
    # query had in hand.
    [ "$superseded" = 1 ] && continue
    # A BEAD THE OPERATOR DROPPED WILL NEVER HAVE A COMMIT NAMING IT EITHER, and that is
    # equally correct: the verdict was "do not do this work", so no branch and no commit is
    # ever coming. Without this, CHECK 5 reopens it every pass and the drop cannot stick —
    # sp-m56w was closed on Ryan's verdict at 00:17 on 2026-09-08 and reopened by this check
    # at 00:18:52, poison label intact, so no aeon would claim it and nothing would ever
    # land it. A permanent zombie reached by a check that was right about every other bead.
    [ "$dropped" = 1 ] && continue
    r_path="$(repo_root "${r_name:-}")" || {
        log "CHECK5 $id: repo:$r_name is not in repo-map — cannot say whether it landed"
        continue; }
    # ONE `git log` PER REPO, not per bead. `landed` walks 400 commits every call, so 36
    # closed beads meant 36 full walks of the same history — the bulk of a pass that had
    # grown to four minutes against a two-minute timer, so passes overlapped. This is
    # `landed` inlined over a cached walk, so it must keep landed's THREE outcomes.
    if [ "$r_path" != "${subj_repo:-}" ]; then
        subj_repo="$r_path"
        # spira_landrefs is the base plus its local counterpart, both verified to resolve.
        # Non-zero means the repository cannot say what it lands on at all.
        subj_refs="$(spira_landrefs "$r_path")" || subj_refs=""
        subj_base="${subj_refs%% *}"
        # shellcheck disable=SC2086
        [ -n "$subj_refs" ] \
            && subjects="$(git -C "$r_path" log --format='%s%n%b' -n "${SPIRA_VERDICT_WINDOW:-400}" $subj_refs 2>/dev/null)" \
            || subjects=""
    fi
    # CANNOT TELL IS NOT "NOT LANDED". Reading an unresolvable base as "no commit names it"
    # would reopen every closed bead in that repository on every pass. The question is
    # unanswerable, so it is left unanswered and said out loud rather than answered wrongly.
    if [ -z "$subj_refs" ]; then
        log "CHECK5 $id: cannot resolve the ref $r_name lands on — not judging whether it landed"
    elif ! grep -qF "$id" <<< "$subjects"; then
        if git -C "$r_path" show-ref --verify -q "refs/heads/spira/$id"; then
            continue   # work exists on a branch; CHECK 6 lands it
        fi
        # COUNT IT. A bead that closes itself without committing a working change is
        # reopened here, becomes ready, is claimed, and closes itself again — a loop
        # with no counter, which is precisely the loop the poison threshold exists to
        # bound. The aeon's own post-session check handles the normal case (the aeon
        # detects closed+uncommitted and reopens it, so the cleanup trap sees the bead
        # as open and charges via session_outcome). This is the safety net for the case
        # where the aeon exited before reaching that check — in which case no attempt
        # has been charged yet and this is genuinely a failed attempt at the work.
        n="$(bump_attempt "$id" "closed-not-landed")"
        bead_reopen "$id" "Reopened by sentinel: closed, but no commit on ${subj_base:-the base} or on spira/$id names it in $r_name. Closed is not landed; attempt $n charged toward the poison threshold. If this bead was closed because another bead did the work, record it with: bd supersede $id --with <successor> — a close reason alone is not read by this check."
        progress "reopened $id — closed without landing (attempt $n)"
    fi
done < <(
    # EVERY PERSONA'S PARTITION, NOT THE BUILDER'S. This listed `--label spira,plan`, so a
    # bead of any other persona closed without a commit naming it was invisible to the one
    # check that exists to catch that — law-closed-is-not-landed, pointed at one partition
    # of several. A chamber that declares no partition is named below rather than read as a
    # clean sweep.
    home_repo="$(spira_home_repo)"
    while IFS=$'\t' read -r part _; do
        [ -n "$part" ] || continue
        bdjson list --status closed --limit 0 --label "$part" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
home = sys.argv[1]
for i in (d if isinstance(d, list) else [d]):
    repo = next((l[5:] for l in (i.get("labels") or []) if l.startswith("repo:")), home)
    # The third column is supersession, read from the dependencies this query already
    # returns rather than fetched per bead.
    #
    # `bd list` AND `bd show` NAME THE SAME FIELD DIFFERENTLY. show returns
    # {"dependency_type": "supersedes"}; list returns {"type": "supersedes"}. Reading only
    # the show spelling off a list row yields None for every dependency, so `sup` was 0 for
    # every bead and this exemption had never once fired: sp-dvlq was superseded by sp-35pl,
    # carried the dependency, and was still reopened as closed-without-landing every two
    # minutes. Accept either spelling rather than the one the neighbouring command happened
    # to use, because nothing here can tell which shape it was handed.
    sup = 1 if any((x.get("dependency_type") or x.get("type")) == "supersedes"
                   for x in (i.get("dependencies") or [])) else 0
    # Fourth column: dropped by the operator, carried as a label because "dropped" is not a
    # relation between beads the way supersession is — there is no second bead to point at.
    drop = 1 if "spira-dropped" in (i.get("labels") or []) else 0
    print("%s\t%s\t%s\t%s" % (i["id"], repo, sup, drop))' "$home_repo" 2>/dev/null
    done <<< "$PARTITIONS" |
    # Sorted on the REPOSITORY column first, because the loop above caches one `git log`
    # walk per repository and re-walks whenever the repository changes between rows; `-u`
    # then drops the duplicate a bead carrying two personas' labels would produce. Both
    # keys together are the whole line, so nothing is deduplicated on a partial key.
    sort -u -t$'\t' -k2,2 -k1,1
)
[ -n "$PARTITIONS" ] || log "CHECK5 no persona in the chamber declares a partition — no closed bead is being checked for landing"

# ======================================================================================
# CHECK 6 — land finished branches. THE WORK IS NOT DONE HERE; it is dispatched to
# landing.sh and this pass moves on. Landing fetches, rebases, runs a repository's whole
# gate and pushes: Measured, an ordinary pass cost 21s and the one pass that
# landed cost 5m30s, during which CHECK 7 below could not run and a free aeon slot sat
# empty with 15 beads ready. Cheap deterministic work must not queue behind expensive work,
# and this is the check that made it.
#
# WHY NOT SIMPLY REORDER CHECK 7 ABOVE CHECK 6. It recovers the empty slot and nothing else.
# systemd will not start a second instance of a running oneshot, so a five-minute pass still
# swallows the ticks behind it and the loop's period is still set by its most expensive
# step — which is the actual defect. The decoupling is the fix; the reorder was its shadow.
#
# THE UNIT NAME IS THE MUTEX AND THERE IS NO LOCKFILE. systemd refuses to start a unit that
# is already active, so a pass arriving mid-landing declines and moves on. `--collect` is
# not tidiness: without it a FAILED transient unit stays loaded and every later
# `systemd-run --unit=spira-landing` is refused forever, which is a landing leg that stops
# dead and never says so.
#
# NOTHING IS WAITED ON, so nothing about the landing's outcome is known during this pass.
# What is known is what the PREVIOUS run left behind, and that is read in two places below:
# the mailbox, which carries the movements it made, and the status file, which is the
# positive control — because "nothing landed" and "the landing worker has not run since
# Tuesday" are indistinguishable from here unless the worker says which one it is
# (law-absence-needs-a-positive-control).
#
# THE ENVIRONMENT IS EXPLICIT, NOT INHERITED. systemd-run does not carry the caller's
# environment across, which is correct and is also what this must want: a sentinel that
# exported SPIRA_FAYTHS into a transient unit once had it reach a test suite asserting
# defaults, and correct work was rejected on every retry with nothing pointing at the
# environment (law-gates-run-in-a-clean-environment). Pass what landing.sh needs and
# nothing else — in particular not SPIRA_FAYTHS, which is this pass's business alone.
#
# 40% AND A RuntimeMaxSec, BECAUSE THIS LEAVES THE SENTINEL'S CGROUP. Landing ran under
# spira-sentinel.service's CPUQuota=40% until it was split out; a transient unit is its own
# cgroup, so without a quota of its own the split would quietly hand the box more Spira than
# it had before. 40% is the same ceiling it already had. This machine also runs prod, two CI
# runners and the operator's session, and anything that polls in a loop on it gets a quota before it
# is enabled (law-fence-loops-on-shared-hardware). RuntimeMaxSec is the knob that applies to
# a `simple` service, which is what systemd-run creates; TimeoutStartSec would be ignored.
# ======================================================================================
LAND_UNIT="${SPIRA_LAND_UNIT:-spira-landing}"
# THE CAP IS SIZED AGAINST THE GATE, AND THE WORKER IS TOLD WHAT IT IS. At 1800s this leg
# could not finish a single pass once anything closed: a full spira gate measured 776s cold
# on 2026-09-07 and far more under contention, so four consecutive passes were SIGTERMed
# mid-gate having moved nothing while two closed beads waited and the base ref went six hours
# without a commit. It was invisible until then because a pass with nothing to land finishes
# in under twenty seconds, so the cap was only ever approached on the one path that matters.
#
# Raising it is half the fix and the weaker half — a bigger number just moves the cliff. The
# other half is in landing.sh, which now refuses to BEGIN a gate it has not time to finish,
# so a pass ends cleanly and its successor continues rather than restarting the same gate
# forever. That is why the worker is given the number rather than left to guess it.
LAND_MAXSEC="${SPIRA_LAND_MAXSEC:-3600}"
LAND_STALE="${SPIRA_LAND_STALE:-1800}"      # seconds; a leg quieter than this is broken
LAND_STATUS="$SPIRA_RUN/landing.status"
LAND_MAILBOX="$SPIRA_RUN/landing.progress"

# systemctl behind a seam for the same reason `bd` and `gh` are: a suite has to be able to
# say "a landing is in flight" without one, and there is no other way to ask.
land_active() {
    [ "$("${SPIRA_SYSTEMCTL:-systemctl}" --user is-active "$LAND_UNIT.service" 2>/dev/null)" = active ]
}

# DRAIN BY RENAME. The worker appends while this reads, so the mailbox is moved aside first
# and read from the copy: a line is then counted exactly once, and a landing that finishes
# mid-drain simply lands its lines in the next pass's mailbox rather than in a file being
# consumed underneath it.
land_drain() {
    local mine="$SPIRA_RUN/landing.progress.drain.$$" f line
    [ -s "$LAND_MAILBOX" ] && mv -f "$LAND_MAILBOX" "$mine" 2>/dev/null
    # EVERY drain file, not just this pass's. One left behind by a pass that died between
    # the rename and the read holds movements the DAG really made, and a `progress` silently
    # dropped is a pass that judges itself starved when it was not — the same class of bug
    # as counting one twice, arriving from the other side. The glob is guarded because an
    # unmatched one expands to itself.
    for f in "$SPIRA_RUN"/landing.progress.drain.*; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            # THE SENTINEL COUNTS IT, not landing.sh. `progressed` gates CHECK 8, and a
            # movement the harness made is a movement whichever process made it — the pass
            # it is counted in is a detail of scheduling, not of the DAG.
            progress "$line"
        done < "$f"
        rm -f "$f"
    done
}

land_drain

# THE POSITIVE CONTROL, read before anything is launched so it describes a completed run
# rather than the one this pass is about to start.
land_age=-1
if [ -r "$LAND_STATUS" ]; then
    # shellcheck disable=SC1090
    eval "$(sed -n 's/^\(SP_LAND_[A-Z]*\)=\([0-9-]*\)$/\1=\2/p' "$LAND_STATUS" 2>/dev/null)"
    land_age=$(( $(date +%s) - ${SP_LAND_AT:-0} ))
    log "CHECK6: last landing ${land_age}s ago — rc=${SP_LAND_RC:-?}, ${SP_LAND_BRANCHES:-?} branch(es) seen, ${SP_LAND_MOVED:-?} moved"
    if [ "${SP_LAND_RC:-0}" != 0 ]; then
        log "CHECK6 WARN: the last landing exited ${SP_LAND_RC} — see $SPIRA_RUN/landing.log"
        land_escalate "its last run exited ${SP_LAND_RC}" \
            "$(printf 'STATUS  %s\n\n--- landing.log (tail) ---\n%s\n' \
                 "$(tr '\n' ' ' < "$LAND_STATUS")" "$(land_log_tail 30)")"
    fi
else
    log "CHECK6: no landing has ever completed on this host"
fi

if land_active; then
    log "CHECK6: a landing is already in flight — this pass does not start another"
elif "${SPIRA_LAUNCH:-systemd-run}" --user --collect --quiet \
        --unit="$LAND_UNIT" \
        --property=RuntimeMaxSec="$LAND_MAXSEC" \
        --property=CPUQuota=40% --property=Nice=10 \
        --property=StandardOutput="append:$SPIRA_RUN/landing.log" \
        --property=StandardError="append:$SPIRA_RUN/landing.log" \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
        --setenv=SPIRA_HOME="$SPIRA_HOME" --setenv=SPIRA_RUN="$SPIRA_RUN" \
        --setenv=SPIRA_DB="$SPIRA_DB" --setenv=SPIRA_REPO="${SPIRA_REPO:-}" \
        --setenv=SPIRA_REPO_MAP="$SPIRA_REPO_MAP" \
        --setenv=SPIRA_HOME_REPO="$(spira_home_repo)" \
        --setenv=SPIRA_BD="${SPIRA_BD:-bd}" --setenv=SPIRA_GH="${SPIRA_GH:-gh}" \
        --setenv=SPIRA_LAND_MAXSEC="$LAND_MAXSEC" \
        "$SPIRA_HOME/landing.sh" 2>/dev/null
then
    log "CHECK6: landing dispatched as $LAND_UNIT"
    # The FIRST dispatch ever, never overwritten. It is what makes "a worker that has never
    # once completed a run" a detectable state rather than a permanently silent one: without
    # it, a landing.sh that dies before it can write a status file leaves no status to be
    # stale, and the staleness check below would have nothing to measure against forever.
    [ -f "$SPIRA_RUN/landing.dispatched" ] || date +%s > "$SPIRA_RUN/landing.dispatched"
elif land_active; then
    # The race: a landing started between the check above and the launch. Declining is the
    # right answer and it is not a failure, so it must not be reported as one.
    log "CHECK6: a landing started underneath this pass — not starting another"
else
    log "CHECK6 WARN: could not dispatch the landing worker; nothing will land until this is fixed"
    land_escalate "the landing worker will not start" \
        "$(printf 'systemd-run --unit=%s refused, and the unit is not active.\n\n--- landing.log (tail) ---\n%s\n' \
             "$LAND_UNIT" "$(land_log_tail 30)")"
fi

# A leg that has not COMPLETED a run in half an hour, with nothing in flight, is broken —
# and this is the case the whole status file exists for. Checked after the dispatch so a
# host that has simply never run one is not escalated about on its very first pass.
if [ "$land_age" -lt 0 ] && [ -f "$SPIRA_RUN/landing.dispatched" ]; then
    land_age=$(( $(date +%s) - $(cat "$SPIRA_RUN/landing.dispatched" 2>/dev/null || date +%s) ))
fi
if ! land_active && [ "$land_age" -gt "$LAND_STALE" ]; then
    log "CHECK6 WARN: no landing has completed in ${land_age}s and none is running"
    land_escalate "nothing has completed a landing pass in ${land_age}s" \
        "$(printf 'STATUS  %s\n\n--- landing.log (tail) ---\n%s\n' \
             "$( [ -r "$LAND_STATUS" ] && tr '\n' ' ' < "$LAND_STATUS" || echo 'none — no run has ever written one' )" \
             "$(land_log_tail 30)")"
fi

# READ THE MAILBOX AGAIN. A landing that finished while this pass was running has movements
# to report and no reason to wait two minutes to be counted; in the normal case the dispatch
# above returned in milliseconds and this finds nothing.
land_drain

# ======================================================================================
# CHECK 6b — the Sending. Reap the branch and worktree of every bead whose work is now an
# ancestor of its repository's base.
#
# THIS STILL RUNS INSIDE THE PASS, and it may run while a landing is in flight. That is safe
# by the same predicate that makes the two separate checks: the Sending reaps only branches
# ALREADY an ancestor of the base, and those are exactly the branches landing.sh skips, so
# the two never hold the same ref. The one interleaving that looks alarming — landing pushes
# a branch and this reaps it in the same minute — is the intended path arriving a pass early.
#
# This is `gt convoy land`'s worktree cleanup, scoped to branches,
# and it is a separate check from CHECK 6 on purpose: a branch also arrives at "landed" by
# a hand merge, by an earlier pass whose reap was interrupted, or by a reap that a locked
# worktree refused, and a cleanup that only ever runs on the success path of one code path
# leaks everywhere else. sending.sh judges by ancestry alone, never by bead status, so it
# cannot be talked into deleting work by a database that is merely optimistic.
# ======================================================================================
sent="$("$SPIRA_HOME/sending.sh" 2>&1)"
[ -n "$sent" ] && printf '%s\n' "$sent"
n_reaped="$(grep -c '^REAPED' <<< "$sent" || true)"
# ONE ACT PER BRANCH, NAMING IT, rather than one act carrying a count. "reaped 2 landed
# branch(es)" told the pane that something had been cleaned up and withheld the only part a
# reader can act on — WHICH branch, in WHICH repository. Two of these a pass is two rows, and
# RECENT now has the height for them; a count is what a section with five rows had to settle
# for. The id is last so the title lookup in the collector still finds it.
if [ "${n_reaped:-0}" -gt 0 ]; then
    while read -r _ rid rrepo rbr _; do
        [ -n "${rbr:-}" ] || continue
        act "reaped $rrepo $rbr $rid"
    done < <(grep '^REAPED' <<< "$sent")
fi
# A FAILED reap is a leak that will repeat every pass, so it is worth a line in the log —
# but it is NOT an action, because counting a failure as an action is precisely how the
# starvation check was blinded in the first place.
grep -q '^FAILED' <<< "$sent" && log "sending reported a branch it could not delete"

# ======================================================================================
# ======================================================================================
# THE GOVERNOR runs before capacity is considered. It decides from /proc how much of this
# machine Spira may use — the box also runs prod, two CI runners, all of Gas Town and
# the operator's own session, so an aeon is never the most important thing on it. It withholds
# only, and never touches an aeon already working: finishing costs less than restarting.
# ======================================================================================
"$SPIRA_HOME/governor.sh" >/dev/null 2>&1 || true
if [ -r "$SPIRA_RUN/budget.env" ]; then
    b="$(. "$SPIRA_RUN/budget.env"; printf '%s|%s|%s' "${SP_BUDGET:-?}" "${SP_BUDGET_REASON:-?}" "${SP_GOVERNOR_MODE:-measure}")"
    gb="${b%%|*}"; grest="${b#*|}"; greason="${grest%|*}"; gmode="${grest##*|}"
    if [ "$gmode" = measure ] && [ "$gb" = "0" ]; then
        log "governor [measure]: WOULD withhold — $greason (not enforcing)"
    elif [ "$gmode" = enforce ] && [ "$gb" = "0" ]; then
        log "governor: summoning nothing — $greason"
    fi
fi

# ======================================================================================
# CHECK 6c — THE CI SWEEP. An aeon does the work, cuts the review, and exits; this is what
# brings the bead back (the operator, verbatim: "generally i want an aeon to do the work, cut
# the CR, then die. we need a sentinel or a watcher that sweeps open CRs and then changes
# the priority on the associated bead so that it gets picked up next sweep").
#
# WHY NOT LET THE AEON WAIT. It costs an Opus session to sit on a `gh run watch` for
# twenty-five minutes, and the session can die in that window carrying everything it knows.
# A parked bead costs nothing to leave parked, and this check is three cheap `gh` calls.
#
# The label is also what stops parked work looking abandoned: strand.sh sees a bead with no
# live aeon and would otherwise call it stranded.
#
# WHICH IS EXACTLY WHY THE PARK IS JUDGED BEFORE THE RUN IS. Everything below that asks `gh`
# a question can give up quietly — an unmapped repository, a path that is not a checkout, a
# pull request that does not exist — and every one of those exits leaves the label standing.
# A park in a repository that opens no pull requests therefore never ends: not claimable, not
# reported, and displayed as "in CI", which is the one description that stops anybody looking
# for the real cause. So the two verdicts that need no network are taken first, at the top of
# the loop body, above every `continue`. spira_ci_park_state holds the rule; this acts on it.
# ======================================================================================
# NOT `--status open`. A parked bead may still be in_progress — the aeon that labelled it
# has not necessarily exited yet — and filtering on open alone reported zero while a bead sat
# labelled and plainly visible in `bd show`. Take everything not closed.
#
# The repo name and the park's age come out of THIS listing rather than a `bd show` per bead:
# the JSON is already in hand, and a query per parked bead is a cost paid every two minutes
# to learn what was already on the screen.
while IFS="$(printf '\t')" read -r id park_repo park_at; do
    [ -n "$id" ] || continue
    park_state="$(spira_ci_park_state "$park_repo" "$park_at")" || {
        # THE CLOCK, NOT THE BEAD. The park could not be aged, so leave it standing —
        # stripping a label on the strength of a timestamp we could not read would summon an
        # aeon for nothing — and say so in the log, because a check that could not run must
        # never pass for a check that found nothing (law-absence-needs-a-positive-control).
        log "CHECK6c $id: parked with an updated_at this cannot read [$park_at] — the park was not aged"
        park_state=watch
    }
    case "$park_state" in
        no-ci)
            # NO RUN EXISTS AND NONE WILL. Only `pr` mode opens a pull request; `push` merges
            # the branch itself and `hold` leaves it for a human, so for both of those the
            # landing gate is the only gate and there is nothing further to wait for. This
            # also catches a bead that MOVED repository while parked, which no check made at
            # the moment of parking could have seen.
            bdq label remove "$id" "$SPIRA_CI_LABEL" >/dev/null 2>&1
            bdq note "$id" "Unparked by the CI sweep: repo:$park_repo lands by $(repo_land "$park_repo"), so nothing opens a pull request for it and no CI run exists — a park here waits for an event that cannot occur, and the label excludes the bead from every predicate and from the stranded-work report while it waits. The landing gate is the only gate for this repository. If the work is done, close the bead and the sentinel lands the branch; if it is not, carry on with it." >/dev/null 2>&1
            progress "$id: unparked — repo:$park_repo has no CI to wait for"
            continue
            ;;
        expired)
            # A PARK IS A PROMISE THAT SOMETHING ELSE IS WATCHING. Past the longest plausible
            # run that promise is false, and the bead belongs back in the report that would
            # have found it rather than excluded from it. The priority is deliberately left
            # alone: this says the park is over, not that the work is urgent.
            bdq label remove "$id" "$SPIRA_CI_LABEL" >/dev/null 2>&1
            bdq note "$id" "Unparked by the CI sweep: this bead had been parked for longer than SPIRA_CI_PARK_MAX (${SPIRA_CI_PARK_MAX}s). A park that outlives the longest plausible run is not parked, it is lost, and the label was keeping it out of the stranded-work report that would have found it. The branch and its commits are recorded on this bead — read its run before assuming anything about it." >/dev/null 2>&1
            progress "$id: unparked — the park outlived SPIRA_CI_PARK_MAX"
            continue
            ;;
    esac
    br="$(bead_branch "$id")"
    repo="$(repo_root "$park_repo" 2>/dev/null)" || continue
    [ -d "$repo/.git" ] || continue
    state="$( cd "$repo" && ghq pr view "$br" --json state,mergeable,statusCheckRollup \
                -q '"\(.state) \(.mergeable) \([.statusCheckRollup[]?|.conclusion//.state]|join(","))"' 2>/dev/null )"
    [ -n "$state" ] || continue
    case "$state" in
        *FAILURE*|*TIMED_OUT*|*ERROR*|*CANCELLED*)
            # RED: the park is over; hand the bead back to the queue at its own priority.
            # Priority is deliberately left alone — CI failure says the work is needed
            # again, not that it is more important than it was. A trivial bead that fails
            # repeatedly must not outrank genuine P0 work just because it is loud. Being
            # picked up again requires being READY, which clearing the park label achieves
            # on its own. The branch and its commits are already recorded on this bead.
            bdq label remove "$id" "$SPIRA_CI_LABEL" >/dev/null 2>&1
            bdq note "$id" "CI failed on $br. Cleared $SPIRA_CI_LABEL; the bead returns to the queue at its own priority — the branch and its commits are recorded on this bead." >/dev/null 2>&1
            progress "CI red on $id — handed back to the queue at its own priority"
            spira_event ci.failed "$id" "CI red on $br — $id handed back to the queue" \
                "pull request state: $state" || true
            ;;
        *PENDING*|*IN_PROGRESS*|*QUEUED*|*" null"*)
            : ;;   # still running; leave it parked, and say nothing
        MERGED*|CLOSED*)
            bdq label remove "$id" "$SPIRA_CI_LABEL" >/dev/null 2>&1
            progress "$id: its pull request is $state — no longer awaiting CI"
            ;;
        *)
            # GREEN: nothing left to decide, so let CHECK 6 land it on the next pass.
            bdq label remove "$id" "$SPIRA_CI_LABEL" >/dev/null 2>&1
            bdq note "$id" "CI green on $br; released to the landing check." >/dev/null 2>&1
            progress "CI green on $id — released to land"
            ;;
    esac
# THE LISTING IS REDIRECTED IN, NOT PIPED. A pipeline runs its right-hand side in a subshell,
# and `progress` writes a counter this pass's judgement gate reads — piped, every action taken
# here would be counted in a shell that exits at `done`, and a busy sweep would report an idle
# harness.
done < <(bdjson list --all --limit 0 --label "$SPIRA_CI_LABEL" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
home = sys.argv[1]
for i in (d if isinstance(d, list) else [d]):
    if i.get("status") == "closed":
        continue
    repo = next((l[5:] for l in (i.get("labels") or []) if l.startswith("repo:")), home)
    # updated_at is a proxy for "entered this state", and a good one: writing the label moves
    # it, and a parked bead is not otherwise touched.
    print("%s\t%s\t%s" % (i["id"], repo, i.get("updated_at") or ""))' "$(spira_home_repo)" 2>/dev/null)

# CHECK 7 — idle capacity. Ready work and a free aeon is the whole point of the system.
#
# EVERY FAYTH IS ASKED ITS OWN PREDICATE, AND EVERY FAYTH IS ASKED. This whole block used
# to sit inside `if [ "$ready" -gt 0 ]`, where `$ready` was a single hardcoded
# `--label spira,plan` count — the BUILDER's partition, standing in for every persona. Ops
# was therefore unreachable by construction: an incident arriving while no plan work was
# queued summoned nothing, and Ops could only ever wake when the builder had work, which is
# backwards for an on-call role. A fayth carries FAYTH_LABELS precisely so its partition is
# its own; the readiness question has to be asked through it.
#
# summon_fayth lives in lib.sh so the decision is one thing in one place — and so it can be
# exercised by test-fayth.sh, which the version inlined here could not be: everything else
# in a sentinel pass touches the real repository and the real database.
# ======================================================================================
# ONE POOL, DRAWN DOWN IN THE ORDER THE PERSONAS ARE NAMED. SPIRA_MAX_AEONS is that pool and
# was, until 2026-09-07, a configuration key nothing read — so every persona had a private
# cap and nothing coordinated them. The order is the priority: Ops is named first because an
# on-call persona that has to wait behind feature work is not on call.
#
# Ops also RESERVES a slot (FAYTH_RESERVE in its .fayth), which is the half that ordering
# alone cannot do: builders hold their beads for ~10 minutes (p50 9.4 min, p90 18.6 min measured over 28 runs), so a pass that merely asked
# Ops first would still find every slot occupied by sessions that started an hour ago. The
# reserve is subtracted from what the others may see whether or not Ops is using it.
#
# A HOST THAT SETS NO POOL BEHAVES EXACTLY AS BEFORE — an empty pool is passed as empty, and
# every cap below it is the persona's own.
# THE POOL IS FOR AEONS, NOT FOR THE PARTY. Party members travel with you and are summoned by
# their own units; only task personas are called for a fight and dismissed after it, and only
# they draw on this. `live` is counted the same way, over the task roster alone, or a running
# Ops would consume a slot it was never taking from.
TASK_FAYTHS="$(spira_task_fayths)"
pool="${SPIRA_MAX_AEONS:-}"
if [ -n "$pool" ]; then
    task_live=0; for f in $TASK_FAYTHS; do task_live=$((task_live + $(aeon_count "$f"))); done
    pool=$(( pool > task_live ? pool - task_live : 0 ))
    log "CHECK7 pool: ${SPIRA_MAX_AEONS} slot(s), $task_live live, $pool free — order: $TASK_FAYTHS"
fi
for f in $TASK_FAYTHS; do
    if summon_fayth "$f" "$pool"; then
        act "summoned a $f aeon"
        [ -n "$pool" ] && pool=$(( pool > 0 ? pool - 1 : 0 ))
    fi
done

# LANE FAYTHS are handled AFTER the pool and draw from their own declared capacity, never
# from SPIRA_MAX_AEONS. No pool argument is passed — that is the mechanism: fayth_free
# without a pool arg uses FAYTH_MAX_CONCURRENT alone, so a fully-occupied builder pool
# cannot prevent an ops aeon from starting. This is what the ops lane was always designed
# to guarantee; generalising it into this loop is what makes it configurable.
LANE_FAYTHS="$(spira_lane_fayths)"
[ -n "$LANE_FAYTHS" ] && log "CHECK7 lanes (${SPIRA_LANES:-none} declared): $LANE_FAYTHS"
for f in $LANE_FAYTHS; do
    if summon_fayth "$f"; then
        act "summoned a $f lane aeon"
    fi
done

if [ "$GOAL_REACHED" = 1 ]; then
    log "pass complete — $acted action(s), $progressed progress, goal reached"
    exit 0
fi

# The plan's own readiness, and only the plan's, gates the judgement tier below: ready plan
# work means the DAG is moving whether or not an aeon was free to take it, which is
# throughput rather than starvation. A ready INCIDENT says nothing about the plan, so it
# must not silence CHECK 8 either.
if [ "$plan_ready" -gt 0 ]; then
    log "pass complete — $acted action(s), $progressed progress"
    exit 0
fi

# ======================================================================================
# CHECK 8 — JUDGEMENT. Everything above passed, work remains, and nothing is ready or
# running. There is no rule left to apply: that is the definition of needing judgement.
# Rate-limited, because inference is a cost centre and a loop that reasons every minute is
# a loop that reasons about nothing.
# ======================================================================================
if [ "$plan_inprog" -eq 0 ] && [ "$n_open" -gt 0 ] && [ "$progressed" -eq 0 ]; then
    now="$(date +%s)"; last=0; [ -f "$COOLDOWN" ] && last="$(cat "$COOLDOWN" 2>/dev/null || echo 0)"
    if [ $(( now - last )) -lt "$INFERENCE_EVERY" ]; then
        log "starved, but inference is in cooldown ($(( INFERENCE_EVERY - now + last ))s left)"
        exit 0
    fi
    echo "$now" > "$COOLDOWN"
    log "STARVED — $n_open open, 0 ready, 0 running. Dropping to inference."
    "$SPIRA_HOME/reflect.sh" "$open_children" >> "$SPIRA_RUN/reflect.log" 2>&1
    act "invoked reflection"
fi

log "pass complete — $acted action(s), $progressed progress"
