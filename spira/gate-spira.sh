#!/usr/bin/env bash
#
# gate-spira.sh — this repository's own landing gate, named by its row in repo-map and
# invoked by gate.sh with the working directory already set to a tree extracted from the
# BRANCH, in a minimal environment.
#
#   cwd                  the branch's tree
#   SPIRA_GATE_REPO      the shared checkout, for questions about history
#   SPIRA_GATE_BRANCH    the branch under trial
#   SPIRA_GATE_BASE      the ref it is measured against
#   SPIRA_GATE_FILES     a file listing every changed path, one per line
#
# SUITES ARE DISCOVERED, NEVER LISTED, and SELECTED from the changed files. This repository
# IS the harness, so most changes to it are changes to the thing deciding whether to reclaim
# a bead from a running aeon, delete a branch, or raise a decision — but not all of them are,
# and landing is serialised and gate-dominated, so a README edit paying one Dolt fixture and
# every suite is the cap on how fast finished work reaches the base ref.
#
# `gate-select.sh` answers which suites the changed files need, from a `# covers:` line each
# suite declares about itself. Its rules are written there; the one that matters here is that
# it errs toward EVERYTHING — a shared file, an unclaimed path, or an unreadable file list
# all select the whole set, and only an explicit inert list may select nothing.
#
# THE MAP IS NOT TRUSTED TO STAY RIGHT. It is a claim maintained by hand, so it decays the
# first time somebody moves a function — and it decays silently, because an under-selected
# gate is green. Two things hold it: this gate refuses a branch whose suites do not all
# declare what they cover, and `gate-full.sh` runs the WHOLE set against the base ref on a
# timer and escalates on red, so a hole in the map surfaces within a day rather than never.
#
# The two fences run FIRST and independently of the suites, because they answer a different
# question. A suite asks whether the code works; `exclude.sh` and `inventory.sh` ask whether
# it may be published at all, and that is the one refusal nothing may route around — a commit
# that publishes a database or an operator's infrastructure cannot be undone by deleting the
# commit.
#
# A SKIP IS ANNOUNCED, NEVER SWALLOWED. Several suites run the real `bd` against a throwaway
# database and exit 77 — the automake convention — when no server answers. A gate that
# reported "could not check" as all-clear would displace the suspicion that would have
# prompted a look (law-alerts-must-be-actionable).
set -uo pipefail

fail=0

for fence in spira/exclude.sh spira/inventory.sh spira/gate-select.sh; do
    [ -f "$fence" ] || { echo "gate: $fence is missing from the branch" >&2; fail=1; continue; }
done
[ "$fail" = 0 ] || exit 1

# `check .` and not the default: the extracted tree is the repository under judgement, and
# letting it resolve its own root would find whichever checkout the gate happens to run in.
if ! out="$(bash spira/exclude.sh check . 2>&1)"; then
    printf '%s\n' "$out" | tail -20 >&2
    echo "gate: the branch carries beads data" >&2
    fail=1
fi

# The inventory fence's whole-tree entry point reads the git INDEX. Scan the files on disk
# instead, one at a time, through the same matcher — that entry point is a convenience over
# exactly this. Two reasons to go the long way round: the tree under trial is not guaranteed
# to be a checkout, and an index answers only for what is tracked, whereas what a gate must
# judge is every file the tree actually holds.
#
# Build output is pruned by NAME rather than by path, so a second crate does not have to
# remember to add itself here. It is gitignored, it holds absolute paths from whichever box
# last compiled it, and the fence would therefore flag it on every gate run.
inv=""
while IFS= read -r f; do
    case "$f" in */inventory.sh|*/inventory-deny|*/test-inventory.sh) continue ;; esac
    hits="$(bash spira/inventory.sh --scan "$f" 2>/dev/null)"
    [ -n "$hits" ] && inv="$inv
$f: $(printf '%s' "$hits" | tr '\n' ' ')"
done < <(find . -path ./.git -prune -o -type d -name target -prune -o -type f -print)
if [ -n "$inv" ]; then
    printf '%s\n' "$inv" >&2
    echo "gate: the branch names one operator's infrastructure — see spira/inventory.sh" >&2
    fail=1
fi

# ONE RETRY, AND ONLY FOR A SUITE THAT COULD NOT BUILD ITS FIXTURE. Several suites run the
# real `bd` against a throwaway database on the same server the live harness is using, so a
# `bd init` can lose a race with whatever else is working — each suite passes alone and a
# sequential sweep intermittently loses one. That is a flaky gate, and a flaky gate rejects
# good work at random and teaches everyone to ignore it.
#
# The retry is narrow on purpose: it fires on the fixture-setup signal and nothing else, so
# a genuine test failure is still red the first time and is never re-run into a pass.
run_suite() {           # run_suite <suite> -> stdout+stderr, exit code
    local t="$1" out rc
    out="$(timeout 600 bash "$t" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'could not build a fixture database\|testdb_up failed\|bd init failed' <<< "$out"; then
        sleep 5
        out="$(timeout 600 bash "$t" 2>&1)"; rc=$?
    fi
    printf '%s' "$out"
    return "$rc"
}

# EVERY SHELL SCRIPT PARSES. The cheapest check there is, and it caught a real one: a comment
# rewritten inside a `python3 -c '...'` block gained an apostrophe, which closed the quote and
# left the file syntactically invalid — invisible to every suite, because nothing here executes
# that particular watcher, and invisible to review, because the change was one word in a
# comment. Prose is not inert when it lives inside a quoted string
# (law-deterministic-before-inference: build the cheap check before the smart one).
badsyntax=""
while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || badsyntax="$badsyntax $f"
done < <(find . -path ./.git -prune -o -type d -name target -prune -o -name '*.sh' -type f -print)
if [ -n "$badsyntax" ]; then
    for f in $badsyntax; do bash -n "$f" 2>&1 | head -2 >&2; done
    echo "gate: shell scripts do not parse:$badsyntax" >&2
    fail=1
fi

# EVERY SUITE DECLARES WHAT IT COVERS, and a branch where one does not is refused. This is
# the fence under the selection: a suite with no `# covers:` line claims nothing, so it runs
# only when something else forces a full pass — and it then looks exactly like a suite that
# is passing. The refusal is the whole reason the map can be trusted to stay narrow
# (law-absence-needs-a-positive-control).
if ! out="$(bash spira/gate-select.sh --lint 2>&1)"; then
    printf '%s\n' "$out" >&2
    echo "gate: add a '# covers:' line naming the files each suite covers — see spira/gate-select.sh" >&2
    fail=1
fi

# WHICH SUITES THIS BRANCH NEEDS. SPIRA_GATE_ALL=1 overrides the selection and runs the whole
# set: that is what the daily full run against the base ref uses, and it is the seam the
# selection's own suite drives.
#
# The selector is trusted to widen, never to narrow wrongly — every uncertain case it meets
# selects everything — so a failure to run it at all is the only thing that could quietly
# shrink this, and that is why its absence is refused above with the two publication fences.
suites=""
if [ "${SPIRA_GATE_ALL:-0}" = 1 ]; then
    echo "gate: SPIRA_GATE_ALL=1 — running every suite" >&2
    suites="$(bash spira/gate-select.sh 2>/dev/null)"
else
    suites="$(bash spira/gate-select.sh "${SPIRA_GATE_FILES:-}")"
fi

# NOTHING SELECTED IS AN OUTCOME, NOT AN ERROR — but it is announced, because a gate that
# silently ran no suites is indistinguishable in an exit code from one where they all passed.
if [ -z "$suites" ]; then
    echo "gate: no suite covers anything this branch changed — fences only, no suites run" >&2
    exit "$fail"
fi

# ONE FIXTURE FOR THE WHOLE RUN. Several of these suites build a Dolt database, and `bd init`
# is nearly all of the ~27s each one costs — the same schema built over and over was more than
# half the gate's wall clock. testdb_up honours an inherited TESTDB_SHARED fixture by resetting
# it to its baseline instead (~73ms), which is the same isolation every suite already relies on
# between its own cases. Parallelising instead was measured and is worse: the Dolt server
# contends on creation, three concurrent builds taking 95.6s against 66.6s serially.
#
# BUILT HERE, NOT IN THE SUITES, so a suite run on its own still builds its own and needs no
# argument — the sharing is the gate's optimisation, not a precondition of the tests.
if . spira/testdb.sh 2>/dev/null && testdb_up gate >/dev/null 2>&1; then
    export TESTDB_SHARED=1 TESTDB_NAME TESTDB_DIR TESTDB_BASELINE TESTDB_HOST TESTDB_PORT
    # The owner drops it: TESTDB_SHARED is cleared first so testdb_drop stops being a no-op.
    trap 'TESTDB_SHARED=0 testdb_drop >/dev/null 2>&1' EXIT
else
    # A FIXTURE THAT COULD NOT BE BUILT ABORTS THE GATE. It is not a pass and not a skip, and
    # it is emphatically not a licence to let 36 suites each build their own: `bd init` holds a
    # schema-migration lock, so the fallback took the one contended operation and did it
    # thirty-six more times. Measured 2026-09-07, that is what turned a 776s gate into one that
    # could not finish at all, stranding aeons and taking the landing leg down for six hours.
    #
    # Aborting costs one gate run and says why. Degrading cost a day, and said "could not build
    # a shared fixture" once, in the middle of output nobody reads until something is already
    # wrong (law-alerts-must-be-actionable). testdb_up now serialises on flock, so reaching
    # here means the lock could not be taken in ten minutes or the init genuinely failed —
    # both of which are facts about this box that a gate must report rather than work around.
    echo "gate: could not build the shared fixture — refusing to run 36 individual builds against the same lock" >&2
    echo "gate: see testdb_up's output above; the fixture lock is ${SPIRA_RUN:-/tmp}/testdb-init.lock" >&2
    exit 1
fi

skipped=0
while IFS= read -r t; do
    [ -e "$t" ] || continue
    out="$(run_suite "$t")"; rc=$?
    case "$rc" in
        0)  case "$out" in *SKIP*) skipped=$((skipped+1)); echo "gate: SKIP $t — $(grep -m1 SKIP <<< "$out")" >&2 ;; esac ;;
        77) skipped=$((skipped+1)); echo "gate: SKIP $t — no database available" >&2 ;;
        *)  printf '%s\n' "$out" | tail -25 >&2
            echo "gate: $t FAILED (rc=$rc)" >&2
            fail=1 ;;
    esac
done <<< "$suites"

# A gate that found nothing to RUN must say so rather than pass. An empty glob and a green
# suite are indistinguishable in an exit code (law-absence-needs-a-positive-control). This
# asks whether the suites EXIST, not whether any were selected: selecting none is a verdict
# the selector reached and announced above, whereas an empty `spira/` is a broken checkout.
n="$(ls spira/test-*.sh 2>/dev/null | wc -l)"
if [ "$n" -eq 0 ]; then
    echo "gate: no test-*.sh in spira/ — refusing to report a pass on nothing checked" >&2
    exit 1
fi
ran="$(printf '%s\n' "$suites" | grep -c .)"
[ "$ran" -eq "$n" ] || echo "gate: ran $ran of $n suite(s) — selected from the changed files" >&2

[ "$skipped" -gt 0 ] && echo "gate: $skipped of $ran suite(s) run were skipped" >&2
exit "$fail"
