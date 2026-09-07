#!/usr/bin/env bash
#
# test-reap.sh — nothing destroys a live aeon's worktree or its branch.
#
#   ./test-reap.sh
#
# WHAT THIS SUITE IS THE ANSWER TO. A bead's worktree and its branch were both destroyed
# while its aeon was mid-edit and its lease was live, taking forty minutes of uncommitted
# work with them, writing no salvage and naming the bead in no log. It happened twenty times
# to the same bead before anyone read the attempt counter.
#
# So this suite does not test one caller. It tests the CHOKEPOINT — the section of lib.sh
# every removal now goes through — because the defect was never a bad guard, it was six
# deletion sites with six different guards, reachable by anything that sources lib.sh with
# the default environment. Each case asserts the refusal AND that the thing survived: a
# guard that returns non-zero while the tree is already gone has refused nothing.
#
# A REAL GIT REPOSITORY, real worktrees, real processes. Every claim here is a claim about
# what git and /proc do, and a mock would assert only that the mock agrees with the author.
#
# covers: spira/sending.sh spira/aeon.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
lives()  { [ -e "$2" ] && ok "$1" || bad "$1" "$2 is gone"; }
gone()   { [ -e "$2" ] && bad "$1" "$2 survived" || ok "$1"; }

TMP="$(mktemp -d)"
LIVE=""
cleanup() { [ -n "$LIVE" ] && kill "$LIVE" 2>/dev/null; chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; SH="$TMP/spira"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
mkdir -p "$RUN/worktree" "$SH"

# ITS OWN SPIRA_HOME, SPIRA_RUN AND repo-map, and they are ASSERTED below rather than
# assumed. A fixture that forgets one of these does not fail — it succeeds against the
# INSTALLED harness and the operator's real checkouts, which is how this suite's own subject
# matter came to happen (test-sending.sh's header records the same near miss).
# conf.sh travels with lib.sh: lib.sh resolves every path through it and refuses to run
# without it, so a fixture that copies one and not the other dies at source time.
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/sending.sh" "$SH/"
cat > "$SH/repo-map" <<MAP
fixture | $REPO | push | main | |
MAP
export SPIRA_HOME="$SH" SPIRA_REPO="$REPO" SPIRA_RUN="$RUN" SPIRA_DB=/nonexistent-spira-db
export SPIRA_REAPLOG="$RUN/reap.log"
. "$SH/lib.sh"

echo "the fixture is sealed:"
[ "$SPIRA_RUN" = "$RUN" ]           && ok "SPIRA_RUN is the fixture's"    || bad "SPIRA_RUN is the fixture's" "$SPIRA_RUN"
[ "$SPIRA_REAPLOG" = "$RUN/reap.log" ] && ok "the reap log is the fixture's" || bad "the reap log is the fixture's" "$SPIRA_REAPLOG"
case "$(repo_root fixture)" in "$REPO") ok "repo-map resolves to the fixture repo" ;;
                             *) bad "repo-map resolves to the fixture repo" "$(repo_root fixture)" ;; esac

# AND THE CHOKEPOINT IS ACTUALLY THERE. Nearly every case below asserts that a call was
# REFUSED, and a missing function also returns non-zero — so a harness without the guard
# would score a clean sweep of green refusals it never made. Establish that the thing being
# tested exists before believing anything it does not do.
for fn in spira_destroy_worktree spira_destroy_branch spira_prune_worktrees \
          spira_holder_witnesses spira_db_reachable salvage; do
    declare -F "$fn" >/dev/null || bad "the harness under test defines $fn" "it does not"
done
if [ "$fail" -ne 0 ]; then
    printf '\nrefusing to run: this harness has no deletion chokepoint, so every refusal\n'
    printf 'below would pass by accident. %d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

# A bead's branch and worktree, exactly as aeon.sh makes them.
tree_for() {   # tree_for <id> [uncommitted]
    local id="$1"
    git -C "$REPO" worktree add -q -b "spira/$id" "$RUN/worktree/$id" main
    if [ -n "${2:-}" ]; then
        echo 'forty minutes of it' > "$RUN/worktree/$id/new-file.txt"   # untracked
        git -C "$RUN/worktree/$id" commit -q --allow-empty -m "wip $id"
        echo 'edited' >> "$RUN/worktree/$id/tracked.txt"
        git -C "$RUN/worktree/$id" add tracked.txt
        git -C "$RUN/worktree/$id" commit -q -m "base $id"
        echo 'half-written' > "$RUN/worktree/$id/tracked.txt"
    fi
}
# A process that is genuinely alive and whose argv contains aeon.sh, which is what
# aeon_alive checks — a bare sleep would be alive but would prove nothing.
live_aeon_for() {   # live_aeon_for <id>
    cp /bin/sleep "$TMP/aeon.sh"; "$TMP/aeon.sh" 120 & LIVE=$!
    echo "$LIVE" > "$RUN/aeon-builder-$1.pid"
}
reaplog() { cat "$SPIRA_REAPLOG" 2>/dev/null; }
has_branch() { git -C "$REPO" show-ref --verify -q "refs/heads/spira/$1"; }
status() { spira_status_seam /dev/null; SPIRA_STATUS_MAP=(); while [ $# -gt 1 ]; do SPIRA_STATUS_MAP["$1"]="$2"; shift 2; done; }

# ======================================================================================
echo
echo "witness 1 — a live aeon's pidfile:"
# ======================================================================================
tree_for sp-live wip
live_aeon_for sp-live
status sp-live open          # the bead says free; the process says otherwise
: > "$SPIRA_REAPLOG"
spira_destroy_worktree sp-live "$RUN/worktree/sp-live" "$REPO" "test" \
    && bad "a held worktree is refused" "the removal returned success" \
    || ok "a held worktree is refused"
lives "the held worktree survives"       "$RUN/worktree/sp-live"
lives "and the work inside it survives"  "$RUN/worktree/sp-live/new-file.txt"
want  "the refusal names the bead"       "sp-live" "$(reaplog)"
want  "and says who is home"             "a live aeon holds it" "$(reaplog)"

: > "$SPIRA_REAPLOG"
spira_destroy_branch sp-live "spira/sp-live" "$REPO" "test" \
    && bad "a held branch is refused" "the deletion returned success" \
    || ok "a held branch is refused"
has_branch sp-live && ok "the held branch survives" || bad "the held branch survives" "deleted"
want "the branch refusal names the bead" "sp-live" "$(reaplog)"

kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; LIVE=""
rm -f "$RUN/aeon-builder-sp-live.pid"

# ======================================================================================
echo
echo "witness 2 — the bead's own status:"
# ======================================================================================
# No pidfile at all: the window between `bd ready --claim` and the aeon writing one is
# seconds long and it is exactly when a fresh aeon is most vulnerable.
status sp-live in_progress
: > "$SPIRA_REAPLOG"
spira_destroy_worktree sp-live "$RUN/worktree/sp-live" "$REPO" "test" \
    && bad "an in_progress bead's worktree is refused" "removed" \
    || ok "an in_progress bead's worktree is refused"
lives "its worktree survives with no pidfile at all" "$RUN/worktree/sp-live"
want  "the refusal names the witness" "in_progress" "$(reaplog)"

# ======================================================================================
echo
echo "the status witness must be able to answer before its silence is believed:"
# ======================================================================================
# An unreachable database answers "not in_progress" exactly as a genuinely open bead does.
# The wrong one of those reads as permission (law-absence-needs-a-positive-control).
out="$(
    SPIRA_STATUS_SEAM=0 SPIRA_DB_OK="" SPIRA_BD=/bin/false
    spira_destroy_worktree sp-live "$RUN/worktree/sp-live" "$REPO" "test" && echo REMOVED
    cat "$SPIRA_REAPLOG"
)"
nowant "a dead database is not permission to delete" "REMOVED" "$out"
want   "and the refusal says the probe failed" "did not answer" "$out"
lives  "the worktree survives a dead database" "$RUN/worktree/sp-live"

# ======================================================================================
echo
echo "the fence — nothing outside the harness's own scratch directory:"
# ======================================================================================
mkdir -p "$TMP/elsewhere/precious"; echo real > "$TMP/elsewhere/precious/file"
status sp-elsewhere open
: > "$SPIRA_REAPLOG"
spira_destroy_worktree sp-elsewhere "$TMP/elsewhere/precious" "$REPO" "test" \
    && bad "a path outside SPIRA_RUN/worktree is refused" "removed" \
    || ok "a path outside SPIRA_RUN/worktree is refused"
lives "the outside directory survives" "$TMP/elsewhere/precious/file"
want  "and the refusal says why"       "is not under" "$(reaplog)"

# ======================================================================================
echo
echo "salvage runs first, carries everything, and its failure aborts the removal:"
# ======================================================================================
# THE POSITIVE CONTROL for every refusal above: with nobody home the same call must succeed,
# or the suite proves only that the guard is stuck shut.
status sp-live open
: > "$SPIRA_REAPLOG"
spira_destroy_worktree sp-live "$RUN/worktree/sp-live" "$REPO" "landed" \
    && ok "an unheld worktree IS removed" || bad "an unheld worktree IS removed" "refused"
gone "the unheld worktree is gone" "$RUN/worktree/sp-live"
want "the removal names the bead in the log" "sp-live" "$(reaplog)"
want "and records the removal"               "REMOVED" "$(reaplog)"

p="$(ls "$RUN"/reaped/sp-live.*.patch 2>/dev/null | head -1)"
[ -n "$p" ] && ok "the tracked diff was salvaged first" \
            || bad "the tracked diff was salvaged first" "no patch in $RUN/reaped"
want "the salvaged diff carries the content" "half-written" "$(cat "$p" 2>/dev/null)"
t="$(ls "$RUN"/reaped/sp-live.*.untracked.tar 2>/dev/null | head -1)"
[ -n "$t" ] && ok "untracked files are salvaged by CONTENT" \
            || bad "untracked files are salvaged by CONTENT" "no tar in $RUN/reaped"
want "and the content is really in there" "forty minutes of it" \
     "$(tar -xOf "$t" new-file.txt 2>/dev/null)"

# A second reap of the same bead must not overwrite the first salvage. One bead was reaped
# twenty times into one filename: nineteen salvages destroyed by the salvage machinery.
tree_for sp-live2 wip
mv "$RUN/reaped/$(basename "$p")" "$RUN/reaped/sp-live2.19700101T000000Z.patch"
echo keepme > "$RUN/reaped/sp-live2.19700101T000000Z.patch"
status sp-live2 open
spira_destroy_worktree sp-live2 "$RUN/worktree/sp-live2" "$REPO" "landed" >/dev/null
want "an earlier salvage is not overwritten" "keepme" \
     "$(cat "$RUN/reaped/sp-live2.19700101T000000Z.patch")"
[ "$(ls "$RUN"/reaped/sp-live2.*.patch | wc -l)" -ge 2 ] \
    && ok "each reap leaves its own salvage" || bad "each reap leaves its own salvage" "one file"

# A salvage that cannot be written must abort the removal, not be stepped over.
tree_for sp-nosalv wip
status sp-nosalv open
chmod a-w "$RUN/reaped"
: > "$SPIRA_REAPLOG"
spira_destroy_worktree sp-nosalv "$RUN/worktree/sp-nosalv" "$REPO" "landed" \
    && bad "a failed salvage aborts the removal" "it removed the tree anyway" \
    || ok "a failed salvage aborts the removal"
lives "the unsalvageable worktree survives" "$RUN/worktree/sp-nosalv"
want  "and the log says salvage is why"     "salvage failed" "$(reaplog)"
chmod u+w "$RUN/reaped"

# ======================================================================================
echo
echo "prune must not unregister a worktree whose directory is still on disk:"
# ======================================================================================
# The prunable case nobody expects: the DIRECTORY is intact and full of work, but the
# worktree's own `.git` file is missing or unreadable. Plain `git worktree prune` drops the
# registration, which frees the branch for `git branch -D` and leaves a live tree registered
# nowhere — precisely the orphan shape the Sending's second pass then removes.
tree_for sp-broken wip
mv "$RUN/worktree/sp-broken/.git" "$TMP/stashed-dotgit"
git -C "$REPO" worktree prune -n -v 2>&1 | grep -q sp-broken \
    && ok "git really would prune it (the hazard is real)" \
    || bad "git really would prune it (the hazard is real)" "prune -n does not list sp-broken"
: > "$SPIRA_REAPLOG"
spira_prune_worktrees "$REPO"
lives "the intact directory survives the prune" "$RUN/worktree/sp-broken/new-file.txt"
want  "and the repair is logged by name"        "sp-broken" "$(reaplog)"
git -C "$REPO" worktree list --porcelain | grep -q "$RUN/worktree/sp-broken" \
    && ok "its registration survives, so the branch stays protected" \
    || bad "its registration survives, so the branch stays protected" "unregistered"
out="$(git -C "$REPO" branch -D spira/sp-broken 2>&1)"
has_branch sp-broken && ok "and git still refuses to delete its branch" \
                     || bad "and git still refuses to delete its branch" "$out"
# The positive control: an entry whose directory really is gone is still pruned.
tree_for sp-vanished
rm -rf "$RUN/worktree/sp-vanished"
spira_prune_worktrees "$REPO"
git -C "$REPO" worktree list --porcelain | grep -q "$RUN/worktree/sp-vanished" \
    && bad "a genuinely missing worktree is still pruned" "the entry survived" \
    || ok "a genuinely missing worktree is still pruned"

# ======================================================================================
echo
echo "sending.sh, end to end — the orphan sweep is the guard that was weakest:"
# ======================================================================================
# PASS 2 asked only `holder_alive`, the witness with the documented blind spot, and it is
# reached whenever the branch is missing — which is the state a mis-prune produces and the
# state a brand-new aeon is briefly in. A live holder must stop it.
sending() {
    SPIRA_HOME="$SH" SPIRA_REPO="$REPO" SPIRA_RUN="$RUN" SPIRA_DB=/nonexistent-spira-db \
    SPIRA_REAPLOG="$SPIRA_REAPLOG" \
        "$SH/sending.sh" --no-fetch --status-from "$TMP/status" "$@" 2>&1
}
tree_for sp-orphan wip
# update-ref deletes the ref without consulting worktrees, which is exactly how the state
# arises: the branch goes and the worktree stays.
git -C "$REPO" update-ref -d refs/heads/spira/sp-orphan
live_aeon_for sp-orphan
printf 'sp-orphan\topen\n' > "$TMP/status"
: > "$SPIRA_REAPLOG"
out="$(sending)"
want "the orphan sweep refuses a held tree" "HELD   sp-orphan" "$out"
lives "the held orphan's directory survives" "$RUN/worktree/sp-orphan"
lives "and its uncommitted work survives"    "$RUN/worktree/sp-orphan/new-file.txt"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; LIVE=""
rm -f "$RUN/aeon-builder-sp-orphan.pid"

# The positive control: with the holder gone, the same sweep removes it.
out="$(sending)"
want "and removes it once nobody holds it" "REAPED sp-orphan" "$out"
gone "the unheld orphan is gone" "$RUN/worktree/sp-orphan"
want "every sending deletion is in the reap log" "sp-orphan" "$(reaplog)"
# An orphan's branch ref is gone, so its HEAD is unborn and `git diff HEAD` fails there.
# That is the case salvage matters most in, so assert the work came out anyway.
t2="$(ls "$RUN"/reaped/sp-orphan.*.untracked.tar 2>/dev/null | head -1)"
want "the orphan's untracked work was carried out first" "forty minutes of it" \
     "$(tar -xOf "${t2:-/dev/null}" new-file.txt 2>/dev/null)"

# An in_progress bead is refused by PASS 2 as well as PASS 1, with no pidfile in play.
tree_for sp-claimed wip
git -C "$REPO" update-ref -d refs/heads/spira/sp-claimed
printf 'sp-claimed\tin_progress\n' > "$TMP/status"
out="$(sending)"
lives "a freshly-claimed bead's orphan tree survives" "$RUN/worktree/sp-claimed"

# ======================================================================================
echo
echo "no seventh deletion site:"
# ======================================================================================
# The chokepoint is only worth anything while it is the ONLY way through. This is the fence
# that makes it so: a static sweep of the harness for the raw destructive verbs, with the
# handful of legitimate sites named individually. It binds whoever adds the next one — the
# grep fails, in the gate, before the caller exists rather than after it has eaten a bead.
#
# It runs against the INSTALLED tree, not the fixture, because the fixture only holds the two
# files this suite copies and the point is to police all of them.
offenders="$(grep -rnE "git -C [^ ]+ (worktree (remove|prune)|branch -D)|rm -rf \"\$w\"" \
             "$HERE"/*.sh 2>/dev/null \
    | grep -v "^$HERE/test-" \
    | grep -vE "^$HERE/lib\.sh:[0-9]+:" \
    || true)"
if [ -z "$offenders" ]; then
    ok "every deletion in the harness goes through lib.sh"
else
    bad "every deletion in the harness goes through lib.sh" "$(printf '%s' "$offenders" | tr '\n' ' ')"
fi
# THE POSITIVE CONTROL for that grep. An expression that matches nothing looks exactly like a
# clean harness, and this one has four alternations and six escapes in it. Prove it can see a
# violation before believing it did not find one.
mkdir -p "$TMP/fence"; cp "$HERE/lib.sh" "$TMP/fence/"
printf 'git -C "$REPO" worktree remove --force "$w"\n' > "$TMP/fence/offender.sh"
seen="$(grep -rnE "git -C [^ ]+ (worktree (remove|prune)|branch -D)|rm -rf \"\$w\"" \
        "$TMP/fence"/*.sh 2>/dev/null | grep -c offender.sh || true)"
[ "${seen:-0}" -ge 1 ] && ok "and the sweep can actually see a violation" \
                       || bad "and the sweep can actually see a violation" "it matched nothing"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
