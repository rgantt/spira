#!/usr/bin/env bash
#
# sending.sh — the Sending: send finished work out properly. Reap the branch and the
# worktree of every bead whose work has landed, and nothing else.
#
#   sending.sh                     one reaping pass (what the sentinel runs)
#   sending.sh --dry-run           print each branch's disposition, change nothing
#   sending.sh <bead-id>           reap exactly one bead's branch and worktree
#   sending.sh --status-from <f>   read `id<TAB>status` from a file instead of bd (tests)
#
# WHAT THIS REPLACES
# ------------------
# `gt convoy land` step 3, "cleans up polecat worktrees associated with the convoy's
# tracked issues". Steps 2, 4 and 5 — all-closed, close the convoy, notify — are
# pilgrimage.sh; this is the part that was left. The design ledger predicted this
# responsibility would vanish with polecat worktrees, and it did not: the aeon runner
# reintroduced worktrees on purpose, because the first supervised aeon checked its branch
# out in the shared tree and swept the interactive session's files into its commit. Every
# aeon therefore leaves a branch AND a worktree behind, and until now nothing removed
# either.
#
# THE DEFECT THIS EXISTS TO FIX, MEASURED
# ---------------------------------------
# CHECK 6 in the sentinel ended a successful land with `git branch -q -D "$br" 2>/dev/null`.
# git REFUSES to delete a branch that a worktree has checked out —
#
#     error: cannot delete branch 'feat' used by worktree at '/tmp/.../wt'
#
# — and the aeon's own worktree is always holding exactly that branch. So the delete could
# never succeed, the error went to /dev/null, and the branch survived. The next pass found
# the same closed bead with the same branch, merged it again (already up to date), pushed
# again (a no-op) and counted another action. From .runtime/spira/sentinel.log:
#
#     2026-09-05T06:29:33Z spira: ACT landed spira/sp-stranded
#     2026-09-05T06:31:35Z spira: ACT landed spira/sp-stranded
#
# That is not merely untidy. `acted` was never 0, and CHECK 8 — the judgement tier — fires
# only when `acted` is 0, so a harness that re-lands one branch forever can never notice it
# is starved. It is the same false-action bug already commented at CHECK 2, arriving by a
# different route: a cleanup step that does not verify its own effect reports success on
# the strength of having tried.
#
# So every deletion here is CHECKED AFTER THE FACT, and a branch that survives its own
# deletion is reported FAILED rather than counted.
#
# WHAT MAY BE DELETED
# -------------------
# Only a branch every one of whose commits is already an ancestor of its repository's base
# ref. Ancestry,
# never a tip comparison and never the bead's status (law-closed-is-not-landed): CLOSED is a
# claim about a database, and the question here is whether deleting this ref can lose work.
# If the remote is unreachable the fetch fails, the base ref is stale, and a freshly-landed
# branch reads as unlanded and is KEPT — the fetch failure biases toward hoarding branches,
# which is recoverable, rather than toward deleting work, which is not.
#
# An unlanded branch is never deleted, whatever its bead says. That is CHECK 6's problem to
# land or reopen, not this program's to tidy away.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# EVERY REPOSITORY THE HARNESS MANAGES, not one. A branch lives in the checkout the aeon
# cut it from, and an aeon's checkout now comes from its bead's `repo:` label — so a reaper
# that swept one repository would leave every other repository's landed branches and
# worktrees standing forever, and would report a clean pass while doing it. $REPO is set per
# repository by the sweep below; nothing here may read it before then.
WORKTREES="$SPIRA_RUN/worktree"
REPO=""

DRY=0; FETCH=1; ONLY=""; STATUS_FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY=1 ;;
        --no-fetch)    FETCH=0 ;;
        --status-from) STATUS_FROM="${2:?--status-from needs a file}"; shift ;;
        -*)            die "unknown flag: $1" ;;
        *)             ONLY="$1" ;;
    esac
    shift
done

say() { printf '%s\n' "$*"; }

# --------------------------------------------------------------------------------------
# Bead status and liveness both live in lib.sh now, at the one place a tree or a branch can
# be destroyed. They were here, and being here is what made them advisory: this file asked
# for two witnesses in PASS 1 and one in PASS 2, and every other deleter in the harness
# asked for none. A rule stated where the deletion happens cannot be skipped by a caller
# that took another route (see the DESTRUCTION section of lib.sh).
#
# `--status-from` is still the seam a suite drives the status witness through, and the
# honest manual entry point: it says exactly what the reaper believes about each bead.
# --------------------------------------------------------------------------------------
[ -n "$STATUS_FROM" ] && spira_status_seam "$STATUS_FROM"


reaped=0; failed=0
LANDREF=""

# --------------------------------------------------------------------------------------
# reap <id> <branch> — remove the worktree, then the branch, then the remote branch, then
# verify. Order matters: the branch cannot be deleted while a worktree holds it, which is
# the entire bug this file exists for.
# --------------------------------------------------------------------------------------
reap() {
    local id="$1" br="$2" w held
    # Re-check liveness immediately before acting. The sentinel summons aeons in the same
    # pass that lands branches, so the gap between deciding and doing is a real window. Both
    # witnesses again, not just the pidfile: this recheck used to ask only `holder_alive`,
    # which is the witness with the documented blind spot.
    if held="$(spira_holder_witnesses "$id")"; then
        say "HELD   $id  $held (mid-reap)"; return 0
    fi

    w="$(worktree_of "$br" "$REPO")"
    if [ -n "$w" ] && ! spira_destroy_worktree "$id" "$w" "$REPO" "landed in $LANDREF"; then
        say "FAILED $id  worktree $w was not removed — see $SPIRA_REAPLOG"
        failed=$((failed+1)); return 1
    fi

    # VERIFY. `git branch -D` failing silently is the whole reason this program exists; a
    # reaper that trusts its own exit status inherits the bug it was written to fix. The
    # verification is inside spira_destroy_branch, which re-reads the ref after the delete.
    SPIRA_DESTROY_ERR=""
    if ! spira_destroy_branch "$id" "$br" "$REPO" "landed in $LANDREF"; then
        say "FAILED $id  branch $br survived deletion: ${SPIRA_DESTROY_ERR:-refused, see $SPIRA_REAPLOG}"
        failed=$((failed+1)); return 1
    fi

    # Under `pr` the branch IS pushed, and under `push` only the landing branch is, so this
    # is defensive rather than routine. It is guarded on existence because a delete of a ref
    # that was never there is an error the caller would have to learn to ignore — and it
    # names the base's own remote rather than assuming `origin`.
    local rem; rem="$(ref_remote "$LANDREF")" || rem=""
    if [ -n "$rem" ] && git -C "$REPO" rev-parse --verify -q "$rem/$br" >/dev/null 2>&1; then
        git -C "$REPO" push -q "$rem" --delete "$br" 2>/dev/null \
            && say "  deleted $rem/$br"
    fi

    # The aeon's session log is deliberately KEPT. Sentinel CHECK 5 uses the existence of
    # .runtime/spira/<id>.log to tell a bead an aeon worked from one a human closed by hand,
    # so deleting it here would silently disable the closed-but-not-landed check for exactly
    # the beads that check exists for.
    reaped=$((reaped+1))
    say "REAPED $id  branch and worktree"
}

# ======================================================================================
# THE SWEEP — one repository, both passes. Called once per repository the harness manages,
# with $REPO and $LANDREF set for it.
#
# The landing reference is per repository and is chosen by `spira_landref`, the one place
# that choice is made, so the ref a branch is CUT from and the ref it is judged against can
# never drift apart. It is not assumed to be `main` — three of the seven repositories here
# default to something else — and a repository whose answer cannot be established is skipped
# rather than swept against a ref that does not exist. `merge-base --is-ancestor` against a
# missing ref returns non-zero, which reads as "unlanded", so that failure was survivable in
# this file and catastrophic in CHECK 6; skipping loudly is what makes it visible in both.
# ======================================================================================
sweep_repo() {
    local name="$1" br id n w brs rem held
    REPO="$(repo_root "$name")" || { say "SKIP   $name  repo-map has no path for it"; return 0; }
    if [ ! -e "$REPO/.git" ]; then say "SKIP   $name  $REPO is not a git checkout"; return 0; fi

    # ----------------------------------------------------------------------------------
    # PASS 1 — every spira/* branch gets a disposition. Exactly one of them.
    #
    # THE LOCAL QUESTION IS ASKED FIRST, AND THE FETCH IS PAID FOR ONLY IF THE ANSWER IS
    # YES. This runs inside every sentinel pass, two minutes apart, and now over seven
    # repositories rather than one — an unconditional fetch of each would be four thousand
    # round trips a day to GitHub to learn nothing about six repositories with no Spira
    # branch in them. Refs are a local read; ancestry is the only question that needs a
    # current base ref.
    # ----------------------------------------------------------------------------------
    brs="$(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/spira/*' 2>/dev/null)"
    LANDREF="$(spira_landref "$REPO")" || {
        say "SKIP   $name  cannot resolve the ref it lands on — give it a \`base\` in repo-map"
        return 0; }
    # The base's OWN remote, not a literal `origin`: a remote need not be called that, so
    # fetch was a quiet no-op in the one repository nothing else here refreshes.
    if rem="$(ref_remote "$LANDREF")" && [ "$FETCH" = 1 ] && [ -n "$brs" ]; then
        git -C "$REPO" fetch -q "$rem" 2>/dev/null
    fi
    for br in $brs; do
        id="${br#spira/}"
        [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || [ "$ONLY" = "$br" ] || continue

        # ONE WITNESS FUNCTION, the same one every deleter asks. Asked separately here, this
        # pass had two witnesses and no positive control on either — an unreachable database
        # answers "not in_progress" exactly as an open bead does, and that reads as permission.
        if held="$(spira_holder_witnesses "$id")"; then
            say "HELD   $id  $held"; continue
        fi
        if ! git -C "$REPO" merge-base --is-ancestor "$br" "$LANDREF" 2>/dev/null; then
            n="$(git -C "$REPO" rev-list --count "$LANDREF..$br" 2>/dev/null || echo '?')"
            say "KEEP   $id  unlanded — $n commit(s) not in $LANDREF"; continue
        fi
        if [ "$DRY" = 1 ]; then
            say "WOULD  $id  reap branch $br$( [ -n "$(worktree_of "$br" "$REPO")" ] && printf ' and its worktree')"
            continue
        fi
        reap "$id" "$br"
    done

    # ----------------------------------------------------------------------------------
    # PASS 2 — orphaned worktrees. A worktree outlives its branch whenever a reap is
    # interrupted between the two deletions, and an orphan is not inert: aeon.sh reuses any
    # directory that already looks like a worktree, so the next aeon for that bead would be
    # handed a checkout of a branch that no longer exists.
    # ----------------------------------------------------------------------------------
    [ -n "$ONLY" ] && return 0
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        case "$w" in "$WORKTREES"/*) ;; *) continue ;; esac   # never the shared checkout
        # The harness's own trees are named with a leading dot and are permanent: .landing.*
        # lands, .rebase.* replays, .gate.* is where a branch stands trial. Listing them
        # individually was fine while there was one of each; there is now one of each PER
        # REPOSITORY, and a skip-list that has to be extended by hand is a skip-list that
        # eventually deletes the tree the next pass needed.
        case "$(basename "$w")" in .*) continue ;; esac
        id="$(basename "$w")"
        # Only branch-backed worktrees are ours to judge; a detached one under this
        # directory is something a human made and is left alone.
        br="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | python3 -c '
import sys
want = sys.argv[1]; path = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "): path = line[9:]
    elif line.startswith("branch ") and path == want:
        print(line[7:].removeprefix("refs/heads/")); break
' "$w" 2>/dev/null)"
        [ -n "$br" ] || continue
        git -C "$REPO" show-ref --verify -q "refs/heads/$br" && continue   # branch still exists
        # THE SAME TWO WITNESSES AS PASS 1. This asked only `holder_alive` — the one guard in
        # the file weaker than the rule the file states — and a missing branch is not evidence
        # that nobody is home: an aeon works for its first minutes with a branch that exists
        # only locally, and any prune that unregistered a live tree produces exactly this
        # shape. spira_destroy_worktree refuses on either witness and salvages before acting.
        if held="$(spira_holder_witnesses "$id")"; then
            say "HELD   $id  orphaned worktree kept — $held"; continue
        fi
        if [ "$DRY" = 1 ]; then say "WOULD  $id  remove orphaned worktree $w"; continue; fi
        spira_destroy_worktree "$id" "$w" "$REPO" "orphan: branch $br is gone" || {
            say "FAILED $id  orphaned worktree $w was not removed — see $SPIRA_REAPLOG"
            failed=$((failed+1)); continue; }
        reaped=$((reaped+1))
        say "REAPED $id  orphaned worktree (branch $br is gone)"
    done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

    # Registrations whose directory a human already deleted. Harmless, but they accumulate
    # and make `git worktree list` unreadable, which is how the real ones get missed.
    # Through the chokepoint, which repairs rather than prunes any entry whose directory is
    # still on disk, and names in the reap log every entry it really does drop.
    [ "$DRY" = 1 ] || spira_prune_worktrees "$REPO"
    return 0
}

# ======================================================================================
# THE LEGACY TREES. `.landing` and `.rebase` were single, unsuffixed and registered against
# whichever repository happened to create them; they are `.landing.<repo>` and
# `.rebase.<repo>` now. The old pair cannot serve a second repository and nothing will ever
# check anything out in them again, so retire them once rather than leaving two permanent
# registrations that make `git worktree list` unreadable.
# ======================================================================================
# These are DETACHED scratch trees the harness made for itself and no bead was ever worked in
# one, so the liveness witnesses will always say nobody is home — but they go through the
# chokepoint anyway rather than being exempted from it. An exemption is a second code path,
# and a second code path is what this whole section is a response to.
[ "$DRY" = 1 ] || for legacy in "$WORKTREES/.landing" "$WORKTREES/.rebase"; do
    [ -e "$legacy" ] || continue
    for r in $(spira_repos); do
        rp="$(repo_root "$r")" || continue
        spira_destroy_worktree "$(basename "$legacy")" "$legacy" "$rp" \
            "legacy harness tree, superseded by the per-repository one" && break
    done
    [ -e "$legacy" ] && continue     # nothing could remove it: say nothing rather than lie
    say "RETIRED $(basename "$legacy")  superseded by the per-repository tree"
done

for repo_name in $(spira_repos); do
    sweep_repo "$repo_name"
done

[ "$DRY" = 1 ] || log "sending: $reaped reaped, $failed failed"
[ "$failed" -eq 0 ]
