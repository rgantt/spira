#!/usr/bin/env bash
#
# landing.sh — CHECK 6, moved out of the reconcile loop and into its own process.
#
#   landing.sh          one landing pass over every repository
#
# WHY THIS IS NOT IN THE SENTINEL ANY MORE
# ----------------------------------------
# The sentinel is a reconcile loop and every other check in it is a handful of bead queries
# and a `git for-each-ref`. Landing is not: it fetches, rebases, runs the repository's whole
# landing gate and pushes. Measured, an ordinary pass took 21s and the one pass
# that landed a branch took 5m30s — and because CHECK 7 (summon an aeon for ready work) sat
# BELOW it, a free aeon slot with 15 beads ready stayed empty for those five and a half
# minutes. systemd will not start a second instance of a oneshot that is already running, so
# the long pass also swallowed the three timer ticks behind it.
#
# That inverts the tenet the harness is built on: cheap deterministic work must not queue
# behind expensive work. Summoning costs about a second and is pure dispatch; gating runs a
# repository's whole test suite. Reordering the two checks was the one-line version and it
# was rejected on purpose — it recovers the free slot but a long landing still swallows the
# ticks behind it, so the loop's period would still be set by its most expensive step.
#
# THE UNIT NAME IS THE MUTEX. The sentinel launches this as a transient unit with a FIXED
# name (`spira-landing`), fire and forget, the same shape lib.sh already uses to summon an
# aeon. systemd refuses to start a unit that is already active, so a pass arriving while a
# landing is still in flight declines and moves on — the wanted behaviour, and it costs no
# lockfile and no pid file to get. `--collect` is load-bearing rather than tidiness: without
# it a FAILED unit stays loaded and every later `systemd-run --unit=spira-landing` would be
# refused forever, which is a landing leg that stops dead and says nothing.
#
# FIRE AND FORGET NEEDS A POSITIVE CONTROL, because "nothing landed" and "the landing worker
# never ran" look identical from the sentinel's pane (law-absence-needs-a-positive-control).
# So this writes two things the sentinel reads on its next pass:
#
#   landing.status    — key=value, rewritten whole every run: when it finished, its exit
#                       status, how many spira/* branches it actually SAW. A run that saw
#                       branches and landed none is a different fact from a run that saw
#                       none, and a leg that has not completed a run in half an hour is a
#                       third.
#   landing.progress  — an append-only mailbox, one line per movement of the DAG. The
#                       sentinel drains it (by rename, so a line is counted once and only
#                       once) and replays each line through its own `progress`, which is
#                       what keeps landings visible in the sentinel log and counted against
#                       the judgement tier. Landing does not get to count its own actions
#                       into a pass it is no longer part of.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

STATUS="$SPIRA_RUN/landing.status"
MAILBOX="$SPIRA_RUN/landing.progress"

# n_branches is the positive control's evidence and it counts every spira/* ref seen, not
# the subset that was landable. "I looked at nine branches and moved none" is a claim about
# the graph; "I looked at zero" is a claim about this program, and only the raw count can
# tell them apart.
n_branches=0
n_prog=0

# The mailbox line is the message and nothing else — no ACT prefix, no timestamp. The
# sentinel adds both when it counts it, and a line that arrived pre-formatted would read as
# though the sentinel had done the work.
#
# ONLY MOVEMENTS CROSS THE SEAM. `act` writes to this worker's log and stops there: the
# sentinel's `acted` counter exists for its own pass summary and gates nothing, while
# `progressed` gates the judgement tier, so a write that moved nothing has no business
# travelling. Sending a "gated and held" across would be the old blinding bug — a futile
# action muting the only check that notices paralysis — rebuilt across a file.
act()      { log "$*"; }
progress() { n_prog=$((n_prog+1)); log "$*"; printf '%s\n' "$*" >> "$MAILBOX"; }

# STATUS IS WRITTEN ON EVERY EXIT PATH, including the one where systemd's RuntimeMaxSec cuts
# this off mid-gate. A worker that only reports when it finishes cleanly is a worker whose
# silence means nothing.
finish() {
    local rc=$?
    { printf 'SP_LAND_AT=%s\n'       "$(date +%s)"
      printf 'SP_LAND_RC=%s\n'       "$rc"
      printf 'SP_LAND_BRANCHES=%s\n' "$n_branches"
      printf 'SP_LAND_MOVED=%s\n'    "$n_prog"
    } > "$STATUS.$$" 2>/dev/null && mv -f "$STATUS.$$" "$STATUS" 2>/dev/null
    rm -f "$STATUS.$$" 2>/dev/null
    exit "$rc"
}
trap finish EXIT
trap 'exit 143' TERM INT

log "landing: starting a pass over [$(spira_repos | tr '\n' ' ')]"

# ======================================================================================
# LAND FINISHED BRANCHES. A passing branch must merge without a human; a branch
# that waits rots, because main moves underneath it and manufactures conflicts that did
# not exist.
#
# ONCE PER REPOSITORY, AND HOW A BRANCH LANDS IS THE REPOSITORY'S OWN ANSWER. brain has no
# reviewer between an aeon's commit and origin/main, so its branches are merged and pushed.
# A repository may have branch protection and a CI suite that is the real authority, so pushing
# its default branch would be both wrong and refused; its branches become pull requests with
# auto-merge armed, and GitHub lands them when CI goes green (law-green-prs-merge-themselves).
# A repository whose branches this harness has no business advancing — one whose checkout is a
# Town rig on a detached HEAD — has its branches gated and held.
#
# AND THE BRANCH THEY LAND ON IS THE REPOSITORY'S OWN ANSWER TOO. Three of the seven are not
# `main`: some repositories default to `master` and have no ref named `main` at all, and a
# remote need not be called `origin`. `spira_landref` resolves it and refuses to guess.
# ======================================================================================
# Land in a DEDICATED WORKTREE, never in the shared checkout an interactive session is
# using. The first version guarded on `git status --porcelain` being clean, which fails
# safe in the wrong direction: .claude/concierge.log was a LOG TRACKED IN GIT, rewritten
# every ten minutes by concierge.timer, so the tree was dirty essentially always and the
# gate never opened once. A gate that never opens is as broken as one that never closes.
# The logs are untracked now, but the structural answer is not to care about that tree.
#
# EVERY BRANCH IS REBASED ONTO ITS REPOSITORY'S BASE BEFORE IT IS GATED OR MERGED. A branch
# that was cut hours ago is measured against a base that has moved, and because every Spira bead
# edits the same few files under .claude/spira, the collision is manufactured rather than
# real. Rebasing first turns the merge into a fast-forward and puts any genuine conflict in
# front of an aeon, which can resolve it, instead of in front of a `git merge` that can only
# fail. A merge conflict is not an escalation.

# submitted <id> <tip> [state] — has this exact branch tip already been sent, and how?
#
# `pr` and `hold` leave the branch standing by design, so the plain ancestry test that stops
# `push` mode from re-landing says nothing about them: without this, every pass two minutes
# apart would push the branch again, ask GitHub for the pull request again, and re-note the
# bead again, forever. Keyed on the TIP, so a branch an aeon has moved is genuinely resent.
# A failed submission is retried, but not sooner than an hour — a gh outage must not become
# a request every two minutes, and it must not become silence either.
SUBMITTED="$SPIRA_RUN/submitted"
submitted() {            # 0 if nothing more to do for this tip right now
    local id="$1" tip="$2" f="$SUBMITTED/$1" rec_tip rec_at rec_state
    [ -f "$f" ] || return 1
    read -r rec_tip rec_at rec_state < "$f" 2>/dev/null || return 1
    [ "$rec_tip" = "$tip" ] || return 1
    [ "$rec_state" = failed ] || return 0
    [ $(( $(date +%s) - rec_at )) -lt 3600 ]
}
mark_submitted() {       # mark_submitted <id> <tip> <state>
    mkdir -p "$SUBMITTED"
    printf '%s %s %s\n' "$2" "$(date +%s)" "$3" > "$SUBMITTED/$1"
}

# land_pr <repo> <branch> <id> <base-ref> -> 0 if a pull request is open for this tip.
# The branch is force-pushed with a lease because CHECK 6 rebases it before gating, so the
# remote ref is routinely behind by a rewrite rather than by a divergence — and the lease is
# what keeps that from being a licence to clobber someone else's push.
#
# THE REMOTE AND THE BASE BRANCH BOTH COME OUT OF THE BASE REF. This took `origin` and `main`
# literally, and `--base main` opens a pull request against a branch that does not exist in
# the two repositories whose default is `master`.
land_pr() {
    local repo="$1" br="$2" id="$3" baseref="$4" num title remote base
    remote="$(ref_remote "$baseref")" || remote=origin
    base="$(ref_branch "$baseref")"
    if ! git -C "$repo" push -q --force-with-lease -u "$remote" "$br" 2>/dev/null; then
        log "CHECK6 $id: could not push $br to $remote"
        return 1
    fi
    num="$( cd "$repo" && ghq pr view "$br" --json number -q .number 2>/dev/null )"
    # DOES ANOTHER OPEN PR ALREADY CARRY THIS WORK? A branch is named for its bead, so a
    # successor bead cuts a new branch and this path opens a SECOND pull request for the
    # same commits — which is what happened to sp-pd-ci: #114 carried all nineteen commits
    # of #113 plus one, and both sat open, burning CI minutes and splitting the review.
    # law-decompose-by-deliverable stops the usual cause; this catches the rest, because a
    # duplicate review thread is expensive and silent.
    if [ -z "${num:-}" ]; then
        dup="$( cd "$repo" && ghq pr list --state open --json number,headRefName \
                  -q '.[] | "\(.number) \(.headRefName)"' 2>/dev/null \
                | while read -r n ref; do
                      [ "$ref" = "$br" ] && continue
                      # An existing PR supersedes this branch when it already contains
                      # every commit this branch would add.
                      if [ -z "$(git -C "$repo" log --format='%H' "$base..$br" 2>/dev/null \
                                 | while read -r c; do
                                       git -C "$repo" merge-base --is-ancestor "$c" "origin/$ref" 2>/dev/null || echo x
                                   done)" ]; then
                          echo "$n"; break
                      fi
                  done | head -1 )"
        if [ -n "${dup:-}" ]; then
            log "CHECK6 $id: #$dup already carries every commit on $br — not opening a second pull request"
            bdq note "$id" "Not opening a pull request: #$dup already carries every commit on $br. Continue the review there rather than splitting it across two threads." >/dev/null 2>&1
            return 1
        fi
        title="$(bdjson show "$id" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
d = d if isinstance(d, list) else [d]
print(d[0].get("title", "") if d else "")' 2>/dev/null)"
        # THE BODY GOES IN ON STDIN, and the heredoc must CLOSE before the `||` arm, or
        # bash reads the arm itself as heredoc content — a redirection is bound to the line
        # it appears on, not to the command that line continues. Prose belongs on stdin
        # anyway: backticks and $( ) in a double-quoted argument are command substitution,
        # and a message that silently loses the terms it was explaining is worse than none
        # (law-commit-messages-via-stdin).
        if ! ( cd "$repo" && ghq pr create --head "$br" --base "$base" \
                 --title "$id: ${title:-Spira}" --body-file - >/dev/null 2>&1 ) <<PRBODY
Filed by Spira for bead $id. The bead is closed in the Spira database; this
pull request is how the work lands, so it is not done until this merges.

Auto-merge is armed — a green run merges it without anyone waiting on it.
PRBODY
        then
            log "CHECK6 $id: gh pr create failed for $br"
            return 1
        fi
        num="$( cd "$repo" && ghq pr view "$br" --json number -q .number 2>/dev/null )"
    fi
    # A green pull request must merge itself. If the repository has auto-merge disabled the
    # arm fails and is worth a line — the pull request is still open and correct, it simply
    # now needs a human, which is the thing to know.
    ( cd "$repo" && ghq pr merge --auto --squash "$br" >/dev/null 2>&1 ) \
        || log "CHECK6 $id: pull request ${num:-?} is open but auto-merge could not be armed"
    log "CHECK6 $id: pull request ${num:-?} open on $br — its CI is the gate now"
    return 0
}

land_repo() {
    local name="$1" repo br id st mode base land tip merged pushed attempt brs
    local bead_repo_name bead_repo_path gate_out base_branch base_remote
    repo="$(repo_root "$name")" || { log "CHECK6 $name: no repo-map entry — skipped"; return 0; }
    [ -e "$repo/.git" ] || { log "CHECK6 $name: $repo is not a git checkout — skipped"; return 0; }

    # The local ref read comes first and the fetch is paid for only if there is something to
    # land. This runs every two minutes across every registered repository; an unconditional
    # fetch of each would be thousands of round trips a day to learn nothing.
    brs="$(git -C "$repo" for-each-ref --format='%(refname:short)' 'refs/heads/spira/*' 2>/dev/null)"
    [ -n "$brs" ] || return 0
    n_branches=$(( n_branches + $(printf '%s\n' "$brs" | grep -c . || true) ))

    mode="$(repo_land "$name")"

    # THE BASE IS RESOLVED BEFORE THE FETCH, AND THE FETCH FOLLOWS IT. `git fetch origin` was
    # literal here; a remote need not be called `origin`, so that fetch was a silent no-op in the
    # one repository whose refs nothing else in this harness touches. Resolving first is safe
    # because the ANSWER is a ref name, which a fetch does not change — only what the ref
    # points at, which is why the fetch still has to happen before anything is measured.
    #
    # A repository whose base cannot be established is SKIPPED, loudly. Every alternative is
    # worse: rebasing onto a branch that does not exist reopens finished work with a reason
    # that is not a reason, and merging into a guessed branch writes to one nobody chose.
    base="$(spira_landref "$repo")" || {
        log "CHECK6 $name: cannot resolve the ref its branches land on — skipped. Give it a \`base\` in repo-map."
        return 0; }
    base_branch="$(ref_branch "$base")"
    base_remote="$(ref_remote "$base")" || base_remote=""
    [ -n "$base_remote" ] && git -C "$repo" fetch -q "$base_remote" 2>/dev/null
    land="$SPIRA_RUN/worktree/.landing.$(basename "$repo")"
    if [ "$mode" = push ]; then
        if [ ! -e "$land/.git" ]; then
            mkdir -p "$(dirname "$land")"
            # Through the chokepoint. This runs on every landing pass, every two minutes,
            # over every repository — so it is the prune most likely to be the one standing
            # over a live aeon's tree when that tree's `.git` link is momentarily unreadable.
            spira_prune_worktrees "$repo" >/dev/null 2>&1
            git -C "$repo" worktree add -q --detach "$land" "$base" 2>/dev/null || true
        fi
        [ -e "$land/.git" ] && git -C "$land" checkout -q -B landing "$base" 2>/dev/null
    fi

    for br in $brs; do
        id="${br#spira/}"
        read -r st bead_repo_name <<< "$(bdjson show "$id" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
d = d if isinstance(d, list) else [d]
if not d: raise SystemExit
i = d[0]
repo = next((l[5:] for l in (i.get("labels") or []) if l.startswith("repo:")), sys.argv[1])
print(i.get("status", "-"), repo)' "$(spira_home_repo)" 2>/dev/null)"
        [ "${st:-}" = "closed" ] || continue

        # THE BRANCH BEING HERE IS NOT EVIDENCE THAT IT BELONGS HERE. A branch is only landed
        # in the repository its BEAD names; a ref that says otherwise is a bug elsewhere, and
        # merging it anyway would push one repository's work into another repository's main —
        # the silent wrong-repository failure this whole change exists to make impossible. It
        # must not be talked out of that by a plausible-looking ref.
        bead_repo_path="$(repo_root "${bead_repo_name:-}")" || bead_repo_path=""
        if [ "$bead_repo_path" != "$repo" ]; then
            log "CHECK6 $id: $br is in $name but the bead names repo:${bead_repo_name:-?} — not landing it here"
            continue
        fi
        # ANCESTRY IS THE WHOLE QUESTION. A branch already merged into main has nothing to
        # land; re-merging it is a no-op that still logs an ACT, and that
        # re-landed spira/sp-stranded on every pass for twenty minutes. Reaping the ref is
        # CHECK 6b's job, not this one's.
        if git -C "$repo" merge-base --is-ancestor "$br" "$base" 2>/dev/null; then
            log "$br is already an ancestor of $base — nothing to land"
            continue
        fi

        # NEVER REBASE UNDER A LIVE AEON. Rebasing rewrites the commits beneath a working
        # tree, so doing it while an aeon is inside destroys work that exists in exactly one
        # place. The bead is closed here, which SHOULD mean nobody is home — "should" is not
        # "is", the aeon runs on past its close to its own verdict step, and the check costs
        # one /proc read. If someone is home, this branch is simply landed on the next pass.
        if holder_alive "$id"; then
            log "CHECK6 $id: a live aeon still holds $br — deferring the land"
            continue
        fi

        # A branch already sent under a mode that leaves it standing is not re-sent. Checked
        # before the rebase, because rebasing an open pull request's branch on every pass
        # would rewrite it under its own reviewer.
        tip="$(git -C "$repo" rev-parse "$br" 2>/dev/null)"
        if [ "$mode" != push ] && submitted "$id" "$tip"; then
            continue
        fi

        if ! rebase_branch "$br" "$base" "$repo" "$name"; then
            bdq reopen "$id" >/dev/null 2>&1
            bdq note "$id" "Reopened by sentinel: $br does not rebase onto $base in $name; conflicts in ${REBASE_CONFLICTS:-unknown}. A merge conflict is not an escalation — the next aeon is handed the rebase and must resolve it." >/dev/null 2>&1
            progress "reopened $id — does not rebase onto $base"
            continue
        fi
        tip="$(git -C "$repo" rev-parse "$br" 2>/dev/null)"

        # THE NOTE CARRIES THE GATE'S OWN WORDS. A bead reopened with "failed the landing
        # gate" tells its next aeon nothing it can act on, and after three of those the bead
        # poisons and reaches the operator with a reason that is not a reason. The gate already
        # distinguishes a branch's own fault from a repository whose gate fails against its
        # base; that distinction is worthless if it stops at a log nobody reads.
        if ! gate_out="$("$SPIRA_HOME/gate.sh" "$br" "$name" 2>&1)"; then
            bdq reopen "$id" >/dev/null 2>&1
            bdq note "$id" "Reopened by sentinel: branch $br failed $name's landing gate.

$(printf '%s' "$gate_out" | tail -20)" >/dev/null 2>&1
            progress "reopened $id — failed the gate"
            log "CHECK6 $id: gate output — $(printf '%s' "$gate_out" | tail -3 | tr '\n' ' ')"
            continue
        fi

        case "$mode" in
        pr)
            if land_pr "$repo" "$br" "$id" "$base"; then
                mark_submitted "$id" "$tip" pr
                progress "opened a pull request for $br in $name"
            else
                mark_submitted "$id" "$tip" failed
            fi
            ;;
        hold)
            bdq note "$id" "Gated and held: $br passed $name's landing gate. Spira does not advance $name's $base_branch. Merge it by hand when you are ready — nothing else will." >/dev/null 2>&1
            mark_submitted "$id" "$tip" hold
            act "gated and held $br in $name — nothing here advances $base"
            ;;
        *)
            # A MERGE CONFLICT AND A REJECTED PUSH ARE NOT THE SAME FAILURE. The first is a
            # real disagreement the next aeon must resolve; the second only means the base
            # moved between our fetch and our push, and the fix is to fetch again and retry.
            # Conflating them reopened finished work that merged perfectly: law-cron pushes
            # the statute synthesis every four hours and export-beads the mirror every six,
            # so this raced roughly six times a day and each race cost a bead an attempt
            # toward poison.
            merged=0; pushed=0
            if git -C "$land" merge --no-edit -q -m "spira: land $id" "$br" 2>/dev/null; then
                merged=1
                for attempt in 1 2 3; do
                    if git -C "$land" push -q "$base_remote" "landing:$base_branch" 2>/dev/null; then pushed=1; break; fi
                    # Rejected: someone else advanced the base. Rebase onto it and try again.
                    git -C "$land" fetch -q "$base_remote" 2>/dev/null
                    git -C "$land" rebase -q "$base" >/dev/null 2>&1 || { git -C "$land" rebase --abort 2>/dev/null; break; }
                    log "landing: push rejected, $base moved — retry $attempt"
                done
            fi
            if [ "$merged" = 1 ] && [ "$pushed" = 1 ]; then
                # The reap belongs to CHECK 6b, not here. This line used to be
                # `git branch -q -D "$br" 2>/dev/null`, which git REFUSES while the aeon's
                # worktree still holds the branch — so it never once succeeded, the branch
                # survived, and the next pass re-landed it and counted the action again:
                #   06:29:33 ACT landed spira/sp-stranded
                #   06:31:35 ACT landed spira/sp-stranded
                # `acted` was therefore never 0 and CHECK 8 could never fire, which is the
                # CHECK 2 false-action bug arriving by a second route.
                progress "landed $br"
                # ADVANCE THE CHECKOUT HUMANS READ. (the operator, accepting sp-wud's own
                # stated default.) Landing pushes the base branch from the .landing worktree and nothing
                # ever pulled the home checkout, so the shared checkout stayed at whatever the last
                # human left — and every hand-run script and interactive session there read a past
                # state. It cost three wrong readings in one day, including one where I reported a
                # landed fix as missing because I was grepping a stale file.
                #
                # --ff-only, and only when clean and on the base branch: this must never clobber an
                # interactive session's work. Silence when it declines is correct; the next pass
                # tries again.
                #
                # THE REPOSITORY BEING LANDED, not $REPO. This said $REPO — the HOME checkout —
                # inside a function that runs once per repository, so landing a branch in any
                # other repository would have fast-forwarded brain instead of the one that
                # just moved. It is only ever reached in `push` mode, which today is brain
                # alone, which is exactly why it could sit here looking correct.
                if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ] \
                   && [ "$(git -C "$repo" branch --show-current 2>/dev/null)" = "$base_branch" ]; then
                    git -C "$repo" merge --ff-only -q "$base" 2>/dev/null \
                        && log "fast-forwarded $name's checkout to $base"
                fi
            elif [ "$merged" = 1 ]; then
                # Merged fine, could not push after three rebases. Nothing is wrong with the
                # work; leave the bead closed and let the next pass land it.
                git -C "$land" reset -q --hard "$base" 2>/dev/null
                log "landing: $br merges clean but push kept losing the race — retrying next pass"
            else
                git -C "$land" merge --abort 2>/dev/null
                bdq reopen "$id" >/dev/null 2>&1
                bdq note "$id" "Reopened by sentinel: branch $br conflicts with $base. A merge conflict is not an escalation — rebase and finish." >/dev/null 2>&1
                progress "reopened $id — branch conflicts with $base"
            fi
            ;;
        esac
    done
    return 0
}

for repo_name in $(spira_repos); do
    land_repo "$repo_name"
done

log "landing: pass complete — $n_branches branch(es) seen, $n_prog movement(s)"
