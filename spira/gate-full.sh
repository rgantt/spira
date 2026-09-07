#!/usr/bin/env bash
#
# gate-full.sh — run the WHOLE gate against the ref everything lands on, on a timer.
#
#   gate-full.sh [repo-name]
#
# WHY THIS EXISTS. The landing gate selects suites from the changed files, and the map it
# selects by is a claim maintained by hand: each suite names the files it covers. A hand-kept
# map decays the first time somebody moves a function between two scripts, and it decays in
# the one direction nobody notices — an under-selected gate is GREEN. Every branch passes,
# every bead closes, and the suite that would have caught it was simply not run.
#
# So the map is not trusted; it is checked. Once a day the whole set runs against the base
# ref, where a red result cannot be any branch's fault and is therefore either a hole in the
# map or a genuine break already landed. Either is a decision for the operator, and either is
# worth knowing within a day rather than never (law-take-the-simple-fix-with-a-meter: the
# cheap selection ships WITH the thing that says when it has stopped being adequate).
#
# IT JUDGES THE BASE REF, NOT A BRANCH. There is no diff to take and no changed-file list to
# select from, so it forces `SPIRA_GATE_ALL=1` explicitly rather than relying on an empty file
# list happening to mean "everything" — a default the selector does hold, but one this program
# must not be silently depending on.
#
# ITS OWN WORKTREE. The landing gate's scratch tree is checked out and force-reset by every
# pass, and this runs on a clock rather than in that sequence, so sharing it would let a timer
# yank the tree out from under a landing in progress.
#
# EXIT   0  the full set passed against the base ref
#        1  it did not — the finding is on stdout and has been escalated
#        3  could not check — said out loud, never a silent pass
#              (law-absence-needs-a-positive-control)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

REPO_NAME="${1:-$(spira_home_repo)}"
REPO="$(repo_root "$REPO_NAME")" || {
    echo "gate-full: repo-map has no entry for '$REPO_NAME'" >&2; exit 3; }

CMD="$(repo_gate "$REPO_NAME")"
[ -n "$CMD" ] || {
    echo "gate-full: repo:$REPO_NAME declares no gate of its own — nothing to run" >&2; exit 3; }

BASE="$(spira_landref "$REPO")" || {
    echo "gate-full: cannot resolve the ref repo:$REPO_NAME lands on" >&2; exit 3; }

# Fetch first. The base is a remote-tracking ref, so an unfetched checkout would judge
# whatever this box last pulled and report on code that is a day behind the thing it claims
# to be checking. A fetch that fails is not fatal — the ref still resolves to something real
# — but it changes what the answer means, so it is said.
case "$BASE" in
    */*) remote="${BASE%%/*}"
         git -C "$REPO" fetch --quiet "$remote" 2>/dev/null \
            || echo "gate-full: could not fetch $remote — judging the cached $BASE" >&2 ;;
esac

TREE="$SPIRA_RUN/worktree/.gatefull.$(basename "$REPO")"
if [ ! -e "$TREE/.git" ]; then
    mkdir -p "$(dirname "$TREE")"
    # Through the chokepoint: one prune covers every worktree of the repository, so a timer
    # tidying up after itself must not be able to unregister the tree an aeon is working in.
    spira_prune_worktrees "$REPO" >/dev/null 2>&1
    git -C "$REPO" worktree add -q --detach "$TREE" "$BASE" 2>/dev/null || {
        echo "gate-full: cannot create a worktree at $TREE" >&2; exit 3; }
else
    git -C "$TREE" checkout -q --force --detach "$BASE" 2>/dev/null || {
        echo "gate-full: cannot check $BASE out in $TREE" >&2; exit 3; }
fi

# The same minimal environment the landing gate gives a repository's own gate command, for the
# same reason: a verdict that depends on ambient configuration is not a verdict
# (law-gates-run-in-a-clean-environment). SPIRA_GATE_FILES is deliberately absent — there is
# no diff here — and SPIRA_GATE_ALL is what says so.
out="$( cd "$TREE" && env -i \
    PATH="$HOME/.cargo/bin:$PATH" HOME="$HOME" TERM=dumb \
    SPIRA_GATE_REPO="$REPO" SPIRA_GATE_REPO_NAME="$REPO_NAME" \
    SPIRA_GATE_BRANCH="$BASE" SPIRA_GATE_BASE="$BASE" \
    SPIRA_GATE_ALL=1 \
    timeout "${SPIRA_GATE_FULL_TIMEOUT:-3600}" bash -c "$CMD" 2>&1 )"
rc=$?

if [ "$rc" = 0 ]; then
    echo "gate-full: the whole suite set passes against $BASE in repo:$REPO_NAME"
    exit 0
fi

findings="The full Spira suite set fails against $BASE (repo:$REPO_NAME), which no branch can
have caused. Either a suite covers a file its \`# covers:\` line does not name — so the
landing gate has been skipping it — or something already landed is broken.

    gate command: $CMD
    exit status:  $rc

$(printf '%s\n' "$out" | tail -40)"

printf '%s\n' "$findings"

# ESCALATE ONCE PER DISTINCT STATE, not once per run. The condition persists until somebody
# acts on it, and a daily repetition of a decision already in front of the operator is the
# noise that teaches them to scroll past the one that matters (law-alerts-must-be-actionable).
# A CHANGE in the findings is new information and does ask again.
stamp="$SPIRA_RUN/gate-full.escalated"
fp="$(printf '%s' "$findings" | cksum | tr -d ' ')"
prev=""; [ -f "$stamp" ] && prev="$(cat "$stamp" 2>/dev/null)"
if [ "$fp" != "$prev" ]; then
    mkdir -p "$SPIRA_RUN" 2>/dev/null
    printf '%s' "$fp" > "$stamp"
    if [ -x "$SPIRA_NOTIFY" ]; then
        "$SPIRA_NOTIFY" add \
            "The full Spira suite set is red against $BASE" \
            --default "read the failure below: if a suite fails on a file no \`# covers:\` line names, widen that line; otherwise fix what landed broken" \
            --why "the landing gate runs only the suites the changed files select, so a suite that is red here has been passing branches that never ran it" \
            --evidence "$findings" >/dev/null 2>&1
    else
        echo "gate-full: no escalation path at $SPIRA_NOTIFY — the finding above reaches nobody" >&2
    fi
fi
exit 1
