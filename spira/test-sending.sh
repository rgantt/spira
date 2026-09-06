#!/usr/bin/env bash
#
# test-sending.sh — every disposition the reaper can reach, against a real git repo.
#
#   ./test-sending.sh
#
# These are real repositories with real worktrees and a real bare remote, not fixtures,
# because every claim sending.sh makes is a claim about git's behaviour: that a branch held
# by a worktree cannot be deleted, that `merge-base --is-ancestor` is the landed predicate,
# that a forced worktree removal takes the directory with it. A mocked git would assert only
# that the mock agrees with the author.
#
# The negatives carry the weight. A reaper that fails to delete something leaves a branch
# lying around; a reaper that deletes the wrong thing destroys work that exists in exactly
# one place. So the unlanded, held and in-progress cases are each asserted twice — the
# branch survives AND its commit is still reachable.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want() {   # want <name> <substring> <output>
    [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"
}
nowant() {
    [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"
}
has_branch()  { git -C "$REPO" show-ref --verify -q "refs/heads/spira/$1"; }
has_commit()  { git -C "$REPO" cat-file -e "$1^{commit}" 2>/dev/null; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
# `-b main` ON THE BARE TOO. Without it HEAD names `refs/heads/master`, which nothing here
# ever pushes, so the remote publishes a default branch that does not exist — a stand-in for
# a broken remote rather than for a clone. It passed only while nothing asked the repository
# what its default branch was.
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree" "$SH"

# ITS OWN SPIRA_HOME, AND THEREFORE ITS OWN repo-map. Without one, SPIRA_HOME defaults to the
# INSTALLED harness directory and this suite swept every REAL repository in the map:
# it fetched them, and it printed a disposition for another repository's live branch belonging to
# an aeon that was still working it. A test that reaches production checkouts is one status
# file away from reaping real work.
cp "$HERE/sending.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$SH/"
cat > "$SH/repo-map" <<MAP
brain | $REPO | push | origin/main | |
MAP

sending() {   # sending <args...> — one pass with the test's status map
    SPIRA_HOME="$SH" SPIRA_REPO="$REPO" SPIRA_RUN="$RUN" SPIRA_DB=/nonexistent-spira-db \
        "$SH/sending.sh" --no-fetch --status-from "$TMP/status" "$@" 2>&1
}

# A bead's branch and worktree, exactly as aeon.sh makes them.
aeon_branch() {   # aeon_branch <id> [commit-message]
    local id="$1" msg="${2:-}"
    git -C "$REPO" worktree add -q -b "spira/$id" "$RUN/worktree/$id" main
    if [ -n "$msg" ]; then
        echo "$id" > "$RUN/worktree/$id/$id.txt"
        git -C "$RUN/worktree/$id" add -A
        git -C "$RUN/worktree/$id" commit -q -m "$msg"
    fi
}
land() {          # land <id> — merge the branch to origin/main the way CHECK 6 does
    git -C "$REPO" checkout -q main
    git -C "$REPO" merge -q --no-edit -m "spira: land $1" "spira/$1"
    git -C "$REPO" push -q origin main
}
status() { printf '%s\t%s\n' "$@" > "$TMP/status"; }

# ======================================================================================
# The bug this program exists to fix, reproduced first. Assert that git really does refuse,
# so the rest of the suite is testing a fix to a defect that is present rather than a
# defence against a hazard that was never real (law-seen-red-must-be-seen-in-ci).
# ======================================================================================
echo "the defect:"
aeon_branch sp-repro "feat: sp-repro — work"
land sp-repro
out="$(git -C "$REPO" branch -D spira/sp-repro 2>&1)"
want "git refuses to delete a branch a worktree holds" "used by worktree" "$out"
has_branch sp-repro && ok "the branch survives the old cleanup" \
                    || bad "the branch survives the old cleanup" "it was deleted"

# ======================================================================================
echo
echo "sending.sh:"
# ======================================================================================

# -- landed: the whole point ------------------------------------------------------------
status sp-repro closed
out="$(sending)"
want "landed branch is reaped"        "REAPED sp-repro" "$out"
has_branch sp-repro && bad "landed branch is gone" "it survived" || ok "landed branch is gone"
[ -e "$RUN/worktree/sp-repro" ] && bad "landed worktree is gone" "it survived" \
                                || ok "landed worktree is gone"
nowant "the reap is not reported as failed" "FAILED" "$out"
out="$(sending)"
nowant "a reaped branch is not reaped twice" "sp-repro" "$out"

# -- unlanded: the expensive mistake ----------------------------------------------------
aeon_branch sp-open "feat: sp-open — unlanded work"
tip="$(git -C "$REPO" rev-parse spira/sp-open)"
status sp-open closed          # CLOSED, and still not landed: the status must not decide
out="$(sending)"
want "unlanded branch is kept"          "KEEP   sp-open" "$out"
want "the reason names what is missing" "1 commit(s) not in" "$out"
has_branch sp-open && ok "unlanded branch survives" || bad "unlanded branch survives" "deleted"
has_commit "$tip"  && ok "unlanded work survives"   || bad "unlanded work survives" "unreachable"

# -- in_progress: someone still holds the lease ------------------------------------------
land sp-open
status sp-open in_progress
out="$(sending)"
want "in_progress is held, even once landed" "HELD   sp-open" "$out"
has_branch sp-open && ok "an in_progress branch survives" \
                   || bad "an in_progress branch survives" "deleted"

# -- a live aeon: the pidfile witness ----------------------------------------------------
# A process that is genuinely alive and whose argv contains aeon.sh, which is what
# aeon_alive checks — a sleep would be alive but not an aeon, and would prove nothing.
cp /bin/sleep "$TMP/aeon.sh"; "$TMP/aeon.sh" 30 & LIVE=$!
echo "$LIVE" > "$RUN/aeon-builder-sp-open.pid"
status sp-open closed
out="$(sending)"
want "a live aeon holds its branch" "HELD   sp-open  a live aeon" "$out"
has_branch sp-open && ok "a held branch survives" || bad "a held branch survives" "deleted"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

# A dead pid in the pidfile is not a holder; otherwise a crashed aeon would pin its branch
# forever, and the leak this program removes would come straight back.
echo 999999 > "$RUN/aeon-builder-sp-open.pid"
out="$(sending)"
want "a stale pidfile does not hold a branch" "REAPED sp-open" "$out"
rm -f "$RUN/aeon-builder-sp-open.pid"

# -- an empty branch: an aeon that produced nothing --------------------------------------
aeon_branch sp-empty
status sp-empty open
out="$(sending)"
want "an empty branch is reaped" "REAPED sp-empty" "$out"
[ -e "$RUN/worktree/sp-empty" ] && bad "its stale worktree is gone" "survived" \
                                || ok "its stale worktree is gone"

# -- dirty worktree: force, but salvage first --------------------------------------------
aeon_branch sp-dirty "feat: sp-dirty — work"
land sp-dirty
echo 'half-written' > "$RUN/worktree/sp-dirty/sp-dirty.txt"
echo 'scratch'      > "$RUN/worktree/sp-dirty/untracked.txt"
status sp-dirty closed
out="$(sending)"
want "a dirty worktree is still reaped" "REAPED sp-dirty" "$out"
want "its diff is salvaged"             "reaped/sp-dirty.patch" "$out"
want "the salvaged diff has the content" "half-written" "$(cat "$RUN/reaped/sp-dirty.patch")"
want "untracked files are at least named" "untracked.txt" "$(cat "$RUN/reaped/sp-dirty.patch")"

# -- an orphaned worktree ----------------------------------------------------------------
# The interrupted-reap state: branch gone, worktree left. aeon.sh reuses any directory that
# looks like a worktree, so this one would be handed to the next aeon for that bead.
aeon_branch sp-orphan "feat: sp-orphan — work"
land sp-orphan
git -C "$REPO" worktree list --porcelain | grep -q 'sp-orphan' \
    || bad "fixture" "sp-orphan worktree was not registered"
# update-ref deletes the ref without consulting worktrees, which is precisely how the state
# arises: the branch goes and the worktree stays.
git -C "$REPO" update-ref -d refs/heads/spira/sp-orphan
has_branch sp-orphan && bad "fixture" "the orphan branch was not actually deleted"
status sp-orphan closed
out="$(sending)"
want "an orphaned worktree is removed" "orphaned worktree" "$out"
[ -e "$RUN/worktree/sp-orphan" ] && bad "the orphan directory is gone" "survived" \
                                 || ok "the orphan directory is gone"

# -- a reap that cannot complete says so ---------------------------------------------------
# The failure this whole program is a response to: a deletion that does not happen and is
# reported as though it had. A locked worktree is the realistic way to reach it — `worktree
# remove` refuses, `worktree prune` skips locked entries, so the registration survives and
# `git branch -D` cannot succeed. The reaper must report FAILED and exit non-zero rather
# than count an action it did not take.
aeon_branch sp-stuck "feat: sp-stuck — work"
land sp-stuck
git -C "$REPO" worktree lock "$RUN/worktree/sp-stuck"
status sp-stuck closed
out="$(sending)"; rc=$?
want "a reap that cannot complete is FAILED" "FAILED sp-stuck" "$out"
want "and it names why"                      "used by worktree" "$out"
nowant "and is not also counted as reaped"   "REAPED sp-stuck" "$out"
[ "$rc" -ne 0 ] && ok "a failed reap exits non-zero" || bad "a failed reap exits non-zero" "rc=$rc"
git -C "$REPO" worktree unlock "$RUN/worktree/sp-stuck"
out="$(sending)"
want "and it is reaped once unstuck" "REAPED sp-stuck" "$out"

# -- the harness's own worktrees are permanent --------------------------------------------
# .landing.<repo> is detached on purpose and is recreated by CHECK 6 every pass, .rebase.<repo>
# replays a stale branch and .gate.<repo> is where a branch stands trial. Reaping any of them
# would be a pointless churn of the trees the sentinel needs to exist — and the skip is on the
# LEADING DOT rather than a list of names, because there is now one of each per repository and
# a hand-maintained skip-list is one that eventually deletes the tree the next pass needed.
own="$(basename "$REPO")"
for w in ".landing.$own" ".rebase.$own" ".gate.$own"; do
    git -C "$REPO" worktree add -q --detach "$RUN/worktree/$w" main
done
: > "$TMP/status"
out="$(sending)"
for w in ".landing.$own" ".rebase.$own" ".gate.$own"; do
    [ -e "$RUN/worktree/$w" ] && ok "$w is never reaped" || bad "$w is never reaped" "removed"
done

# -- and the unsuffixed legacy pair is retired exactly once --------------------------------
# `.landing` and `.rebase` were registered against whichever repository created them first,
# so they cannot serve a second one; leaving them standing would mean two permanent
# registrations that nothing will ever check anything out in again.
git -C "$REPO" worktree add -q --detach "$RUN/worktree/.landing" main
out="$(sending)"
want "the legacy landing tree is retired" "RETIRED .landing" "$out"
[ -e "$RUN/worktree/.landing" ] && bad "the legacy landing tree is gone" "still there" \
                                || ok "the legacy landing tree is gone"
out="$(sending)"
nowant "and is not retired twice" "RETIRED .landing" "$out"

# -- the shared checkout is never touched --------------------------------------------------
out="$(sending)"
nowant "the shared checkout is not a candidate" "$REPO " "$out"
[ -e "$REPO/.git" ] && ok "the shared checkout survives" || bad "the shared checkout survives" "gone"

# -- --dry-run changes nothing --------------------------------------------------------------
aeon_branch sp-dry "feat: sp-dry — work"
land sp-dry
status sp-dry closed
out="$(sending --dry-run)"
want "dry run says what it would do" "WOULD  sp-dry" "$out"
has_branch sp-dry && ok "dry run deletes nothing" || bad "dry run deletes nothing" "branch gone"

# -- one bead by id ---------------------------------------------------------------------
aeon_branch sp-other "feat: sp-other — work"
land sp-other
printf 'sp-dry\tclosed\nsp-other\tclosed\n' > "$TMP/status"
out="$(sending sp-dry)"
want "a single-bead reap acts on that bead"   "REAPED sp-dry" "$out"
nowant "a single-bead reap leaves the others" "sp-other" "$out"
has_branch sp-other && ok "the other branch survives" || bad "the other branch survives" "deleted"

# -- a stale origin/main keeps branches rather than losing them ----------------------------
# The fetch-failed case. sending.sh compares against origin/main; if that ref is behind, a
# landed branch reads as unlanded and is KEPT. Asserting the bias explicitly, because the
# opposite bias would delete work on a network blip.
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse main~1)"
printf 'sp-other\tclosed\n' > "$TMP/status"
out="$(sending)"
want "a stale origin/main keeps the branch" "KEEP   sp-other" "$out"
has_branch sp-other && ok "no work is lost to a stale remote" \
                    || bad "no work is lost to a stale remote" "deleted"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
