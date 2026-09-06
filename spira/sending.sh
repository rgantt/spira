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
# Bead status. Routed through one function so a destructive program can be tested without a
# live database: a reaper whose only test environment is production is a reaper nobody dares
# run. `--status-from` is also the honest manual entry point — it says exactly what the
# reaper believes about each bead.
# --------------------------------------------------------------------------------------
declare -A STATUS_MAP=()
if [ -n "$STATUS_FROM" ]; then
    while IFS=$'\t' read -r sid sst; do
        [ -n "${sid:-}" ] && STATUS_MAP["$sid"]="${sst:-}"
    done < <(if [ "$STATUS_FROM" = - ]; then cat; else cat "$STATUS_FROM"; fi)
fi

bead_status() {          # bead_status <id> -> open|in_progress|blocked|closed|""
    if [ -n "$STATUS_FROM" ]; then printf '%s' "${STATUS_MAP[$1]:-}"; return; fi
    bdjson show "$1" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
d = d if isinstance(d, list) else [d]
print(d[0].get("status", "") if d else "")' 2>/dev/null
}

# --------------------------------------------------------------------------------------
# Liveness. A bead whose aeon is still running must never be reaped out from under it, and
# there are two independent witnesses to that, because either alone has a blind spot:
# `holder_alive` (lib.sh) reads the pidfile, which is absent for the seconds between
# `bd ready --claim` and the aeon writing it, and `bead_status` reads a status that is stale
# for as long as it takes a killed aeon's lease to be reclaimed. Requiring BOTH to say
# "nobody is here" costs one skipped pass and buys the guarantee.
# --------------------------------------------------------------------------------------

reaped=0; failed=0
LANDREF=""

# --------------------------------------------------------------------------------------
# reap <id> <branch> — remove the worktree, then the branch, then the remote branch, then
# verify. Order matters: the branch cannot be deleted while a worktree holds it, which is
# the entire bug this file exists for.
# --------------------------------------------------------------------------------------
reap() {
    local id="$1" br="$2" w
    # Re-check liveness immediately before acting. The sentinel summons aeons in the same
    # pass that lands branches, so the gap between deciding and doing is a real window.
    if holder_alive "$id"; then say "HELD   $id  an aeon appeared mid-reap"; return 0; fi

    w="$(worktree_of "$br" "$REPO")"
    if [ -n "$w" ]; then
        salvage "$id" "$w"
        git -C "$REPO" worktree remove --force "$w" 2>/dev/null \
            || { rm -rf "$w"; git -C "$REPO" worktree prune 2>/dev/null; }
    fi
    git -C "$REPO" branch -D "$br" >/dev/null 2>&1

    # VERIFY. `git branch -D` failing silently is the whole reason this program exists; a
    # reaper that trusts its own exit status inherits the bug it was written to fix.
    if git -C "$REPO" show-ref --verify -q "refs/heads/$br"; then
        say "FAILED $id  branch $br survived deletion: $(
             git -C "$REPO" branch -D "$br" 2>&1 | head -1)"
        failed=$((failed+1)); return 1
    fi
    if [ -n "$w" ] && [ -e "$w" ]; then
        say "FAILED $id  worktree $w survived removal"
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
    local name="$1" br id st n w brs rem
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

        if holder_alive "$id"; then
            say "HELD   $id  a live aeon holds it"; continue
        fi
        st="$(bead_status "$id")"
        if [ "$st" = in_progress ]; then
            say "HELD   $id  in_progress — the lease has not been released"; continue
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
        holder_alive "$id" && continue
        if [ "$DRY" = 1 ]; then say "WOULD  $id  remove orphaned worktree $w"; continue; fi
        salvage "$id" "$w"
        git -C "$REPO" worktree remove --force "$w" 2>/dev/null || rm -rf "$w"
        reaped=$((reaped+1))
        say "REAPED $id  orphaned worktree (branch $br is gone)"
    done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

    # Registrations whose directory a human already deleted. Harmless, but they accumulate
    # and make `git worktree list` unreadable, which is how the real ones get missed.
    [ "$DRY" = 1 ] || git -C "$REPO" worktree prune 2>/dev/null
    return 0
}

# ======================================================================================
# THE LEGACY TREES. `.landing` and `.rebase` were single, unsuffixed and registered against
# whichever repository happened to create them; they are `.landing.<repo>` and
# `.rebase.<repo>` now. The old pair cannot serve a second repository and nothing will ever
# check anything out in them again, so retire them once rather than leaving two permanent
# registrations that make `git worktree list` unreadable.
# ======================================================================================
[ "$DRY" = 1 ] || for legacy in "$WORKTREES/.landing" "$WORKTREES/.rebase"; do
    [ -e "$legacy" ] || continue
    for r in $(spira_repos); do
        rp="$(repo_root "$r")" || continue
        git -C "$rp" worktree remove --force "$legacy" 2>/dev/null && break
    done
    rm -rf "$legacy" 2>/dev/null
    say "RETIRED $(basename "$legacy")  superseded by the per-repository tree"
done

for repo_name in $(spira_repos); do
    sweep_repo "$repo_name"
done

[ "$DRY" = 1 ] || log "sending: $reaped reaped, $failed failed"
[ "$failed" -eq 0 ]
