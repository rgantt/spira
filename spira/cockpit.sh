#!/usr/bin/env bash
#
# cockpit.sh — gather Spira health into .runtime/spira/cockpit.env for the cockpit pane.
#
#   cockpit.sh          one pass, write the snapshot, append a history row, exit
#   cockpit.sh loop     forever, every INTERVAL seconds
#   cockpit.sh history  append one history row from the snapshot already on disk
#
# WHY A SNAPSHOT FILE AND NOT DIRECT CALLS
# ----------------------------------------
# The pane repaints every two seconds. A pane that shelled out to `bd` and `git` would
# freeze on every repaint and paint stale frames while it did — the reason the town
# collector exists, arriving here for the same reason. The cost is paid once per pass; the
# pane reads a file.
#
# Flat `KEY='value'` so a renderer can `source` it with no parser. EVERY VALUE IS
# SHELL-QUOTED: the town snapshot once carried an unquoted `SCHED_CAP=direct dispatch
# (scheduler.max_polecats=-1)`, which is a syntax error that aborts the source, so every
# key after it silently read as unset and the whole panel rendered "?" while the collector
# looked healthy. Writes are atomic, so a half-written file cannot wedge a pane.
#
# SEPARATE FROM .runtime/cockpit.env, DELIBERATELY. That file is Gas Town's and is deleted
# with it; this one is Spira's and must survive that.
#
# THE RULE THAT GOVERNS EVERY PROBE: a probe that fails renders `?`, never 0. The town
# collector's first version returned 0 from its exception handler, so a broken parser
# displayed as "no parked beads" — a panel that reports a broken check as all-clear
# displaces the suspicion that would have prompted a look.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# The analyser is addressed as a SIBLING of this file, not through $SPIRA_HOME. A collector
# running from a worktree while its analyser resolves to the installed copy on main is a
# version skew that shows up as `?` on the panel and as nothing at all in any log.
HERE="$(cd "$(dirname "$0")" && pwd)"
COCK_DIR="$SPIRA_COCKPIT"

SNAP="$SPIRA_RUN/cockpit.env"
# No single $REPO. Every git question here is asked of the repository the BEAD named, or of
# every registered repository — see spira_repos / repo_root in lib.sh.
WINDOW_HOURS="${SPIRA_COCKPIT_WINDOW_HOURS:-24}"
INTERVAL="${SPIRA_COCKPIT_INTERVAL:-60}"

# The sentinel's own ready predicate, verbatim. A dashboard that counts ready work by a
# different rule than the harness acting on it is a second opinion, not a view.
READY_ARGS=(ready --limit 0 --exclude-type epic --label spira,plan
            --exclude-label "spira-poison,$SPIRA_ASK_LABEL")

# count <bd-args...> -> number of rows, or `?` if the query or the parse failed.
count() {
    bdq "$@" --json 2>/dev/null | json_only | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("?"); raise SystemExit
print(len(d if isinstance(d, list) else [d]))' 2>/dev/null || echo "?"
}

# age_of <path> -> seconds since last write, or `?` if it does not exist.
age_of() {
    local f="$1" m
    m="$(stat -c %Y "$f" 2>/dev/null)" || { printf '?'; return; }
    [ -n "$m" ] || { printf '?'; return; }
    printf '%d' $(( $(date +%s) - m ))
}

# unit_active <unit> -> 1 or 0. A timer that is not active is why nothing is happening, and
# it is the first thing to look at when every other number has stopped moving.
unit_active() {
    [ "$(systemctl --user is-active "$1" 2>/dev/null)" = active ] && printf 1 || printf 0
}

probe() {
    echo "SP_AT=$(date +%s)"
    echo "SP_WINDOW_HOURS=$WINDOW_HOURS"

    # ---- NOW: what each aeon is doing, by name -----------------------------------------
    # The pane repaints every two seconds and must never shell out, so the live picture is
    # assembled here: which named aeon holds which bead, for how long, and the last thing
    # it actually did — read from its stream-json trace, which is the only honest answer to
    # "is it working and on what".
    local i=0
    for pf in "$SPIRA_RUN"/aeon-*.pid; do
        [ -e "$pf" ] || continue
        aeon_alive "$pf" || continue
        local base name bead fay secs act
        base="$(basename "$pf" .pid)"          # aeon-<fayth>-<bead>
        fay="$(printf '%s' "$base" | cut -d- -f2)"
        bead="$(printf '%s' "$base" | cut -d- -f3-)"
        name="$(aeon_named "$pf")"
        secs="$(ps -o etimes= -p "$(cat "$pf" 2>/dev/null)" 2>/dev/null | tr -d ' ')"
        # SANITISE HARD. This value is arbitrary text from an agent's trace — a shell
        # command, a code fragment, whatever it last did. Newlines in it inject extra lines
        # into the snapshot, and any that contain `=` become bogus keys; the pane then
        # rendered rustfmt's help text where the ops summary belongs. Strip to a single
        # line, drop the characters that make a KEY=value file ambiguous, then truncate.
        act="$(trace_last "$SPIRA_RUN/$bead.log" 2>/dev/null)"
        # The title, so NOW says what is being worked and not only its id — the same help
        # NEXT gives for queued work.
        local title
        title="$(bdjson show "$bead" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin); i = (d if isinstance(d, list) else [d])[0]
except Exception: raise SystemExit
import re
print(re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", (i.get("title") or ""))[:80])' 2>/dev/null)"
        echo "SP_AEON${i}_TITLE=${title:-?}"
        echo "SP_AEON${i}_NAME=${name:-?}"
        echo "SP_AEON${i}_FAYTH=${fay:-?}"
        echo "SP_AEON${i}_BEAD=${bead:-?}"
        echo "SP_AEON${i}_MIN=$(( ${secs:-0} / 60 ))"
        echo "SP_AEON${i}_ACT=${act:-(no trace yet)}"
        i=$((i+1))
    done
    echo "SP_AEON_N=$i"

    # ---- NEXT: what the graph says to do, in the order it will be claimed ---------------
    bdjson ready --limit 0 --exclude-type epic --label spira,plan \
           --exclude-label "spira-poison,$SPIRA_ASK_LABEL" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
rows = d if isinstance(d, list) else [d]
# AND THE TITLES ARE CUT AT EIGHTY, NOT FIFTY-EIGHT. The pane cuts a row to the width it
# has and marks the cut; the collector cannot, because it does not know how wide the column
# is. A cap here tighter than the pane would be a silent truncation nothing can report, and
# the width of that column is set by whoever runs the harness.
#
# APOSTROPHES ARE FORBIDDEN IN THIS BLOCK. It lives inside python3 -c '...', so one
# would close the quote and leave the whole file syntactically invalid.
#
# TWENTY, NOT FOUR. The pane is a full-height column now and sizes each section to the rows
# it is given, so the COLLECTOR is the binding constraint before the renderer is: four keys
# render as four rows into twenty rows of space, which looks broken in a new way. The cap
# matches health.sh MAX_SECTION_ROWS -- there is no point emitting more than can be shown.
for n, i in enumerate(rows[:20]):
    print("SP_NEXT%d=P%s %s %s" % (n, i.get("priority"), i["id"], (i.get("title") or "")[:80].replace("=", "-")))
print("SP_NEXT_N=%d" % len(rows))
' 2>/dev/null

    # ---- RECENT: TRANSITIONS, not just outcomes ----------------------------------------
    # This listed sentinel ACTs alone — landed, reopened, poisoned, reaped — which are all
    # ENDINGS. A bead being CLAIMED was invisible, and so was a bead being DROPPED: an aeon
    # exited mid-CI believing something would resume it, the lease expired, and the pane
    # showed a 52-minute-old landing while 21 commits sat abandoned. Nothing on screen said
    # a thing had changed hands. Merging the aeon ledger in makes this a lifecycle, so a
    # switch explains itself instead of having to be inferred from a clock.
    {
        grep -E 'ACT (landed|reopened|poisoned|reclaimed [0-9]|announced|reaped)' \
             "$SPIRA_RUN/sentinel.log" 2>/dev/null | tail -40 \
          | sed -E 's/^([^ ]+) spira: ACT /\1 /'
        # strand.sh's output carries NO timestamp of its own — it is printed inside a pass.
        # Stamping it with now() made a half-hour-old reclaim read "0s ago", which is the
        # dashboard lying about the single event that mattered. Attribute each line to the
        # most recent timestamped line above it, as the sending's counters already are.
        python3 -c '
import sys, re
ts, out = None, []
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) ", line)
    if m:
        ts = m.group(1)
        continue
    if line.startswith("RECLAIMED ") and ts:
        parts = line.split()
        if len(parts) > 1:
            out.append("%s reclaimed %s" % (ts, parts[1]))
print("\n".join(out[-20:]))
' "$SPIRA_RUN/sentinel.log" 2>/dev/null
        awk '$3 ~ /^sp-/ && $2 == "awake" { printf "%s claimed %s\n", $1, $3 }' \
            "$SPIRA_RUN/aeon-ledger.log" 2>/dev/null | tail -40
    # EVERY STAGE OF THIS PIPELINE IS A CAP AND THE SMALLEST ONE DECIDES. Widening only the
    # last would still emit four events, because each source is trimmed before the merge.
    } | sort -r | head -20 | python3 -c '
import sys, datetime
now = datetime.datetime.now(datetime.timezone.utc)
for n, line in enumerate(sys.stdin):
    parts = line.strip().split(" ", 1)
    if len(parts) < 2:
        continue
    try:
        t = datetime.datetime.strptime(parts[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        secs = int((now - t).total_seconds())
    except Exception:
        continue
    if secs < 90: rel = "%ds ago" % secs
    elif secs < 5400: rel = "%dm ago" % (secs // 60)
    elif secs < 172800: rel = "%dh ago" % (secs // 3600)
    else: rel = "%dd ago" % (secs // 86400)
    print("SP_EVENT%d=%-7s %s" % (n, rel, parts[1].strip()[:80].replace("=", "-")))
'

    # ---- AWAITING CI: parked on a run, and parked on nothing -----------------------------
    # A parked bead has no aeon and is not stranded — its review is open and the sweep is
    # watching. That makes it invisible in every other figure on this pane: not in progress,
    # not ready, nothing moving. Without a line of its own, work parked for an hour looks
    # exactly like work nobody started.
    #
    # TWO POPULATIONS, AND THE SMALLER ONE IS THE ONE THAT MATTERS. "Waiting on a run" is
    # routine and needs no reader. "Parked with no run to wait for" is a bead that will wait
    # forever: the label excludes it from every predicate and from the stranded-work report,
    # so a park in a repository that opens no pull requests is not merely stalled, it is
    # invisible — and this pane called it "in CI", which is the one description that stops
    # anybody looking for the real cause. spira_ci_park_state decides which it is, and it is
    # the same function the sweep acts on, so the pane cannot disagree with the harness.
    #
    # Age comes from updated_at, which the label write moves. It is a proxy for "entered this
    # state" and a good one, since a parked bead is not otherwise touched.
    # NOT `--status open`. A parked bead may still be in_progress — the aeon that labelled
    # it has not necessarily exited yet — and filtering on open alone reported zero while a
    # bead sat labelled and visible in `bd show`. Take everything not closed.
    # ONE PYTHON PASS FOR THE ORDERING, ONE BASH PASS FOR THE VERDICT. The rows come out
    # oldest first with their age already rendered, because the timestamps are python's to
    # parse; the classification is spira_ci_park_state, which is the SAME function the sweep
    # acts on, so this pane cannot disagree with the harness about what is parked on nothing.
    local ci_rows ci_id ci_repo ci_at ci_rel ci_title ci_state ci_n=0
    local ci_watch=0 ci_stuck=0 ci_oldest=- ci_age=- ci_stuck_id=-
    if ci_rows="$(bdjson list --all --limit 0 --label "$SPIRA_CI_LABEL" 2>/dev/null | python3 -c '
import sys, json, datetime, re
d = json.load(sys.stdin)
home = sys.argv[1]
rows = [i for i in (d if isinstance(d, list) else [d]) if i.get("status") != "closed"]
def when(v):
    try: return datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception: return None
def rel(secs):
    if secs < 90: return "%ds" % secs
    if secs < 5400: return "%dm" % (secs // 60)
    if secs < 172800: return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)
now = datetime.datetime.now(datetime.timezone.utc)
aged = sorted(((when(i.get("updated_at")) or now, i) for i in rows), key=lambda r: r[0])
for t, i in aged[:20]:
    repo = next((l[5:] for l in (i.get("labels") or []) if l.startswith("repo:")), home)
    # The title is sanitised and the fields are tab separated, so a title carrying a tab or a
    # control character cannot shift the columns the reader below splits on.
    title = re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", (i.get("title") or ""))[:80]
    print("%s\t%s\t%s\t%s\t%s" % (i["id"], repo, i.get("updated_at") or "",
                                    rel(int((now - t).total_seconds())), title))' "$(spira_home_repo)" 2>/dev/null)"
    then
        while IFS="$(printf '\t')" read -r ci_id ci_repo ci_at ci_rel ci_title; do
            [ -n "$ci_id" ] || continue
            # A PARK THIS CANNOT AGE COUNTS AS STUCK, which is where the pane and the sweep
            # deliberately part company: the sweep will not strip a label on the strength of a
            # clock it could not read, but a pane that paints an unreadable check as normal
            # displaces the suspicion that would have prompted a look.
            ci_state="$(spira_ci_park_state "$ci_repo" "$ci_at")" || ci_state=no-ci
            # OLDEST FIRST, so the first row is the oldest and the first STUCK row is the
            # oldest of those — no second sort, and no arithmetic that can disagree with the
            # order the section renders in.
            [ "$ci_oldest" = - ] && { ci_oldest="$ci_id"; ci_age="$ci_rel"; }
            if [ "$ci_state" = watch ]; then
                ci_watch=$(( ci_watch + 1 ))
            else
                ci_stuck=$(( ci_stuck + 1 ))
                [ "$ci_stuck_id" = - ] && ci_stuck_id="$ci_id"
                # THE ROW CARRIES ITS OWN REASON. A count in the summary says how many are
                # stuck; only the row says which, and a reader looking at one bead should not
                # have to work out which population it fell into.
                ci_title="no run to wait for · $ci_title"
            fi
            # ONE KEY PER PARKED BEAD, so the CI section has something to expand INTO. The
            # summary line answers "is anything parked"; it cannot answer "which of them has
            # been parked since yesterday", and that is the question a stalled run is found by.
            printf 'SP_AWAITING%d=%-10s %-4s %s\n' "$ci_n" "$ci_id" "$ci_rel" "$ci_title"
            ci_n=$(( ci_n + 1 ))
        done <<< "$ci_rows"
        echo "SP_AWAITING_N=$ci_watch"
        echo "SP_AWAITING_STUCK=$ci_stuck"
        echo "SP_AWAITING_STUCK_ID=$ci_stuck_id"
        echo "SP_AWAITING_OLDEST=$ci_oldest"
        echo "SP_AWAITING_AGE=$ci_age"
    else
        # A FAILED PROBE RENDERS `?`, NEVER 0. The first version of this pane returned 0 from
        # its exception handler, so a broken parser displayed as "no parked beads".
        echo "SP_AWAITING_N=?"; echo "SP_AWAITING_STUCK=?"; echo "SP_AWAITING_STUCK_ID=?"
        echo "SP_AWAITING_OLDEST=?"; echo "SP_AWAITING_AGE=?"
    fi

    # ---- FLOW: what is moving between the operator and the harness ------------------------------
    local waiting unread
    waiting=$(bdjson list --status open --limit 0 --label "$SPIRA_ASK_LABEL" 2>/dev/null | json_count)
    unread=$("$COCK_DIR/unanswered.sh" --count 2>/dev/null | tail -1)
    echo "SP_WAITING=${waiting:-?}"
    echo "SP_UNANSWERED=${unread:-?}"

    # ---- THROUGHPUT: what closed and what opened, by kind --------------------------------
    bdjson list --all --limit 0 --label spira,plan 2>/dev/null | python3 -c '
import sys, json, datetime
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
rows = d if isinstance(d, list) else [d]
cut = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
def when(v):
    try: return datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception: return None
closed = [i for i in rows if i.get("status") == "closed" and (when(i.get("closed_at") or i.get("updated_at")) or cut) >= cut]
opened = [i for i in rows if (when(i.get("created_at")) or cut - datetime.timedelta(1)) >= cut]
kinds = {}
for i in closed: kinds[i.get("issue_type") or "task"] = kinds.get(i.get("issue_type") or "task", 0) + 1
print("SP_CLOSED_24H=%d" % len(closed))
print("SP_OPENED_24H=%d" % len(opened))
print("SP_CLOSED_KINDS=%s" % (", ".join("%s %d" % (k, v) for k, v in sorted(kinds.items(), key=lambda x: -x[1])[:4]) or "-"))
' 2>/dev/null

    # ---- the unsent backlog ------------------------------------------------------------
    # Current state, not log history: how many spira/* branches exist right now and how old
    # the oldest is. A branch that keeps ageing is work that landed nowhere, which is how a
    # fiend starts — before sending.sh, one such branch was re-merged and re-pushed every
    # two minutes forever because git would not delete it while a worktree held it.
    # A failed probe renders `?`, never 0: "no unsent work" is the reassuring answer and
    # must never be the one a broken git call produces.
    # ACROSS EVERY REPOSITORY. A bead names the checkout it is worked in, so counting only
    # the home repo's branches would report "no unsent work" while another repository's
    # branches aged forever — the reassuring answer, produced by looking in the wrong place.
    # Refs are a local read, so this costs nothing per repository; no fetch happens here.
    _fail=0; _n=0; _o=""
    for _r in $(spira_repos); do
        _p="$(repo_root "$_r")" || continue
        [ -e "$_p/.git" ] || continue
        # How many unsent branches are FINISHED — their bead is closed, so they await only
        # the rites. That is the number saying whether the sending is keeping up.
        _done=0
        for _b in $(git -C "$_p" for-each-ref --format='%(refname:short)' 'refs/heads/spira/*' 2>/dev/null); do
            _st="$(bdjson show "${_b#spira/}" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin); print((d if isinstance(d, list) else [d])[0].get("status", ""))
except Exception: print("")' 2>/dev/null)"
            [ "$_st" = closed ] && _done=$((_done+1))
        done
        echo "SP_BRANCH_DONE=$_done"
        if _brs=$(git -C "$_p" for-each-ref --format='%(committerdate:unix)' 'refs/heads/spira/*' 2>/dev/null); then
            while read -r _ts; do
                [ -n "$_ts" ] || continue
                _n=$((_n+1))
                if [ -z "$_o" ] || [ "$_ts" -lt "$_o" ]; then _o="$_ts"; fi
            done <<< "$_brs"
        else
            _fail=1
        fi
    done
    if [ "$_fail" = 1 ]; then
        echo "SP_UNSENT=?"
        echo "SP_UNSENT_OLDEST_H=?"
    else
        echo "SP_UNSENT=$_n"
        if [ "$_n" -gt 0 ]; then
            echo "SP_UNSENT_OLDEST_H=$(( ( $(date +%s) - _o ) / 3600 ))"
        else
            echo "SP_UNSENT_OLDEST_H=0"
        fi
    fi

    # ---- the harness itself -----------------------------------------------------------
    # strand.sh names this as its own blind spot: a check cannot observe the failure of the
    # thing running it. The collector is not the sentinel, so it can — and this is what
    # makes every number below interpretable, because a stale graph under a dead sentinel
    # looks exactly like a quiet one under a live sentinel.
    echo "SP_SENTINEL_TIMER=$(unit_active spira-sentinel.timer)"
    echo "SP_SENTINEL_AGE=$(age_of "$SPIRA_RUN/sentinel.log")"
    echo "SP_OPS_TIMER=$(unit_active spira-ops.timer)"
    echo "SP_OPS_AGE=$(age_of "$SPIRA_RUN/ops.log")"

    # ---- the sphere grid ---------------------------------------------------------------
    # Scoped by LABEL, not by the goal epic's children: the goal epic is one pilgrimage, and
    # a dashboard that describes exactly one of them describes nothing the moment a second
    # design is in flight. Scoped to `spira,plan` for the reason in
    # law-spira-is-a-replica-until-cutover — imported beads are a snapshot of work another
    # system's workers are still doing, and counting them here would report that system's
    # backlog as this one's.
    bdq list --limit 0 --label spira,plan --json 2>/dev/null | json_only | python3 -c '
import os, sys, json
# The escalation label is one configured key, read from the environment rather than written
# in: five literals in five files is how the panel, the gate and the predicates come to
# disagree about which beads are waiting on anyone.
ASK = os.environ["SPIRA_ASK_LABEL"]
try: d = json.load(sys.stdin)
except Exception:
    for k in ("OPEN", "INPROG", "POISON", "NEEDSOP"): print("SP_%s=?" % k)
    raise SystemExit
d = d if isinstance(d, list) else [d]
def has(i, lab): return lab in (i.get("labels") or [])
# Epics are containers, not work; counting the pilgrimage itself as an open bead makes the
# graph look one item further from done than it is, forever.
work = [i for i in d if i.get("issue_type") != "epic"]
print("SP_OPEN=%d"      % sum(1 for i in work if i.get("status") != "closed"))
print("SP_INPROG=%d"    % sum(1 for i in work if i.get("status") == "in_progress"))
print("SP_POISON=%d"    % sum(1 for i in work if i.get("status") != "closed" and has(i, "spira-poison")))
print("SP_NEEDSOP=%d"  % sum(1 for i in work if i.get("status") != "closed" and has(i, ASK)))
' 2>/dev/null || { echo "SP_OPEN=?"; echo "SP_INPROG=?"; echo "SP_POISON=?"; echo "SP_NEEDSOP=?"; }

    echo "SP_READY=$(count "${READY_ARGS[@]}")"

    # ---- closed versus landed ----------------------------------------------------------
    # law-closed-is-not-landed as a running total. A bead closed with no commit naming it
    # unblocks its dependents on a lie, and everything downstream then builds on work that
    # is not there.
    #
    # THE POPULATION IS BEADS AN AEON WORKED, which is CHECK 5's population exactly: a
    # `<id>.log` in the run directory is the evidence that a session ran. Beads closed by
    # hand before the runner existed — sp-collapse-db and sp-freeze-mayor — have no commit
    # naming them and never will, so counting them would pin this line at a permanent
    # `2 unlanded` that is true, unactionable and therefore wallpaper, which is the failure
    # law-alerts-must-be-actionable is about. Scoped this way the number is normally 0 and
    # any other value is something to go and look at.
    #
    # ONE `git log`, then a membership test per id. A git invocation per closed bead is the
    # shape that makes a collector too slow to run often.
    local closed_ids subjects
    # THE BEAD'S REPOSITORY COMES OUT OF THE SAME QUERY AS ITS ID, because reading the wrong
    # repository's commit graph is wrong confidently in both directions: another repository's bead
    # that landed perfectly reads as unlanded in brain, and a panel that reports finished
    # work as lost is the same false alert as one that reports lost work as finished.
    closed_pairs="$(bdjson list --status closed --limit 0 --label spira,plan 2>/dev/null | python3 -c '
import sys, json, os
run, home = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
for i in (d if isinstance(d, list) else [d]):
    if os.path.exists(os.path.join(run, i["id"] + ".log")):
        repo = next((l[5:] for l in (i.get("labels") or []) if l.startswith("repo:")), home)
        print("%s %s" % (i["id"], repo))' "$SPIRA_RUN" "$(spira_home_repo)" 2>/dev/null)"
    closed_ids="$(printf '%s\n' "$closed_pairs" | awk 'NF{print $1}')"
    # ONE FETCH PER REPOSITORY THAT ACTUALLY HAS A CLOSED BEAD IN IT, and none at all for the
    # rest. This runs on the collector loop; fetching every registered repository each pass
    # would be thousands of round trips a day to answer a question about repositories with no
    # Spira work in them.
    #
    # The remote-tracking ref, never the local branch alone: nothing in this harness advances
    # the shared checkout's default branch — the sentinel pushes the landing branch from its
    # own worktree — so the local ref is however stale the last human left it.
    #
    # AND THE REF IS RESOLVED, NOT `main`. This appended a literal `main` to the ref list,
    # which in a `master`-based repository names nothing: `git log <ref> main` fails outright on
    # an unknown revision, so BOTH repositories contributed no subjects at all and every
    # closed bead in them counted as unlanded on the panel the operator reads.
    subjects=""
    for _r in $(printf '%s\n' "$closed_pairs" | awk 'NF{print $2}' | sort -u); do
        _p="$(repo_root "$_r")" || continue
        [ -e "$_p/.git" ] || continue
        _refs="$(spira_landrefs "$_p")" || continue
        if _rem="$(ref_remote "${_refs%% *}")"; then git -C "$_p" fetch -q "$_rem" 2>/dev/null; fi
        # shellcheck disable=SC2086
        subjects="$subjects
$(git -C "$_p" log --format='%s%n%b' -n 2000 $_refs 2>/dev/null)"
    done
    if [ -z "$closed_ids" ] || [ -z "$subjects" ]; then
        echo "SP_CLOSED=?"; echo "SP_LANDED=?"; echo "SP_UNLANDED=?"
    else
        printf '%s' "$subjects" | python3 -c '
import sys, re
ids = [i for i in sys.argv[1].split() if i]
text = sys.stdin.read()
# Bounded on both sides, so `sp-ops` does not match a commit naming `sp-ops-sop`. The commit
# subject is the only machine-checkable link between a closed bead and the commit graph
# (law-aeon-commits-name-their-bead), which is worth matching exactly.
landed = sum(1 for i in ids if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(i), text))
print("SP_CLOSED=%d"   % len(ids))
print("SP_LANDED=%d"   % landed)
print("SP_UNLANDED=%d" % (len(ids) - landed))
' "$closed_ids" 2>/dev/null || { echo "SP_CLOSED=?"; echo "SP_LANDED=?"; echo "SP_UNLANDED=?"; }
    fi

    # ---- live aeons --------------------------------------------------------------------
    # /proc, never a directory count and never `pgrep -f`. `gt polecat list` counting
    # DIRECTORIES is the original scar; `pgrep -f` is the second one, where the pattern
    # matches the searching process's own command line. aeon_alive reads argv of the
    # recorded pid.
    #
    # Read-only: a stale pidfile is left where it is rather than swept, because a collector
    # that mutates the state it reports can race the harness that owns it.
    local n=0 pf
    for pf in "$SPIRA_RUN"/aeon-*.pid; do
        [ -e "$pf" ] || continue
        aeon_alive "$pf" && n=$((n+1))
    done
    echo "SP_AEONS=$n"

    # ---- the account's own capacity -----------------------------------------------------
    # "Nothing is moving" and "nothing is moving because the account is out until 15:00" are
    # the same pixels without this, and the first of those is the reading that prompts
    # somebody to go looking for a fault that does not exist.
    #
    # READ-ONLY, unlike everywhere else this predicate is asked. capacity_paused deletes an
    # expired pause file and announces the reopening; a collector that ran every minute would
    # win that race against the sentinel and swallow the announcement into a snapshot nobody
    # reads. So the epoch is compared here by hand and the file is left for its owner.
    local cap_at cap_now
    cap_at="$(capacity_pause_until)"; cap_now="$(date +%s)"
    if [ "${cap_at:-0}" -gt "$cap_now" ] 2>/dev/null; then
        echo "SP_CAPACITY_PAUSED=1"
        echo "SP_CAPACITY_LEFT=$(( cap_at - cap_now ))"
        echo "SP_CAPACITY_AT=$(date -d "@$cap_at" +%H:%M 2>/dev/null)"
        echo "SP_CAPACITY_WHY=$(capacity_pause_why 2>/dev/null)"
    else
        echo "SP_CAPACITY_PAUSED=0"
        echo "SP_CAPACITY_LEFT=0"
        echo "SP_CAPACITY_AT="
        echo "SP_CAPACITY_WHY="
    fi

    # ---- fiends ------------------------------------------------------------------------
    if [ -f "$SPIRA_RUN/strands.json" ]; then
        python3 -c '
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: print("SP_STRANDS=?"); print("SP_STRANDS_ESCALATED=?"); raise SystemExit
print("SP_STRANDS=%d" % len(d))
print("SP_STRANDS_ESCALATED=%d" % sum(1 for v in d.values() if v.get("escalated")))
' "$SPIRA_RUN/strands.json" 2>/dev/null \
          || { echo "SP_STRANDS=?"; echo "SP_STRANDS_ESCALATED=?"; }
    else
        # No file is not the same claim as no strands: strand.sh writes it on its first
        # pass, so its absence means the detector has not run, which is a different fault.
        echo "SP_STRANDS=?"; echo "SP_STRANDS_ESCALATED=?"
    fi

    # ---- TOKENS: what the account is spending, and which half is spending it ------------
    # The rate limit is the binding constraint on everything else on this pane — when the
    # account is out of capacity no aeon can be summoned, no bead can move, and every other
    # figure here is frozen for reasons nothing else reports. It was also unattributed: the
    # harness and the interactive session were both plausible culprits and optimising the
    # wrong one is the expensive mistake.
    #
    # `tokens.sh env` READS ONLY FILES TOUCHED INSIDE THE WINDOW, which is why it can run on
    # every pass at all. The full corpus is billions of tokens of history and re-reading it
    # here would make the instrument cost more than the thing it measures. Do not "simplify"
    # that away by calling `report`.
    "$HERE/tokens.sh" env 2>/dev/null \
      || { for k in SP_TOK_WINDOW_H SP_TOK_AEON_WIN SP_TOK_SESS_WIN SP_TOK_WIN \
                    SP_TOK_AEON_TURNS SP_TOK_SESS_TURNS SP_TOK_AEON_CTX SP_TOK_SESS_CTX \
                    SP_TOK_AEON_OUT SP_TOK_SESS_OUT SP_TOK_AEON_RECENT SP_TOK_SESS_RECENT; do
               echo "$k=?"
           done; }

    # ---- LIVE CONTEXT: how close the session in front of the operator is to the edge -----
    # A total says what was spent; only the proximity says whether to act now, and acting is
    # what the operator can actually do about it. Measured by ctx-meter.sh — the same program
    # the status line calls, deliberately, so the pane and the status line cannot disagree
    # about how close to a threshold a session is.
    "$HERE/ctx-meter.sh" env 2>/dev/null \
      || { for k in SP_CTX_NOW SP_CTX_TURNS SP_CTX_GROWTH SP_CTX_NEXT SP_CTX_HEADROOM \
                    SP_CTX_TURNS_LEFT SP_CTX_AGE SP_CTX_ARCHIVIST SP_CTX_ARCHIVIST_BEHIND \
                    SP_CTX_SCAN_BYTES SP_CTX_ARCHIVIST_FILED; do
               echo "$k=?"
           done; }

    # ---- the four numbers this build got wrong -----------------------------------------
    python3 "$HERE/cockpit-metrics.py" \
        "$SPIRA_RUN/sentinel.log" "$SPIRA_RUN/aeon-ledger.log" "$WINDOW_HOURS" 2>/dev/null \
      || { for k in SP_PASSES SP_ACTS SP_FALSE_ACTS SP_FALSE_PER_PASS SP_SINCE_JUDGEMENT \
                    SP_AEON_BORN SP_AEON_LIVED SP_AEON_STILLBORN SP_AEON_WORKED; do
               echo "$k=?"
           done; }
}

# THE SERIES, because a gauge cannot answer "over time". The question the token meter exists
# for is what has been contributing to the rate limit across a day, and no instant answers it.
#
# ITS OWN FILE, under $SPIRA_RUN, for the same reason the snapshot is: the predecessor
# harness's collector owns the other cockpit-history.csv and is deleted along with it. A
# series appended by a service that is being retired stops without anyone noticing, and a
# flat line reads as calm rather than as absent.
#
# EVERY TOKEN COLUMN IS A ROLLING WINDOW TOTAL, not a counter — successive rows overlap and
# must never be summed. That is what makes it readable against the limit, which is itself a
# rolling window: the column IS the thing the account is judged on.
#
# A `?` OR `-` IS WRITTEN THROUGH VERBATIM. A probe that failed and a probe that measured zero
# are different facts, and collapsing them here would put the difference beyond recovery for
# every reader downstream.
HIST="$SPIRA_RUN/cockpit-history.csv"
HISTORY_MAX="${SPIRA_COCKPIT_HISTORY_MAX:-20160}"   # 14 days at the default 60s cadence
HIST_COLS="ts,tok_win,tok_aeon_win,tok_sess_win,tok_aeon_turns,tok_sess_turns,ctx_now"

append_history() {
    # Read back the file just written rather than the probe's own output: the snapshot is what
    # every other reader sees, so a row disagreeing with it would be a third opinion.
    #
    # IN A SUBSHELL, WHICH IS LOAD-BEARING IN `loop` MODE. Sourcing the snapshot into this
    # process leaves its keys set, so the NEXT pass — with a probe that had failed and written
    # no key at all — would quietly reuse the previous pass's figure instead of `?`. A stale
    # number presented as current is precisely the confident wrong reading the `?` rule exists
    # to prevent, and it would be indistinguishable from a healthy flat line.
    local row
    row="$(
        set +u
        # shellcheck disable=SC1090
        . "$SNAP" 2>/dev/null
        printf '%s,%s,%s,%s,%s,%s,%s' \
            "${SP_AT:-$(date +%s)}" "${SP_TOK_WIN:-?}" "${SP_TOK_AEON_WIN:-?}" \
            "${SP_TOK_SESS_WIN:-?}" "${SP_TOK_AEON_TURNS:-?}" "${SP_TOK_SESS_TURNS:-?}" \
            "${SP_CTX_NOW:-?}"
    )"
    # A CHANGED COLUMN SET ROTATES THE FILE RATHER THAN APPENDING A SECOND HEADER. Every reader
    # takes line one as the header, so a header written into the middle is parsed as data and
    # every column after it is read under the wrong name — a series that is quietly wrong is
    # worse than one that is quietly short. The old rows are moved aside, not deleted: they are
    # the only record of what came before, and nothing here is worth destroying to keep the
    # shape tidy.
    if [ ! -s "$HIST" ]; then
        echo "$HIST_COLS" > "$HIST"
    elif [ "$(head -1 "$HIST")" != "$HIST_COLS" ]; then
        mv -f "$HIST" "$HIST.$(date +%s)" 2>/dev/null
        echo "$HIST_COLS" > "$HIST"
    fi
    printf '%s\n' "$row" >> "$HIST"

    local lines; lines=$(wc -l < "$HIST" 2>/dev/null || echo 0)
    if [ "${lines:-0}" -gt $(( HISTORY_MAX + 1 )) ] 2>/dev/null; then
        { head -1 "$HIST"; tail -n "$HISTORY_MAX" "$HIST"; } > "$HIST.tmp" \
            && mv -f "$HIST.tmp" "$HIST"
    fi
}

write_snapshot() {
    local tmp="$SPIRA_RUN/.cockpit.$$"
    probe 2>/dev/null | python3 -c '
import sys
seen = set()
for line in sys.stdin:
    line = line.rstrip("\n")
    if "=" not in line:
        continue
    k, _, v = line.partition("=")
    k = k.strip()
    if not k or not (k[0].isalpha() or k[0] == "_"):
        continue
    # First wins. A key is emitted twice only when a probe printed rows and its fallback
    # then fired as well, and the first of those two is the one that actually measured
    # something — the fallback is a shape guarantee, not a reading.
    if k in seen:
        continue
    seen.add(k)
    print("%s=%s" % (k, "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27"))
' > "$tmp"
    mv -f "$tmp" "$SNAP"
    append_history
}

case "${1:-once}" in
once)
    write_snapshot
    echo "spira cockpit: $SNAP ($(wc -l < "$SNAP") keys)"
    ;;
# Appends from the snapshot ALREADY ON DISK, taking no fresh reading. It is how the series is
# repaired without disturbing the live snapshot, and it is the seam the suite drives — the
# same function the loop calls, so what is tested is what runs.
history)
    append_history
    echo "spira cockpit: $HIST ($(( $(wc -l < "$HIST") - 1 )) rows)"
    ;;
# Driven today by the town's cockpit collector, which already runs as a service. This mode
# exists so that retiring that collector is a unit file rather than a rewrite.
loop)
    while :; do write_snapshot; sleep "$INTERVAL"; done
    ;;
*) echo "usage: cockpit.sh [once|loop|history]" >&2; exit 1 ;;
esac
