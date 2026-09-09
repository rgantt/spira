#!/usr/bin/env bash
#
# suites.sh — run every suite the landing gate does not, on a schedule.
#
#   suites.sh list           every spira/test-*.sh, where it runs, and its last result
#   suites.sh run            run the timed set inside the budget; file a bead per red
#   suites.sh status         the compact block the watchtower puts on the sweep
#
# WHY THIS EXISTS. A suite that nothing runs is not a cheap test, it is a false record of
# coverage — worse than no suite, because its existence is what stops anybody writing the
# check it was supposed to be (law-absence-needs-a-positive-control). Measured once: nine
# suites in the tree, four named by the gate, FIVE executed by nothing at all, three of those
# landed the same night with their beads closed citing them as verification. The growth
# problem was never that the gate gets longer as features arrive. It is that a new suite is
# written, goes green once in its author's session, and is then run by nothing, forever.
#
# WHY A TIMED RUN AND NOT SELECTION. Selection picks from a registry; these suites were in no
# registry, so no selector would have found them either. Selection is also unsound in the one
# direction that matters until this exists: an unmapped file falls back to "run everything",
# and "everything" was a hand-maintained list already missing five of nine. The full run is
# what makes selection safe later, not the other way round — and the `# covers:` lines the
# selector will want are still on eight of the suites and cost nothing to keep.
#
# DISCOVERY IS A GLOB, NEVER A LIST. `spira/test-*.sh` is the whole population. A list is the
# thing that just failed, so a new suite is run by existing to be found, and a deleted one
# stops being run with no edit anywhere. The ONE hand-written list is the gate's, in
# `gate-suites`, and this runs its complement — so a suite dropped from the gate moves here
# rather than out of the world, and neither set can be edited into overlapping the other.
#
# A SUITE WITH NO `# covers:` LINE IS STILL RUN. The annotation is for selection, which is a
# later bead; a missing one is reported as an omission and never as a reason to skip. Skipping
# it would reproduce this defect exactly, in a mechanism written to end it.
#
# IT DOES NOT REOPEN, BLOCK OR POISON ANYTHING. A red files a bead and nothing more. By
# law-reversibility-outranks-coverage a failure caught twenty minutes after landing is fine
# when a revert undoes it, and a timed runner that could refuse work would be the seventeen
# minutes back on the critical path under a different name.
#
# WHERE IT RUNS: inside the Ops session, which is why there is no timer unit for it. The
# watchtower NAMES this scan on the sweep it files and Ops runs it. That division is not
# decoration — the watchtower's whole contract is to be deterministic and cheap, because the
# one thing a detector may not be is another thing that is down during an outage, and a
# several-minute test run inside it would make it exactly that.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib.sh"

STATE="${SPIRA_SUITES_STATE:-$SPIRA_RUN/suites}"
BUDGET="${SPIRA_SUITES_BUDGET:-420}"
# SPIRA_SUITES_MAXSEC is the systemd timeout that will kill this process, injected by the
# unit's Environment= line. Cap the budget 60 seconds under it so cleanup always completes.
# A conf override of SPIRA_SUITES_BUDGET cannot then schedule work past the kill deadline.
if [ -n "${SPIRA_SUITES_MAXSEC:-}" ]; then
    _suites_cap=$(( SPIRA_SUITES_MAXSEC - 60 ))
    [ "$BUDGET" -gt "$_suites_cap" ] && BUDGET="$_suites_cap"
    unset _suites_cap
fi
PER_SUITE="${SPIRA_SUITE_TIMEOUT:-600}"
STALE="${SPIRA_SUITES_STALE:-21600}"
PRIORITY="${SPIRA_SUITES_PRIORITY:-2}"
GATE_LIST="${SPIRA_GATE_SUITES:-$HERE/gate-suites}"
INC="${SPIRA_INCIDENT:-$HERE/incident.sh}"
CURSOR="$STATE/cursor"

# --------------------------------------------------------------------------------------
# THE POPULATION, AND THE PARTITION OF IT.
# --------------------------------------------------------------------------------------
# all_suites -> every suite in the tree, basenames, sorted. The glob is the definition.
#
# `printf '%s\n' "$HERE"/test-*.sh` on a directory with no match yields the PATTERN itself,
# which would be reported as one suite named `test-*.sh` that cannot be read — so the
# existence of each is tested rather than assumed.
all_suites() {
    local f
    for f in "$HERE"/test-*.sh; do
        [ -f "$f" ] || continue
        basename "$f"
    done | sort
}

# gated_suites -> the basenames gate-suites names. Empty when the file is unreadable, and
# the caller must treat that as "unknown", never as "the gate runs nothing" — reading it as
# nothing would put every gated suite into the timed run and double the cost of a pass while
# reporting that it had found more work to do.
gated_suites() {
    local line
    [ -r "$GATE_LIST" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        basename "$line"
    done < "$GATE_LIST" | sort
}

# is_gated <basename> -> 0 when the gate already runs it
is_gated() { case " $GATED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# covers_of <basename> -> the suite's `# covers:` globs, or empty
covers_of() { sed -n 's/^# *covers: *//p' "$HERE/$1" 2>/dev/null | head -1; }

# priority_of <basename> -> the priority a red from this suite is filed at.
#
# THE SUITE DECLARES IT, with `# priority: N` beside its `# covers:` line, and the default is
# routine. How urgent a failure in some code is, is a claim about that code, and the only
# place that claim can live without becoming a second list to keep in step with the glob is
# in the suite itself. A malformed value is ignored rather than passed to `bd`, which would
# fail the create and lose the finding to a typo.
priority_of() {
    local p; p="$(sed -n 's/^# *priority: *//p' "$HERE/$1" 2>/dev/null | head -1 | tr -d '[:space:]')"
    case "$p" in [0-4]) printf '%s' "$p" ;; *) printf '%s' "$PRIORITY" ;; esac
}

# --------------------------------------------------------------------------------------
# THE RECORD. One file per suite: `<status> <epoch> <seconds> <fingerprint>`.
#
# GREEN IS RECORDED, NOT SILENT. "No bead was filed" reads identically whether every suite
# passed or the runner has not run since the box came up, and an empty directory gives the
# reassuring reading (law-absence-needs-a-positive-control). So a pass writes a positive
# record with a timestamp, and `status` reports a record older than SPIRA_SUITES_STALE as
# unrun rather than as green — which is what lets the pane render `?` instead of a zero.
# --------------------------------------------------------------------------------------
record_write() {         # record_write <basename> <status> <seconds> <fingerprint>
    mkdir -p "$STATE" 2>/dev/null || return 1
    printf '%s %s %s %s\n' "$2" "$(date +%s)" "$3" "${4:--}" > "$STATE/$1.result"
}
record_read() {          # record_read <basename> -> `<status> <epoch> <seconds> <fp>` or empty
    local f="$STATE/$1.result" st at secs fp
    [ -r "$f" ] || return 1
    # The trailing-status of `read` is ignored for the same reason the watchtower ignores it:
    # a file without a trailing newline populates every variable and then reports failure at
    # EOF. The guards below judge the CONTENT, which a truncated file cannot satisfy.
    read -r st at secs fp < "$f" 2>/dev/null || true
    [ -n "${st:-}" ] || return 1
    case "${at:-}" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s %s %s %s' "$st" "$at" "${secs:-?}" "${fp:--}"
}

# --------------------------------------------------------------------------------------
# THE FINGERPRINT — the second half of the dedupe key, the first being the suite.
#
# A PERSISTENT FAILURE MUST FILE ONCE, NOT ONCE A CYCLE. Six passes an hour against a suite
# that stays red is 144 beads a day, and a queue holding 144 copies of one problem is a queue
# nobody reads. So the ref is `<suite>:<fingerprint>` and incident.sh dedupes on it: the first
# red files, every identical red after it bumps a recurrence on the same bead, and a red that
# CHANGES is new information and files afresh.
#
# WHAT IS HASHED. The suite's FAIL lines, which every suite in this tree emits — three
# different assertion helpers, one shared word. When there are none, the tail of the output
# and the exit status, which is the honest fallback for a suite that died rather than failed
# an assertion. Both are normalised first: a scratch directory and any run of digits differ on
# every run, and a fingerprint carrying them would make each pass a new bead, which is the
# failure this is here to prevent rather than a smaller version of it.
# --------------------------------------------------------------------------------------
fingerprint() {          # fingerprint <rc> <output> -> a short stable digest
    local rc="$1" out="$2" sig
    # NO PIPE INTO A MATCHER THAT EXITS EARLY, and `|| true` because grep exits 1 on no match
    # and pipefail would make that the value of the assignment (law-no-grep-q-under-pipefail).
    sig="$(printf '%s\n' "$out" | grep -F 'FAIL' || true)"
    [ -n "$sig" ] || sig="$(printf '%s\n' "$out" | tail -n 20)"
    printf 'rc=%s\n%s\n' "$rc" "$sig" \
        | sed -e 's#/tmp/[A-Za-z0-9._-]*#/tmp/X#g' \
              -e 's#/[A-Za-z0-9._/-]*/sptest_[A-Za-z0-9_]*#/X#g' \
              -e 's/[0-9]\{3,\}/N/g' \
        | cksum | tr -d ' \t'
}

# --------------------------------------------------------------------------------------
# FILING A RED. Through incident.sh, which is the intake that already exists: it spools the
# payload to disk BEFORE touching the database and clears the spool only once the bead
# exists, it dedupes on the external ref, it bumps a recurrence rather than filing a second,
# and past SIN_AT recurrences it escalates once to the operator. None of that is worth a
# second implementation, and the recurrence count is exactly the signal wanted here: a suite
# red for five cycles is a suite nobody is fixing.
#
# THE LABELS ARE THE CALLER'S, so this lands in the BUILDER's partition rather than in Ops's.
# A broken suite is a defect in the harness — work for whoever can change the code — and Ops
# has eight minutes and a runbook, which is the wrong shape for it entirely.
#
# THE BEAD CARRIES THE OUTPUT. An incident that says "go and run it yourself" makes the aeon
# spend its first minutes reproducing what this pass has already got, and it would reproduce
# it against a tree that has moved (law-escalations-carry-their-evidence).
# --------------------------------------------------------------------------------------
file_red() {             # file_red <basename> <status> <rc> <seconds> <fp> <output>
    local s="$1" status="$2" rc="$3" secs="$4" fp="$5" out="$6" cov id=""
    cov="$(covers_of "$s")"
    if [ ! -r "$INC" ]; then
        log "suites: no intake at $INC — $s is red and the finding reaches nobody"
        return 1
    fi
    # THE ID IS THE LAST LINE, NOT THE WHOLE OUTPUT. incident.sh logs through `tee`, so its
    # progress lines share stdout with the id it returns, and a bare capture takes both — the
    # first version reported a bead id of "…incident: spooled … at /run/incident-spool/…",
    # which is a filing failure rendered as a success, complete with a plausible-looking
    # identifier. The status is checked first and the shape of the id after it, because a
    # spooled event exits non-zero and is a RETRY rather than a loss.
    local out_inc rc_inc
    out_inc="$(SPIRA_INCIDENT_TYPE=bug \
          SPIRA_INCIDENT_PRIORITY="$(priority_of "$s")" \
          SPIRA_INCIDENT_ACTOR=suites \
          SPIRA_INCIDENT_LABELS="spira,plan,repo:$SPIRA_HOME_REPO" \
          SPIRA_INCIDENT_REF="suite:$s:$fp" \
          bash "$INC" file "$s is $status in the timed suite run" - <<PAYLOAD
The timed full run — every \`spira/test-*.sh\` the landing gate does not run — found this
suite $status. It is filed and nothing is blocked: this run reopens no bead and refuses no
branch, so the fix lands as ordinary work.

  suite            $s
  status           $status (rc=$rc) after ${secs}s
  covers           ${cov:-NOTHING DECLARED — this suite has no \`# covers:\` line}
  fingerprint      $fp
  reproduce        bash spira/$s

The fingerprint is over the suite's FAIL lines with scratch paths and numbers normalised out,
and it is half the dedupe key: an identical failure next cycle bumps a recurrence on this
bead rather than filing another, and a failure that CHANGES files a new one.

--- output ---------------------------------------------------------------------------
$(printf '%s\n' "$out" | tail -c 6000)
PAYLOAD
)"; rc_inc=$?
    if [ "$rc_inc" -ne 0 ]; then
        log "suites: the intake could not file $s — it stays spooled and drain will retry"
        return 1
    fi
    id="$(printf '%s\n' "$out_inc" | tail -n 1 | tr -d '[:space:]')"
    case "${id:-}" in
        ''|*[!A-Za-z0-9-]*|-*|*-) log "suites: the intake returned no id for $s"; return 1 ;;
    esac
    printf '%s' "$id"
}

# --------------------------------------------------------------------------------------
# THE PASS.
#
# THE BUDGET IS A WALL, NOT A HOPE. This runs inside an Ops session that systemd kills at
# FAYTH_TIMEOUT_SECONDS, so a pass that overran would be killed mid-suite and would record
# nothing at all — the worst of the outcomes, because a killed pass and a clean one are the
# same silence afterwards. So each suite is given the SMALLER of its own timeout and what is
# left of the budget, and a suite that will not fit is not started.
#
# AND THE CURSOR IS WHAT MAKES THAT SOUND. Stopping at the budget every pass from the same
# starting point would run the first few suites forever and the last few never — the exact
# defect this program exists to end, rebuilt inside it. The cursor names the suite the next
# pass begins with, so the set is covered by rotation over cycles however long it grows.
# --------------------------------------------------------------------------------------
cmd_run() {
    local started deadline s out rc secs fp t0 left slice status id next_cursor="" _td_shared=0
    started="$(date +%s)"; deadline=$(( started + BUDGET ))
    mkdir -p "$STATE" 2>/dev/null

    if ! GATED="$(gated_suites)"; then
        # NOT A DEGRADED PASS THAT RUNS EVERYTHING. Without the gate's list this cannot know
        # which suites are already covered, and guessing wrong in the generous direction runs
        # the gate's own set a second time inside an eight-minute budget it does not fit in.
        log "suites: $GATE_LIST is unreadable — refusing to guess which suites the gate runs"
        return 1
    fi
    GATED=" $(echo $GATED) "

    local timed="" undeclared=""
    for s in $(all_suites); do
        is_gated "$s" && continue
        timed="$timed $s"
        [ -n "$(covers_of "$s")" ] || undeclared="$undeclared $s"
    done
    timed="$(echo $timed)"
    if [ -z "$timed" ]; then
        log "suites: every suite in the tree is gated — nothing to run on a timer"
        return 0
    fi

    # Rotate so the pass begins where the last one stopped. An unreadable or stale cursor
    # simply starts at the beginning, which is correct rather than merely safe.
    local start_at order=""
    start_at="$(cat "$CURSOR" 2>/dev/null | tr -d '[:space:]')"
    case " $timed " in *" $start_at "*) ;; *) start_at="" ;; esac
    if [ -n "$start_at" ]; then
        local seen=0
        for s in $timed; do [ "$s" = "$start_at" ] && seen=1; [ "$seen" = 1 ] && order="$order $s"; done
        for s in $timed; do [ "$s" = "$start_at" ] && break; order="$order $s"; done
    else
        order="$timed"
    fi

    printf 'timed suite run — %s suite(s) the gate does not run, %ss budget\n' \
        "$(set -- $timed; echo $#)" "$BUDGET"
    # WHAT WAS SKIPPED AND WHY, NAMED. A pass that quietly ran a subset and reported only
    # what it ran is the shape of the defect this program exists to end: the reader cannot
    # tell "the gate has this one" from "this one fell out of the world". Gated suites are
    # skipped because running them again would be paying twice inside an eight-minute budget
    # for a verdict the landing gate already produced on every branch.
    local gated_here=""
    for s in $(all_suites); do is_gated "$s" && gated_here="$gated_here $s"; done
    [ -n "$gated_here" ] && printf 'skipped — the landing gate already runs these on every branch:%s\n' "$gated_here"
    [ -n "$undeclared" ] && printf 'no `# covers:` declaration (run anyway, selection cannot see them):%s\n' "$undeclared"

    # --------------------------------------------------------------------------------------
    # SHARED TESTDB FIXTURE. Build once; suites that call testdb_up get the fast reset
    # path (~6ms via directory swap) rather than each building their own fresh database
    # (~7s). Without this, 56+ non-gated suites each pay the init cost every pass —
    # over 6 minutes of a 7-minute budget, and the last suites in the rotation are
    # cut short or killed. A suite killed mid-run by a tight slice fires its EXIT trap
    # (rm -rf its temp dir), which cascades failures in subsequent assertions.
    #
    # Vars are exported so every setsid'd suite subprocess inherits them. suites.sh's
    # own SPIRA_DB and PATH are restored immediately after the build so incident.sh and
    # bd calls here continue to reach the production store.
    #
    # BORROWERS DO NOT DROP. testdb_drop inside each suite's EXIT trap is a no-op when
    # TESTDB_SHARED=1 — only this shell drops at the end of cmd_run.
    # testdb_reset inside testdb_up clears the fixture to a clean baseline at the top
    # of every suite's testdb_up call, so each suite starts with an empty store.
    # --------------------------------------------------------------------------------------
    if . "$HERE/testdb.sh" 2>/dev/null && testdb_available 2>/dev/null; then
        local _td_real_db="$SPIRA_DB"
        local _td_real_bd="${SPIRA_BD:-}"
        local _td_had_bd; [ -n "${SPIRA_BD+x}" ] && _td_had_bd=1 || _td_had_bd=0
        local _td_real_path="$PATH"
        local _td_real_spath="${SPIRA_PATH:-}"
        local _td_had_spath; [ -n "${SPIRA_PATH+x}" ] && _td_had_spath=1 || _td_had_spath=0
        if testdb_up suites 2>/dev/null; then
            export TESTDB_SHARED=1 TESTDB_NAME TESTDB_DIR TESTDB_BASELINE \
                   TESTDB_BIN TESTDB_MODE TESTDB_BD TESTDB_STARTED_SERVICE
            # Restore production vars — the fixture is for suite subprocesses, not us.
            SPIRA_DB="$_td_real_db"; export SPIRA_DB
            PATH="$_td_real_path"; export PATH
            if [ "$_td_had_bd" = 1 ]; then SPIRA_BD="$_td_real_bd"; export SPIRA_BD
            else unset SPIRA_BD 2>/dev/null || true; fi
            if [ "$_td_had_spath" = 1 ]; then SPIRA_PATH="$_td_real_spath"; export SPIRA_PATH
            else unset SPIRA_PATH 2>/dev/null || true; fi
            _td_shared=1
        fi
    fi

    local ran=0 red=0 skipped=0 unreached=""
    # Instrument: track which suites got results, and write unreached for any that didn't.
    local suites_with_results=""
    for s in $order; do
        left=$(( deadline - $(date +%s) ))
        if [ "$left" -le 5 ]; then
            unreached="$unreached $s"
            [ -n "${next_cursor:-}" ] || next_cursor="$s"
            continue
        fi
        # Skip before starting if the last known runtime exceeds what is left; starting anyway
        # produces rc=124 on a killed process, which reads as a test failure rather than a
        # budget constraint.
        last_secs="$(record_read "$s" | awk '{print $3}' | grep -E '^[0-9]+$' || echo 0)"
        if [ "$last_secs" -gt 30 ] && [ "$left" -lt "$last_secs" ]; then
            unreached="$unreached $s"
            next_cursor="${next_cursor:-$s}"
            continue
        fi
        slice="$PER_SUITE"; [ "$left" -lt "$slice" ] && slice="$left"
        t0="$(date +%s)"
        local tmp suite_pid killer
        tmp="$(mktemp)" || return 1
        # PROCESS GROUP ISOLATION. setsid makes the suite the leader of its own process
        # group (PGID = suite_pid), so kill -- -suite_pid reaches every descendant it leaves
        # running. Without this, a suite that hangs before its own cleanup lines keeps
        # orphaned children alive past the harness timeout (sp-a8c5).
        setsid bash "$HERE/$s" > "$tmp" 2>&1 &
        suite_pid=$!
        # Watchdog: send SIGTERM to the whole process group if the suite overruns its slice.
        ( sleep "$slice" && kill -- -"$suite_pid" 2>/dev/null ) &
        killer=$!
        wait "$suite_pid" 2>/dev/null; rc=$?
        kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null || true
        # A suite killed by SIGTERM exits 128+15=143; map to 124 (timeout's convention).
        [ "$rc" -ge 128 ] && rc=124
        # SWEEP SURVIVORS. If any process remains in the suite's process group after it
        # exited, the suite has a cleanup defect. Kill them and, if the suite otherwise
        # passed, mark it red so the defect surfaces rather than being silently absorbed.
        if kill -0 -- -"$suite_pid" 2>/dev/null; then
            kill -- -"$suite_pid" 2>/dev/null || true
            if [ "$rc" -eq 0 ]; then
                printf 'FAIL: %s left background jobs after exit — killed by harness\n' "$s" >> "$tmp"
                rc=1
            fi
        fi
        out="$(cat "$tmp")" || true
        rm -f "$tmp"
        secs=$(( $(date +%s) - t0 ))
        ran=$(( ran + 1 ))
        suites_with_results="$suites_with_results $s"
        case "$rc" in
            0)  status=ok
                record_write "$s" ok "$secs" -
                printf '  %-26s ok       %ss\n' "$s" "$secs" ;;
            # 77 is the automake convention and the one this tree already uses for "the box
            # cannot host this check". It is not a pass and it is not a failure: recorded as
            # its own status so `status` can report it, and never filed, because a bead
            # saying "your box has no Dolt server" is not work anybody can do.
            77) status=skip
                record_write "$s" skip "$secs" -
                skipped=$(( skipped + 1 ))
                printf '  %-26s SKIPPED  %s\n' "$s" \
                    "$(printf '%s' "$out" | sed -n 's/.*SKIP *//p' | head -1)" ;;
            124) status=timeout
                fp="$(fingerprint "$rc" "killed at ${slice}s")"
                record_write "$s" timeout "$secs" "$fp"
                red=$(( red + 1 ))
                id="$(file_red "$s" timeout "$rc" "$secs" "$fp" "$out" || true)"
                printf '  %-26s TIMEOUT  killed at %ss  %s\n' "$s" "$slice" "${id:-not filed}" ;;
            *)  status=red
                fp="$(fingerprint "$rc" "$out")"
                record_write "$s" red "$secs" "$fp"
                red=$(( red + 1 ))
                id="$(file_red "$s" red "$rc" "$secs" "$fp" "$out" || true)"
                printf '  %-26s RED      rc=%s after %ss  %s\n' "$s" "$rc" "$secs" "${id:-not filed}" ;;
        esac
    done

    # Drop the shared fixture this shell owns; borrowers (suites) already no-op'd their drop.
    [ "$_td_shared" = 1 ] && { TESTDB_SHARED=0 testdb_drop 2>/dev/null || true; }

    # INSTRUMENT THE PASS: write an unreached record for every suite in $timed that did not
    # get a result file written. This makes visible which suites were skipped due to budget,
    # so the invariant "every suite in the tree is in exactly one column (gated or timed with
    # a result)" can be verified.
    suites_with_results=" $suites_with_results "
    for s in $timed; do
        case "$suites_with_results" in
            *" $s "*) ;; # Already has a result
            *) record_write "$s" unreached 0 - ;; # Write unreached record
        esac
    done

    # The next pass starts at the first suite this one could not reach, or at the beginning
    # when it reached them all.
    mkdir -p "$STATE" 2>/dev/null
    printf '%s\n' "${next_cursor:-}" > "$CURSOR" 2>/dev/null || true

    if [ -n "$unreached" ]; then
        printf 'budget spent after %ss — not reached this pass, and first next pass:%s\n' \
            "$(( $(date +%s) - started ))" "$unreached"
    fi
    printf '%s ran, %s red, %s skipped, %ss\n' "$ran" "$red" "$skipped" "$(( $(date +%s) - started ))"
    # Exit 2 when suites are red: incidents were filed, the pass completed normally. Exit 1
    # is reserved for errors that abort before any suite runs (gate-suites unreadable). The
    # unit carries SuccessExitStatus=2 so systemd does not mark it failed on a routine red
    # day, while a real error — which exits 1 — still marks it failed.
    [ "$red" -eq 0 ] || return 2
}

# --------------------------------------------------------------------------------------
# WHAT RUNS WHERE, AND WHAT IT LAST SAID. This is the answer to the question nobody could
# ask before: which suites in this tree are executed by nothing.
# --------------------------------------------------------------------------------------
cmd_list() {
    local s where rec st at secs age gated_ok=1
    GATED="$(gated_suites)" || gated_ok=0
    GATED=" $(echo ${GATED:-}) "
    printf '%-26s %-7s %-9s %-8s %s\n' SUITE RUNS LAST AGE COVERS
    for s in $(all_suites); do
        if [ "$gated_ok" = 0 ]; then where='?'
        elif is_gated "$s"; then where=gate
        else where=timed; fi
        rec="$(record_read "$s" || true)"
        if [ -n "$rec" ]; then
            read -r st at secs _ <<< "$rec"
            age="$(( ( $(date +%s) - at ) / 60 ))m"
        else
            # NEVER RUN AND RUN-BUT-UNRECORDED ARE THE SAME THING HERE, and both print `-`
            # rather than a status: this file is the only evidence either way, and inventing
            # a friendlier word for "no evidence" is how the original defect read as fine.
            st=-; age=-
        fi
        [ "$where" = gate ] && { st=-; age=-; }
        printf '%-26s %-7s %-9s %-8s %s\n' "$s" "$where" "$st" "$age" \
            "$(covers_of "$s" || true)"
    done
    [ "$gated_ok" = 1 ] || printf '\n%s is unreadable — which suites the gate runs is unknown\n' "$GATE_LIST"
}

# --------------------------------------------------------------------------------------
# THE BLOCK THE SWEEP CARRIES. Cheap by construction: a glob, a read per suite, no database
# and no subprocess that can hang, because the watchtower embeds it and the watchtower may
# not be another thing that is down during an outage.
#
# EVERY FIELD RENDERS `?` WHEN IT COULD NOT BE READ, never 0.
# --------------------------------------------------------------------------------------
cmd_status() {
    local s rec st at total=0 gate_n=0 timed_n=0 never=0 stale=0 red=0 skip=0 oldest="" oldest_s="" now
    now="$(date +%s)"
    if ! GATED="$(gated_suites)"; then
        printf 'suites          ?   %s is unreadable — the gated set is unknown\n' "$GATE_LIST"
        return 0
    fi
    GATED=" $(echo $GATED) "
    for s in $(all_suites); do
        total=$(( total + 1 ))
        if is_gated "$s"; then gate_n=$(( gate_n + 1 )); continue; fi
        timed_n=$(( timed_n + 1 ))
        rec="$(record_read "$s" || true)"
        if [ -z "$rec" ]; then never=$(( never + 1 )); continue; fi
        read -r st at _ _ <<< "$rec"
        case "$st" in red|timeout) red=$(( red + 1 )) ;; skip) skip=$(( skip + 1 )) ;; esac
        if [ "$(( now - at ))" -gt "$STALE" ]; then stale=$(( stale + 1 )); fi
        if [ -z "$oldest" ] || [ "$at" -lt "$oldest" ]; then oldest="$at"; oldest_s="$s"; fi
    done
    printf '  %-36s%s\n' "suites in the tree" "$total   ($gate_n gated, $timed_n timed)"
    printf '  %-36s%s\n' "timed suites with no result yet" "$never"
    printf '  %-36s%s\n' "timed results older than $(( STALE / 3600 ))h" "$stale"
    printf '  %-36s%s\n' "timed suites red at last run" "$red"
    printf '  %-36s%s\n' "timed suites skipped at last run" "$skip"
    if [ -n "$oldest" ]; then
        printf '  %-36s%sm   %s\n' "oldest timed result" "$(( (now - oldest) / 60 ))" "$oldest_s"
    else
        printf '  %-36s%s\n' "oldest timed result" "?   (nothing has run)"
    fi
}

case "${1:-list}" in
    run)    cmd_run ;;
    list)   cmd_list ;;
    status) cmd_status ;;
    *) printf 'usage: suites.sh [list|run|status]\n' >&2; exit 2 ;;
esac
