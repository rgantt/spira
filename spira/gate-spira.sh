#!/usr/bin/env bash
#
# gate-spira.sh — this repository's own landing gate.
#
#   gate-spira.sh
#
# WHAT THIS REPLACED, and why. Until 2026-09-07 this ran 43 suites, 13,098 lines of test code
# against 4,642 lines of program, and took 17 minutes per branch. On the day the system spent
# an entire morning unable to land anything, that gate found zero real defects and produced
# two failures — both of them suites reading the state of the box they ran on rather than the
# code under test. It was also, by being 17 minutes long, most of the contention that made a
# shared worktree worth locking, and the lock is what livelocked the queue.
#
# The three real defects that day were found by two things: tests written for the specific
# change, in minutes, and a 20-second soak. Neither was in the 17 minutes.
#
# WHAT THIS SYSTEM ACTUALLY IS: N workers pull from a DAG, put candidate work in a merge
# queue, and the queue is CI/CD. Every failure it has ever had is a property of that pipeline
# — two things running at once, a lock, a queue that stops moving — and none has been a
# function returning the wrong value. So the gate checks the pipeline.
#
#   1. THE FENCES. Not quality checks: guards against things that cannot be undone by
#      deleting a commit. A published beads database holds internal notes, agent memories and
#      the operator's own judgement; a published operator inventory names one person's
#      machine. These run first, independently, and nothing routes around them.
#   2. THE SOAK. Does the merge queue make progress while several gates and a landing pass
#      run against each other? It reproduces the 2026-09-07 livelock against the old code at
#      the production ratio, then shows it gone.
#   3. THE END-TO-END is filed, not built (sp-canary). One bead through the whole pipeline
#      on a staging Spira, with a commit on the base branch at the end of it, is the only
#      check that would test the claim this system makes about itself — and it needs a whole
#      second Spira stood up, which is not what today is for. Detection comes first
#      (law-detection-outranks-rejection): the watchtower notices the pipeline has stopped
#      and files it back into the DAG, which is worth more than a gate refusing a change.
#
# It fails CLOSED, and a check that could not run is not a pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "${SPIRA_GATE_REPO:-.}" 2>/dev/null || cd .

rc=0
say() { printf 'gate: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------------------
# 1. THE FENCES — first, and independently of everything below.
# ---------------------------------------------------------------------------------------
for fence in spira/exclude.sh spira/inventory.sh; do
    [ -r "$fence" ] || { say "$fence is missing — refusing to land unchecked"; exit 1; }
done

# The whole tree, not the diff: the question is what this repository would CONTAIN after
# landing, so a database that arrived on an earlier commit of the same branch is caught
# rather than waved through for not being in this diff.
offenders="$(git ls-files 2>/dev/null | bash spira/exclude.sh filter 2>/dev/null)"
if [ -n "$offenders" ]; then
    say "this branch would land beads data in the harness tree:"
    printf '%s\n' "$offenders" | sed 's/^/gate:   /' >&2
    say "a beads database is never public. There is no override for this one."
    exit 1
fi

if ! inv="$(bash spira/inventory.sh 2>&1)"; then
    printf '%s\n' "$inv" >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------
# 2 AND 3 — the pipeline. Both are real programs run against each other; neither models
# anything (law-prefer-the-real-dependency).
#
# A SKIP IS ANNOUNCED, NEVER SWALLOWED. Both exit 77 — the automake convention — when the
# box cannot host them: no flock, or no fixture database server. A gate that reported "could
# not check" as all-clear would displace the suspicion that would have prompted a look
# (law-alerts-must-be-actionable).
# ---------------------------------------------------------------------------------------
run() {                  # run <suite> — its output only when it matters
    local s="$1" out st
    out="$(timeout "${SPIRA_SUITE_TIMEOUT:-600}" bash "$s" 2>&1)"; st=$?
    case "$st" in
        0)  printf 'gate: %-22s ok\n' "$(basename "$s")" >&2 ;;
        77) printf 'gate: %-22s SKIPPED — %s\n' "$(basename "$s")" \
                "$(printf '%s' "$out" | sed -n 's/.*SKIP *//p' | head -1)" >&2 ;;
        124) printf '%s\n' "$out" >&2
             say "$(basename "$s") was killed at ${SPIRA_SUITE_TIMEOUT:-600}s"; rc=1 ;;
        *)  printf '%s\n' "$out" >&2
            say "$(basename "$s") FAILED (rc=$st)"; rc=1 ;;
    esac
}

# THE THIRD IS THE VERDICT CHECK, and it earns its place by the same rule as the other two:
# it is a property of the pipeline, not of a function's return value. A bead that is reopened
# forever is a queue that has stopped moving, and it costs an Opus session every two minutes
# while it does — which is more than every quality check this gate deleted was ever worth.
# 13s.
#
# THE FOURTH IS THE WATCHTOWER'S OWN, and it earns its place by the same rule read the other
# way round. A gate that breaks refuses good work, loudly; a DETECTOR that breaks reports the
# stall and the healthy case identically, and the reassuring reading is the one it gives.
# Detection is what this gate deferred to (law-detection-outranks-rejection), so the one
# check the deleted 17 minutes cannot be traded for is that the detector can still read the
# far end of the queue. Its headline field was unreadable from the day it shipped and woke
# three Ops sessions before anyone looked at the bytes. Under a second, no database.
for s in spira/test-soak.sh spira/test-poison.sh spira/test-aeon-verdict.sh spira/test-watchtower.sh; do
    [ -r "$s" ] || { say "$s is missing — refusing to report a pass without it"; exit 1; }
    run "$s"
done

exit "$rc"
