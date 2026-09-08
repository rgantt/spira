#!/usr/bin/env bash
#
# qa-sweep.sh — manage QA sweep beads.
#
#   qa-sweep.sh create   file a qa-sweep bead if none is open or in_progress
#
# Called from spira-qa.service ExecStartPre before aeon.sh qa. One sweep bead per pass:
# if a previous aeon is still working (status in_progress) or a bead is waiting (status
# open), the timer already has work queued and a second bead would accumulate a backlog
# that the closing rule must then explain away for each skipped one.
#
# A failed create is not a fatal error — ExecStartPre is called with a leading `-` in the
# service file, meaning failure here does not prevent ExecStart from running. The cost of
# a missed create is one aeon that finds nothing and exits idle, which is already a normal
# outcome (law-absence-needs-a-positive-control).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib.sh"

CMD="${1:-}"; [ -n "$CMD" ] || { printf 'usage: qa-sweep.sh create\n' >&2; exit 2; }

case "$CMD" in
create)
    # Check for any open or in_progress qa-sweep bead. If one exists, do not create another.
    existing="$(bdjson list --label "spira,qa-sweep" --status open  --limit 1 2>/dev/null \
                    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d if isinstance(d,list) else [d]))' \
                    2>/dev/null)" || existing="?"
    inprog="$(bdjson list --label "spira,qa-sweep" --status in_progress --limit 1 2>/dev/null \
                    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d if isinstance(d,list) else [d]))' \
                    2>/dev/null)" || inprog="?"

    # Treat a query failure as "might exist" — refuse to create rather than risk a double.
    # A conservative false skip is cheap; a double sweep bead requires an explanation.
    if [ "$existing" = "?" ] || [ "$inprog" = "?" ]; then
        log "qa-sweep: could not read bead status — skipping create"
        exit 0
    fi
    if [ "$existing" -gt 0 ] || [ "$inprog" -gt 0 ]; then
        log "qa-sweep: a sweep bead already exists (open=$existing in_progress=$inprog) — skipping"
        exit 0
    fi

    # No existing sweep bead: create one. Priority 3 (below plan P1/P2, above background
    # work) keeps sweeps from crowding out builder work when both are ready.
    id="$(bdq create "QA sweep" --type task --priority 3 \
             -l "spira,qa-sweep,repo:spira" 2>/dev/null | grep -oE 'sp-[a-z0-9]+' | head -1)" || id=""
    if [ -n "$id" ]; then
        log "qa-sweep: created $id"
    else
        log "qa-sweep: create returned no id — the next aeon pass will find nothing and exit idle"
    fi
    ;;
*)
    printf 'qa-sweep.sh: unknown command %s\n' "$CMD" >&2; exit 2 ;;
esac
