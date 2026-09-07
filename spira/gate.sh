#!/usr/bin/env bash
#
# gate.sh — the deterministic landing gate. Exits 0 if a branch may merge.
#
#   gate.sh <branch> [repo-name]
#
# This is the Cloister: a trial a branch passes before it may enter. It is deliberately
# cheap and mechanical — syntax, then whatever the repository itself declares — because a
# gate that needs judgement is not a gate, it is a review. Judgement belongs to sentinel.sh
# CHECK 8 and to the operator.
#
# TWO LAYERS, AND ONLY ONE OF THEM IS UNIVERSAL. `bash -n` on every changed shell script
# holds everywhere, because a script that does not parse is the most common way an
# unattended change breaks a harness. Everything else is the REPOSITORY'S OWN: brain runs
# the harness and guard suites, another runs a Rust formatting check with its own CI
# behind the pull request. That command comes from repo-map, so adding a repository is
# adding a line rather than editing this file — which is what "the landing gate must learn
# each repo's own test command" means in practice.
#
# It fails CLOSED. A gate that cannot run its own checks must not report a pass: the whole
# point is to keep unverified work out of a branch everything else pulls from.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

BR="${1:?usage: gate.sh <branch> [repo-name]}"
REPO_NAME="${2:-$(spira_home_repo)}"
REPO="$(repo_root "$REPO_NAME")" || {
    echo "gate: repo-map has no entry for '$REPO_NAME' — refusing to guess a checkout" >&2
    exit 1; }

# The remote-tracking ref, never the local branch. Nothing in this harness advances the
# shared checkout's default branch, so a diff against it is a diff against whatever the last
# human left behind: the changed-file list would include every file that landed since, and
# the gate would then run — or skip — suites on the strength of somebody else's work. The
# branch reaching here has already been rebased onto this same ref by CHECK 6, so the
# three-dot merge base is its real base.
#
# And it is resolved, not assumed to be `main`: some repositories have no such ref, so
# every diff here was against nothing and every changed-file test read empty — a gate that
# skips every suite because it thinks nothing changed passes everything.
BASE="$(spira_landref "$REPO")" || {
    echo "gate: cannot resolve the ref '$REPO_NAME' lands on — refusing to guess a base" >&2
    echo "gate: give it a \`base\` column in $SPIRA_REPO_MAP" >&2
    exit 1; }
files="$(git -C "$REPO" diff --name-only "$BASE...$BR" 2>/dev/null)" || exit 1

# ---------------------------------------------------------------------------------------
# LAYER 1 — universal. Every changed shell script must parse.
# ---------------------------------------------------------------------------------------
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
        *.sh)
            git -C "$REPO" show "$BR:$f" > /tmp/spira-gate-$$.sh 2>/dev/null || continue
            if ! bash -n /tmp/spira-gate-$$.sh 2>/dev/null; then
                rm -f /tmp/spira-gate-$$.sh
                echo "gate: $f fails bash -n" >&2
                exit 1
            fi
            rm -f /tmp/spira-gate-$$.sh
            ;;
    esac
done <<< "$files"

# No beads data may land in the harness tree, in any repository. This is universal for the
# same reason `bash -n` is: it is not one repository's taste, and the cost of getting it
# wrong is unbounded — a database published in a shared repository holds internal working
# notes, agent memories and the overseer's own judgement, and cannot be un-published by
# deleting the commit (law-beads-is-never-public).
#
# It is the SECOND fence, and the one that matters. The first is a pre-commit hook, which
# `git commit --no-verify` bypasses by design and which a clone does not have armed until
# somebody runs `exclude.sh install`; neither of those is the committer's failing, and
# neither can be relied on. This runs on every branch before it merges and nothing here
# routes around it.
#
# The branch's WHOLE TREE, not its changed files: the question is what the repository would
# contain after landing, so a database that arrived on an earlier commit of the same branch
# is caught rather than waved through for not being in this diff. exclude.sh takes its
# scope from that same list, so it is answering about this ref and not about wherever the
# harness happens to sit in the shared checkout — and it exits 3, not 0, on a repository
# that carries no harness at all, which is most of them.
#
# And it fails CLOSED on its own absence. `bash <missing-file> | ...` prints to stderr and
# yields an empty offender list, which is indistinguishable from a clean tree — the exact
# shape where a check that could not run reports all-clear.
EXCLUDE="$(dirname "$0")/exclude.sh"
[ -r "$EXCLUDE" ] || { echo "gate: $EXCLUDE is missing — refusing to land unchecked" >&2; exit 1; }
offenders="$(git -C "$REPO" ls-tree -r --name-only "$BR" 2>/dev/null \
    | bash "$EXCLUDE" filter 2>/dev/null)"
if [ -n "$offenders" ]; then
    echo "gate: $BR would land beads data in the harness tree:" >&2
    printf '%s\n' "$offenders" | sed 's/^/gate:   /' >&2
    echo "gate: a beads database is never public and belongs in no shared repository." >&2
    echo "gate: remove them from the branch — there is no override for this one." >&2
    exit 1
fi

# No branch may change a COPY of the harness in a repository that is not the harness's own.
# The service manager executes one tree; a second copy vendored into another repository is
# edited by correct work that then never runs, and nothing downstream can tell — the tree
# that was edited is self-consistent, so its suites are green, its gate is satisfied and its
# bead closes naming a real commit. Landed and in effect became different claims the moment
# there were two copies, and this is the only place that compares them
# (law-closed-is-not-landed, one layer out).
#
# Universal for the same reason the two above are: it is not one repository's taste, and it
# is the harness's own correctness at stake rather than the judged repository's.
#
# It fails CLOSED on its own absence, and skew.sh fails closed on its own confusion.
SKEW="$(dirname "$0")/skew.sh"
[ -r "$SKEW" ] || { echo "gate: $SKEW is missing — refusing to land unchecked" >&2; exit 1; }
bash "$SKEW" foreign "$REPO" "$BASE" "$BR" || {
    echo "gate: $BR belongs in the harness's own repository, not $REPO_NAME." >&2
    exit 1; }

# ---------------------------------------------------------------------------------------
# LAYER 2 — the repository's own gate. Empty means syntax was the whole trial.
# ---------------------------------------------------------------------------------------
CMD="$(repo_gate "$REPO_NAME")"
[ -n "$CMD" ] || exit 0

# THE TREE IS THE BRANCH, never the shared checkout. `cd "$REPO"` would run the copy of
# these suites that is already installed on main — so a branch that breaks a guard would be
# tested by the guard it had not broken yet, and a branch that ADDS a suite would fail its
# own gate because the file does not exist on main yet.
#
# A DETACHED WORKTREE rather than a `git archive` extraction. The archive version could only
# afford to unpack `.claude`, which silently made this brain-shaped: no other repository's
# tests live there, and a gate that can only see one directory cannot run `cargo` or `npm`
# at all. A worktree shares the object store, so the full tree costs a checkout of the files
# that actually changed, and it is reused across passes.
TREE="$SPIRA_RUN/worktree/.gate.$(basename "$REPO")"

# ONE TREE PER REPOSITORY MEANS ONE TREE FOR ALL OF THAT REPOSITORY'S GATES, so the tree is
# LOCKED for the whole trial. Gates run concurrently by construction — every aeon runs one
# before it closes, and the landing pass runs one per branch it is about to merge — and
# without a lock each `checkout --detach` pulls the previous run's branch out from under it
# mid-command. The verdict is then about whatever was checked out last, and nothing says so:
# two consecutive runs both passed, one of them on a branch deliberately broken, because a
# concurrent gate had swapped the tree between them. That is the worst failure a gate has —
# it passes work it never looked at, and the landing pass acts on the pass.
#
# THE SIMPLE FIX, SHIPPED WITH THE METER THAT SAYS WHEN IT STOPS BEING ENOUGH. Serialising
# is correct at any scale; what it costs is wall clock, so every run records how long it
# waited for the tree and how long it then held it, and a non-zero wait is said out loud
# (law-take-the-simple-fix-with-a-meter). When that log shows waits approaching the runs
# themselves, the answer is a tree per branch — not a wider timeout.
#
# It fails CLOSED on a wait that runs out: a gate that could not obtain the tree has checked
# nothing, and "could not run" is not a pass.
mkdir -p "$(dirname "$TREE")"
spira_require flock || exit 1
exec 9>"$TREE.lock" || { echo "gate: cannot open the gate tree's lock at $TREE.lock" >&2; exit 1; }
# THE WAIT IS DERIVED FROM THE RUN, not picked. One holder can legitimately occupy the tree
# for two full gate timeouts — the branch's trial, then the same command against the base to
# establish whose fault a failure is — so a wait shorter than twice the timeout would time
# out against a single healthy holder and report that as a refusal.
GATE_LOCK_WAIT="${SPIRA_GATE_LOCK_WAIT:-$(( ${SPIRA_GATE_TIMEOUT:-900} * 4 ))}"
GATE_WAIT0=$(date +%s)
if ! flock -w "$GATE_LOCK_WAIT" 9; then
    echo "gate: another gate has held $TREE for ${GATE_LOCK_WAIT}s — no verdict on $BR" >&2
    echo "gate: this is a queue, not a fault in the branch; retry, or raise SPIRA_GATE_LOCK_WAIT." >&2
    exit 1
fi
GATE_WAITED=$(( $(date +%s) - GATE_WAIT0 ))
GATE_START=$(date +%s)
[ "$GATE_WAITED" -gt 0 ] && echo "gate: waited ${GATE_WAITED}s for $TREE" >&2

# THE METER IS WRITTEN FROM THE EXIT TRAP, so every way out of the trial is counted — the
# pass, the branch's own failure, and the checkout that could not be proved. A meter only
# the happy path writes measures the happy path.
GATE_LOG="${SPIRA_GATE_LOG:-$SPIRA_RUN/gate.log}"
gate_meter() {           # gate_meter <exit-status>
    printf '%s %s %s waited=%ss ran=%ss rc=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO_NAME" "$BR" \
        "$GATE_WAITED" "$(( $(date +%s) - GATE_START ))" "${1:-?}" >> "$GATE_LOG" 2>/dev/null
}

# gate_at <ref> -> 0 with TREE PROVEN to hold that ref's commit.
#
# The proof is the point. A checkout that reports success is not evidence the tree holds what
# was asked for — the lock above is what makes it true, and this is what says so out loud if
# it ever is not again (law-absence-needs-a-positive-control). A gate that cannot identify
# the tree it is about to judge must refuse rather than judge it.
gate_at() {
    local ref="$1" want have
    want="$(git -C "$REPO" rev-parse --verify -q "$ref^{commit}" 2>/dev/null)" || want=""
    [ -n "$want" ] || { echo "gate: cannot resolve $ref in $REPO_NAME" >&2; return 1; }
    if [ ! -e "$TREE/.git" ]; then
        # Through the chokepoint: one prune covers every worktree of the repository, so a
        # gate tidying up after itself must not be able to unregister the aeon whose branch
        # it is about to try.
        spira_prune_worktrees "$REPO" >/dev/null 2>&1
        git -C "$REPO" worktree add -q --detach "$TREE" "$ref" 2>/dev/null || {
            echo "gate: cannot create a gate worktree at $TREE" >&2; return 1; }
    else
        # `--force` because a previous gate may have left build output; `checkout --detach`
        # refuses nothing else here, and the lock makes the tree ours alone.
        git -C "$TREE" checkout -q --force --detach "$ref" 2>/dev/null || {
            echo "gate: cannot check $ref out in $TREE" >&2; return 1; }
    fi
    have="$(git -C "$TREE" rev-parse HEAD 2>/dev/null)"
    [ "$have" = "$want" ] && return 0
    echo "gate: $TREE is at ${have:-nothing}, not $ref ($want) — refusing to judge a tree it cannot identify" >&2
    return 1
}

gate_at "$BR" || { gate_meter 1; exit 1; }

# THE GATE MUST NOT INHERIT THE HARNESS'S OWN CONFIGURATION.
# Tests run in an explicit, minimal environment. The sentinel service exports
# SPIRA_FAYTHS="builder ops"; systemd passed that into the gate, the gate passed it into
# test-fayth.sh, and two tests asserting the DEFAULT fayth list failed — so correct work was
# rejected because of a deployment setting made an hour earlier, and it would have been
# rejected again on every retry until the bead poisoned. A gate whose verdict depends on
# ambient environment is not deterministic, and a non-deterministic gate is worse than none:
# it rejects good work at random and teaches everyone to ignore it
# (law-gates-run-in-a-clean-environment).
#
# What a gate command MAY see is named here and nowhere else: where the branch came from,
# and what it changed. ~/.cargo/bin is on the path because a Rust repository's cheapest
# real gate is `cargo fmt --check` and lib.sh's PATH — written for systemd — has no toolchain
# on it.
#
# SPIRA_GATE_ALL is passed THROUGH rather than set, and defaults to 0. A repository whose gate
# selects its suites from the changed files needs a way to be told to run all of them anyway;
# leaking in from the environment only ever widens what is checked, which is the safe
# direction, and it is named here so that it is a seam rather than an ambient surprise.
FILELIST="$(mktemp)"; printf '%s\n' "$files" > "$FILELIST"
# The status is captured FIRST: `$?` inside a trap is whatever the previous command in the
# trap returned, so a cleanup line ahead of the meter would have every run recorded as the
# exit status of `rm`.
trap 'gate_rc=$?; rm -f "$FILELIST"; gate_meter "$gate_rc"' EXIT
run_gate() {             # run_gate <ref-being-tested> -> the command's own status
    ( cd "$TREE" && env -i \
        PATH="$HOME/.cargo/bin:$PATH" HOME="$HOME" TERM=dumb \
        SPIRA_GATE_REPO="$REPO" SPIRA_GATE_REPO_NAME="$REPO_NAME" \
        SPIRA_GATE_BRANCH="$1" SPIRA_GATE_BASE="$BASE" \
        SPIRA_GATE_FILES="$FILELIST" \
        SPIRA_GATE_ALL="${SPIRA_GATE_ALL:-0}" \
        timeout "${SPIRA_GATE_TIMEOUT:-900}" bash -c "$CMD" ) 2>&1 | tail -20
    return "${PIPESTATUS[0]}"
}

if out="$(run_gate "$BR")"; then exit 0; fi

# A FAILING GATE MUST SAY WHOSE FAULT IT IS. A command that already fails against the base
# rejects every branch for a condition no branch caused — three attempts, then poison, then
# an escalation to the operator about work that was fine, with nothing in it pointing at the real
# cause. Measured on another: `cargo fmt --all -- --check` exits 1 against its
# own main, so declaring it as that repository's gate would have done exactly this.
#
# The verdict does not change — a gate fails CLOSED, and "main is broken too" is not a
# licence to land unverified work — but the reason does, and the reason is what the bead
# note carries to whoever reads it.
echo "gate: $REPO_NAME's own gate failed: $CMD" >&2
printf '%s\n' "$out" >&2
if gate_at "$BASE" && ! run_gate "$BASE" >/dev/null 2>&1; then
    echo "gate: it fails against $BASE too — this branch did not cause it." >&2
    echo "gate: fix the repository, or clear that command from $SPIRA_REPO_MAP." >&2
fi
gate_at "$BR" >/dev/null 2>&1
exit 1
