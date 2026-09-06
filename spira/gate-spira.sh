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
# EVERY SUITE, EVERY TIME, and discovered rather than listed. This repository IS the harness:
# there is no change to it that is not a change to the thing deciding whether to reclaim a
# bead from a running aeon, delete a branch, or raise a decision. A gate that ran only the
# suites touching changed files would have to model which suite covers which file, and that
# model is wrong the first time somebody moves a function.
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

for fence in spira/exclude.sh spira/inventory.sh; do
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

# The inventory fence reads the git INDEX, and an extracted tree has no index. Scan the files
# on disk instead, one at a time, through the same matcher — the whole-tree entry point is a
# convenience over exactly this.
inv=""
while IFS= read -r f; do
    case "$f" in */inventory.sh|*/inventory-deny|*/test-inventory.sh) continue ;; esac
    hits="$(bash spira/inventory.sh --scan "$f" 2>/dev/null)"
    [ -n "$hits" ] && inv="$inv
$f: $(printf '%s' "$hits" | tr '\n' ' ')"
done < <(find . -path ./.git -prune -o -path './cockpit/panel/target' -prune -o -type f -print)
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
done < <(find . -path ./.git -prune -o -name '*.sh' -type f -print)
if [ -n "$badsyntax" ]; then
    for f in $badsyntax; do bash -n "$f" 2>&1 | head -2 >&2; done
    echo "gate: shell scripts do not parse:$badsyntax" >&2
    fail=1
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
    # A fixture that could not be built is not a pass, and it is not a skip either. Suites fall
    # back to building their own, which is slow but correct; what must not happen is the gate
    # quietly running fewer of them.
    echo "gate: could not build a shared fixture — suites will build their own" >&2
    unset TESTDB_SHARED
fi

skipped=0
for t in spira/test-*.sh; do
    [ -e "$t" ] || continue
    out="$(run_suite "$t")"; rc=$?
    case "$rc" in
        0)  case "$out" in *SKIP*) skipped=$((skipped+1)); echo "gate: SKIP $t — $(grep -m1 SKIP <<< "$out")" >&2 ;; esac ;;
        77) skipped=$((skipped+1)); echo "gate: SKIP $t — no database available" >&2 ;;
        *)  printf '%s\n' "$out" | tail -25 >&2
            echo "gate: $t FAILED (rc=$rc)" >&2
            fail=1 ;;
    esac
done

# A gate that found nothing to run must say so rather than pass. An empty glob and a green
# suite are indistinguishable in an exit code (law-absence-needs-a-positive-control).
n="$(ls spira/test-*.sh 2>/dev/null | wc -l)"
if [ "$n" -eq 0 ]; then
    echo "gate: no test-*.sh in spira/ — refusing to report a pass on nothing checked" >&2
    exit 1
fi

[ "$skipped" -gt 0 ] && echo "gate: $skipped of $n suite(s) skipped" >&2
exit "$fail"
