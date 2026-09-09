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
#      machine. The third is undone by a revert and is here for a different reason: a suite
#      that reads the state of the box refuses correct work with nothing in its output
#      pointing anywhere but at the branch, and both failures the deleted 17 minutes produced
#      on its last day were that. These run first, independently, and nothing routes around
#      them.
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
# IT JUDGES THE TREE IT IS PART OF, and it finds that tree from its own path. This read
# `cd "${SPIRA_GATE_REPO:-.}"`, and the gate sets SPIRA_GATE_REPO to the INSTALLED CHECKOUT
# while extracting the branch to a scratch worktree and running the command there — so this
# line stepped out of the tree under trial and ran the installed copy's suites instead. Every
# branch was therefore judged against the code already in force, which is the one failure a
# gate must not have: it passes work it never looked at, and the landing pass acts on the
# pass. A branch that only edits existing files sails through on the installed copy's green.
# It surfaced only when a branch ADDED a suite, which the installed copy did not have.
#
# Self-located rather than configured, because where the harness IS is a fact about where
# this script sits and never a setting (law-a-split-repoints-nothing). The fence readability
# checks below are the identity check on the result, and they fail closed.
cd "$HERE/.." 2>/dev/null || { printf 'gate: cannot reach the tree holding %s\n' "$0" >&2; exit 1; }

rc=0
gate_total=0      # wall-clock seconds summed across all suites
gate_unmeasurable=0  # set to 1 if any suite's cost cannot be measured
say() { printf 'gate: %s\n' "$*" >&2; }

# file_budget_bead <total> <budget> <over> — file a bead when the gate exceeds its budget.
# Runs in a subshell so sourcing lib.sh does not pollute this script's stripped environment.
# Failure to file must not change the gate's verdict; the caller passes `|| true`.
# SPIRA_DB from the environment wins by conf.sh's env-first rule, so a test database set
# before this script was invoked is the one that receives the bead — not the operator's live
# store. In production, HOME is set (by gate.sh's env -i) so conf.sh finds spira.conf.
# THE BEAD CARRIES repo:spira. The test harness must supply a repo-map that lists "spira"
# so _bdq_check_repo_label allows the create: test-gate-budget.sh creates $SH/repo-map for
# this. Without it the check refuses quietly (no bead filed, gate still exits cleanly). (sp-2kpk2)
file_budget_bead() {
    local total="$1" budget="$2" over="$3"
    (
        . "$HERE/lib.sh" 2>/dev/null || exit 0
        local ref="gate:budget"
        # Dedupe: only file if no open bead with this ref already exists.
        # --external-ref is a create flag, not a bd list flag — filter by the field in JSON.
        local existing
        existing="$(bdq list --status open --limit 0 --json 2>/dev/null \
            | python3 -c 'import sys,json
d=json.load(sys.stdin)
match=[x for x in (d if isinstance(d,list) else []) if x.get("external_ref")=="gate:budget"]
print(match[0]["id"] if match else "")
' 2>/dev/null || true)"
        [ -n "${existing:-}" ] && exit 0
        bdq create \
            "gate: budget exceeded — ${over}s over (${total}s vs ${budget}s); something must leave gate-suites before anything joins" \
            --type chore --priority 2 \
            --labels "spira,plan,repo:spira" \
            --external-ref "$ref" \
            --body - --silent >/dev/null 2>&1 <<'BODY'
The gate has run longer than SPIRA_GATE_BUDGET. Before adding any suite to
spira/gate-suites, one must leave: the budget is what forces that argument, and without
it each suite was individually justified while the total reached 17 minutes unchecked.
BODY
    ) 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------
# 1. THE FENCES — first, and independently of everything below.
# ---------------------------------------------------------------------------------------
for fence in spira/exclude.sh spira/inventory.sh spira/hermetic.sh; do
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

# The suites are checked before any of them is run, and the check is static — so a suite that
# would have decided its verdict from this machine is named here rather than discovered later
# as a red that looks like the branch's fault (law-gates-run-in-a-clean-environment).
if ! herm="$(bash spira/hermetic.sh 2>&1)"; then
    printf '%s\n' "$herm" >&2
    exit 1
fi

# THE SOP SHELF. `sop.sh write` validates; `bd remember sop-<slug>` does not — it is the
# back door this check closes. Lint reads every sop- key and applies the same rules, so a
# runbook written directly cannot survive to be matched at 3am. An unreadable shelf fails
# closed: a broken database is not evidence that no malformed SOPs exist
# (law-absence-needs-a-positive-control, law-bake-rules-into-tools).
[ -r spira/sop.sh ] || { say "spira/sop.sh is missing — refusing to land unchecked"; exit 1; }
if ! sop_lint="$(bash spira/sop.sh lint 2>&1)"; then
    printf '%s\n' "$sop_lint" >&2
    say "sop lint FAILED — the shelf has malformed entries; fix with sop.sh write or sop.sh retire"
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
run() {                  # run <suite> — its output only when it matters; cost always
    local s="$1" out st t0 t1 elapsed elapsed_s name suite_pid killer tmp
    name="$(basename "$s")"
    t0=$(date +%s 2>/dev/null) || t0=""
    tmp="$(mktemp)" || { say "could not create temp file for $name"; rc=1; return; }
    # PROCESS GROUP ISOLATION. The original command substitution creates a pipe; a background
    # job inheriting that pipe's write end blocks the gate until it exits or is killed. Running
    # via setsid (suite gets PGID = suite_pid) lets us sweep survivors with kill -- -$suite_pid
    # after the suite exits, so no orphan can hold any descriptor open (sp-a8c5).
    setsid bash "$s" > "$tmp" 2>&1 &
    suite_pid=$!
    ( sleep "${SPIRA_SUITE_TIMEOUT:-600}" && kill -- -"$suite_pid" 2>/dev/null ) &
    killer=$!
    wait "$suite_pid" 2>/dev/null; st=$?
    kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null || true
    [ "$st" -ge 128 ] && st=124
    if kill -0 -- -"$suite_pid" 2>/dev/null; then
        printf '\nFAIL: %s left background jobs after exit — killed by gate harness\n' "$name" >> "$tmp"
        kill -- -"$suite_pid" 2>/dev/null || true
        [ "$st" -eq 0 ] && st=1
    fi
    out="$(cat "$tmp")"; rm -f "$tmp"
    t1=$(date +%s 2>/dev/null) || t1=""
    # COST IS MEASURED AROUND THE SUBPROCESS, never inferred. If date fails on either side
    # the cost is unmeasurable; unmeasurable counts as over-budget rather than free
    # (law-absence-needs-a-positive-control). The ? is rendered in the log so the reader
    # knows the measurement failed rather than seeing a suspiciously small number.
    if [ -n "$t0" ] && [ -n "$t1" ]; then
        elapsed=$(( t1 - t0 ))
        elapsed_s="${elapsed}s"
        gate_total=$(( gate_total + elapsed ))
    else
        elapsed_s="?"
        gate_unmeasurable=1
    fi
    case "$st" in
        0)  printf 'gate: %-22s ok   cost=%s\n' "$name" "$elapsed_s" >&2 ;;
        77) printf 'gate: %-22s SKIPPED — cost=%s — %s\n' "$name" "$elapsed_s" \
                "$(printf '%s' "$out" | sed -n 's/.*SKIP *//p' | head -1)" >&2 ;;
        124) printf '%s\n' "$out" >&2
             say "$name was killed at ${SPIRA_SUITE_TIMEOUT:-600}s (cost=$elapsed_s)"; rc=1 ;;
        *)  printf '%s\n' "$out" >&2
            say "$name FAILED (rc=$st, cost=$elapsed_s)"; rc=1 ;;
    esac
}

# WHICH SUITES, AND WHY EACH — in `spira/gate-suites`, one path per line with its reason
# beside it. It is a file rather than a list on the line below for one reason: nothing else
# could read the list while it lived here, so no program could answer "which suites does the
# gate NOT run", and the answer went unexamined until five of nine suites were running
# nowhere at all. `suites.sh` runs the complement on a timer, derived from the same file, so
# a suite dropped from the gate moves to the timed run rather than out of the world.
SUITE_LIST=spira/gate-suites
[ -r "$SUITE_LIST" ] || { say "$SUITE_LIST is missing — refusing to report a pass without it"; exit 1; }
# Read whole first, then run: a list that names a file which does not exist is a gate
# reporting on work it never looked at, and finding that out halfway through means the
# suites before the bad line have already been paid for.
suites=""
while IFS= read -r s || [ -n "$s" ]; do
    s="${s%%#*}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
    [ -n "$s" ] || continue
    [ -r "$s" ] || { say "$SUITE_LIST names $s, which is not here — refusing to report a pass without it"; exit 1; }
    suites="$suites $s"
done < "$SUITE_LIST"
# AN EMPTY LIST IS A FAILURE, NOT AN EMPTY GATE (law-absence-needs-a-positive-control). A
# truncated or all-comment file would otherwise run nothing and exit 0, which is the one
# verdict a gate must never reach by accident.
[ -n "$suites" ] || { say "$SUITE_LIST names no suite — refusing to report a pass on nothing"; exit 1; }

for s in $suites; do
    run "$s"
done

# ---------------------------------------------------------------------------------------
# BUDGET CHECK. The gate times itself and reports what it cost, on every run, so the timed
# run and the cockpit pane can both read it. Exceeding the budget is NOT a branch failure —
# the branch did not cause the overrun. It is a failure of the gate, reported against the
# harness: something must leave spira/gate-suites before anything else joins.
#
# AN UNMEASURABLE COST IS OVER BUDGET, NEVER FREE. A suite whose wall-clock cannot be
# read renders `?` and the gate treats it as an overrun, because a measurement that reports
# zero for the wrong reason is worse than one that flags uncertainty.
# ---------------------------------------------------------------------------------------
gate_budget="${SPIRA_GATE_BUDGET:-300}"
if [ "$gate_unmeasurable" -eq 1 ]; then
    say "cost total=?s budget=${gate_budget}s (one or more suite costs were unmeasurable)"
    file_budget_bead "?" "$gate_budget" "?" || true
elif [ "$gate_total" -gt "$gate_budget" ]; then
    over=$(( gate_total - gate_budget ))
    say "cost total=${gate_total}s budget=${gate_budget}s EXCEEDED by ${over}s"
    say "this is a gate fault, not a branch fault — filing a bead against the harness"
    say "something must leave spira/gate-suites before anything else joins it"
    file_budget_bead "$gate_total" "$gate_budget" "$over" || true
else
    say "cost total=${gate_total}s budget=${gate_budget}s"
fi

exit "$rc"
