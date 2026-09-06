#!/usr/bin/env bash
#
# health.sh — the cockpit's bottom-right pane: Spira health first, Gas Town beneath it.
#
#   health.sh          repaint every 2s forever (pane mode)
#   health.sh once     paint one full frame and exit
#
# Reads the snapshots written by the collectors — `.runtime/spira/cockpit.env` from
# `.claude/spira/cockpit.sh`, `.runtime/cockpit.env` from `.claude/cockpit/collect.sh`.
# NEVER calls `bd`, `gt` or `git` itself: the expensive sources cost ~27s a pass and a pane
# that shelled out would freeze on every repaint.
#
# WHY SPIRA IS ON TOP
# -------------------
# This pane used to instrument only Gas Town, which is frozen and being retired, while the
# harness actually running the operator's work — sentinel, aeons, the landing gate — had no display
# at all. A dashboard whose subject is the system being decommissioned reports on the past.
# Gas Town keeps a line because it is still serving; it keeps ONE line because that is what
# a retiring system is worth.
#
# WHAT IS ON IT, AND WHY THOSE
# ----------------------------
# The selection rule is the operator's: **instrument the numbers that surprised us.** Every line is
# something whose real value differed from what a reasonable person would assume, in a way
# that cost time. For Spira they are the ones this build itself got wrong:
#
#   born → lived     the first aeon ever summoned was killed inside the same second by the
#                    oneshot's cgroup teardown, while the sentinel reported "summoned" every
#                    two minutes into an empty log. A summon is not a worker.
#   closed → landed  CLOSED IS NOT LANDED. A bead closed with no commit naming it unblocks
#                    its dependents on a lie.
#   falseACT         CHECK 6 re-landed one branch forever because `git branch -D` refuses a
#                    branch a worktree holds and the error went to /dev/null. `acted` was
#                    therefore never 0, and CHECK 8 fires only when `acted` is 0 — so the
#                    harness could not notice it was starved. The reclaim probe had already
#                    done the same by matching its own idle message.
#   judgement        both of those bugs worked by making the judgement tier unreachable.
#                    "never fired" and "fired 40 passes ago" look identical from outside.
#   sentinel age     strand.sh cannot detect that the sentinel is dead, because a check
#                    cannot observe the failure of the thing running it. This pane can.
#
# And for Gas Town, kept because each is still true: polecats live-vs-directories, parked
# beads, orphaned commits, undrained watcher events, unread mail, statute drift.
#
# A `?` means the probe FAILED. It never renders as 0 — a panel that reports a broken check
# as "all clear" displaces the suspicion that would have prompted a look.
#
# THE PANE IS FIVE ROWS TALL. Lines are emitted in priority order and the frame is cut to
# the terminal's real height, with the count of dropped lines marked on the header. Before
# that, seven lines were written into five and the top two scrolled away unannounced —
# a dashboard that hides its own content is the failure mode it exists to prevent.
set -uo pipefail

# Every path comes from the harness's one configuration surface. It is two directories
# away because the cockpit ships beside the harness, not inside it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../spira" && pwd -P)/conf.sh"

RUN="$SPIRA_REPO/.runtime"
SNAP="$RUN/cockpit.env"
# FROM $SPIRA_RUN, NOT DERIVED. cockpit.sh writes its snapshot to $SPIRA_RUN/cockpit.env, and
# SPIRA_RUN is configurable — a reader that recomputed the path would render `?` for every
# Spira row the moment an operator moved it, and a panel that reports a broken read as
# "nothing happening" displaces the suspicion that would have prompted a look.
SPIRA_SNAP="$SPIRA_RUN/cockpit.env"
HIST="$RUN/cockpit-history.csv"

C_RST=$'\e[0m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'
C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_ACC=$'\e[36m'

# Sparkline over the last N values of a named history column.
spark() {
    local col="$1" n="${2:-24}"
    [ -f "$HIST" ] || { printf '%s' ""; return; }
    python3 - "$HIST" "$col" "$n" <<'PY' 2>/dev/null || printf '%s' ""
import sys, csv
path, col, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
blocks = "▁▂▃▄▅▆▇█"
try:
    with open(path) as f:
        rows = list(csv.DictReader(f))
except Exception:
    sys.exit(0)
vals = []
for r in rows[-n:]:
    try: vals.append(float(r[col]))
    except Exception: vals.append(0.0)
if not vals: sys.exit(0)
lo, hi = min(vals), max(vals)
if hi - lo < 1e-9:
    print(blocks[0] * len(vals) if hi == 0 else blocks[3] * len(vals), end="")
else:
    print("".join(blocks[min(7, int((v - lo) / (hi - lo) * 7.999))] for v in vals), end="")
PY
}

dot() { [ "${1:-0}" = "1" ] && printf '%s●%s' "$C_OK" "$C_RST" || printf '%s○%s' "$C_BAD" "$C_RST"; }

# Render a count: green at zero, coloured above a threshold, and `?` always loud.
num() { # value warn_at label
    local v="$1" w="$2" l="${3:-}"
    if [ "$v" = "?" ]; then printf '%s%s?%s%s' "$C_BAD" "$C_B" "$C_RST" "$l"
    elif [ "$v" -ge "$w" ] 2>/dev/null; then printf '%s%s%s%s' "$C_WARN" "$v" "$C_RST" "$l"
    else printf '%s%s%s%s' "$C_OK" "$v" "$C_RST" "$l"; fi
}

# Like num, but a non-zero value is an outright fault rather than a threshold to watch:
# a stillborn aeon, an unlanded closed bead. Zero is the only healthy reading.
bad_unless_zero() {
    local v="$1" l="${2:-}"
    if [ "$v" = "?" ]; then printf '%s%s?%s%s' "$C_BAD" "$C_B" "$C_RST" "$l"
    elif [ "$v" = "0" ]; then printf '%s0%s%s' "$C_OK" "$C_RST" "$l"
    else printf '%s%s%s%s%s' "$C_BAD" "$C_B" "$v" "$C_RST" "$l"; fi
}

# age <seconds> <warn> -> "12s" / "4m", coloured. `?` if the file was never written.
age_str() {
    local a="$1" w="$2" s
    [ "$a" = "?" ] && { printf '%s%s?%s' "$C_BAD" "$C_B" "$C_RST"; return; }
    if [ "$a" -lt 120 ] 2>/dev/null; then s="${a}s"; else s="$(( a / 60 ))m"; fi
    if [ "$a" -ge "$w" ] 2>/dev/null; then printf '%s%s%s' "$C_BAD" "$s" "$C_RST"
    else printf '%s%s%s' "$C_DIM" "$s" "$C_RST"; fi
}

# ======================================================================================
# SPIRA — four lines, and every one of them is a number this build got wrong at least once.
# ======================================================================================
spira_lines() {
    set +u; [ -f "$SPIRA_SNAP" ] && . "$SPIRA_SNAP" 2>/dev/null
            [ -f "$RUN/spira/budget.env" ] && . "$RUN/spira/budget.env" 2>/dev/null; set -u

    # A LABELLED SECTION PER QUESTION. The old single line read
    # "open 25 ready 17 working 1 aeons 1 poison 1 asks 0 fiends 0" — beads, sessions and
    # asks in one undifferentiated row, so nothing could be read at a glance and the counts
    # looked like they measured the same kind of thing (the operator, verbatim: "i can't tell
    # at a glance what's actually happening"). Each line now answers one question and says
    # which one.

    local age="?" stale=""
    [ -n "${SP_AT:-}" ] && age=$(( $(date +%s) - SP_AT ))
    [ "$age" != "?" ] && [ "$age" -gt 180 ] && stale="  ${C_BAD}STALE ${age}s${C_RST}"
    printf '%s%sSPIRA%s %s   %ssentinel%s %s %ss  %sops%s %s %ss%s\n' \
        "$C_B" "$C_ACC" "$C_RST" "$(date +%H:%M)" \
        "$C_DIM" "$C_RST" "$(dot "${SP_SENTINEL_TIMER:-0}")" "${SP_SENTINEL_AGE:-?}" \
        "$C_DIM" "$C_RST" "$(dot "${SP_OPS_TIMER:-0}")" "${SP_OPS_AGE:-?}" "$stale"

    # NOW — who is working, on what, and what they last actually did. An aeon has a name
    # so two of them are distinguishable; the action comes from its stream-json trace.
    if [ "${SP_AEON_N:-0}" -eq 0 ]; then
        printf ' %sNOW%s    %sno aeon working%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
    else
        local i=0
        while [ "$i" -lt "${SP_AEON_N:-0}" ]; do
            eval "local nm=\${SP_AEON${i}_NAME:-?} fy=\${SP_AEON${i}_FAYTH:-?}"
            eval "local bd=\${SP_AEON${i}_BEAD:-?} mn=\${SP_AEON${i}_MIN:-?} ac=\${SP_AEON${i}_ACT:-}"
            eval "local ti=\${SP_AEON${i}_TITLE:-}"
            # WHO, then WHAT, then the live action — one question per line. Crammed onto
            # one row the name, the bead, the elapsed time and a shell command ran past the
            # pane width and truncated mid-word.
            printf ' %s%s%s    %s%s%s %sthe %s · %sm%s\n' \
                "$C_DIM" "$([ "$i" = 0 ] && printf 'NOW' || printf '   ')" "$C_RST" \
                "$C_OK$C_B" "$nm" "$C_RST" "$C_DIM" "$fy" "$mn" "$C_RST"
            # Same shape as a NEXT row, deliberately: id in the accent colour, title dim,
            # so a bead being worked and a bead about to be worked read as the same kind of
            # thing in the same place on the line.
            printf '        %s%-22s%s %s%s%s\n' "$C_ACC" "$bd" "$C_RST" "$C_DIM" "${ti:-?}" "$C_RST"
            [ -n "$ac" ] && printf '        %s↳ %s%s\n' "$C_DIM" "$(printf '%s' "$ac" | cut -c1-92)" "$C_RST"
            i=$((i+1))
        done
    fi

    # NEXT — the order the graph will actually be claimed in.
    # CLAIM ORDER, not "the top of each priority". These are literally the next two beads
    # `bd ready --claim` would take, in that order.
    printf ' %sNEXT%s   %s%s ready%s %s— next to be claimed:%s\n' "$C_DIM" "$C_RST" \
        "$C_B" "${SP_NEXT_N:-?}" "$C_RST" "$C_DIM" "$C_RST"
    next_row() {   # "P0 sp-id Title..." -> aligned id + dim title, matching NOW
        local raw="$1" pri id rest
        pri="${raw%% *}"; rest="${raw#* }"; id="${rest%% *}"; rest="${rest#* }"
        printf '        %s%s%s %s%-19s%s %s%s%s\n' \
            "$C_DIM" "$pri" "$C_RST" "$C_ACC" "$id" "$C_RST" "$C_DIM" "$rest" "$C_RST"
    }
    # ONE ROW EACH for NEXT and RECENT (the operator's call). The queue depth is on the
    # header line and the rest is a `bd ready` away; a dashboard earns its space by being
    # glanceable, and three rows of backlog is a list, not a glance.
    [ -n "${SP_NEXT0:-}" ] && next_row "$SP_NEXT0"

    # RECENT — what the harness did, newest first.
    printf ' %sRECENT%s %s%s%s\n' "$C_DIM" "$C_RST" "$C_DIM" "${SP_EVENT0:-—}" "$C_RST"


    # FLOW — everything moving between the operator and the harness, in one place.
    local unans_col="$C_OK"; [ "${SP_UNANSWERED:-0}" != 0 ] && unans_col="${C_BAD}${C_B}"
    local fail_col="$C_OK";  [ "${SP_SENT_FAILED:-0}" != 0 ] && fail_col="${C_BAD}${C_B}"
    # TWO LINES. As one it ran to ~140 characters against a pane about 100 wide and
    # truncated mid-word — which is how a dashboard ends up showing a stray "f".
    printf ' %sATTN%s   %swaiting on you%s %s%s%s   %sthreads awaiting my reply%s %s%s%s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "$C_B" "${SP_WAITING:-?}" "$C_RST" \
        "$C_DIM" "$C_RST" "$unans_col" "${SP_UNANSWERED:-?}" "$C_RST"
    # WHERE THIS SITS IN THE LIFECYCLE, because it was read as the verification BEFORE a
    # bead closes and it is the opposite end: gate.sh is the trial a branch passes before
    # it may merge, CHECK 6 is the merge, and the Sending is what happens AFTER — laying
    # the landed branch and its worktree to rest so they do not come back.
    #
    # NAME THE NOUN. "6 unsent" never said unsent WHAT — branches, aeons, stories, epics,
    # PRs were all plausible readings of the same number. It is BRANCHES, each with a
    # worktree, and saying so costs one word.
    #
    # THE METAPHOR STAYS; IT CARRIES ITS OWN GLOSS. (the operator, verbatim: "i like insider
    # vocab from FFX i just don't know what it means".) A Sending is the rite that lays the
    # dead to rest so they do not become fiends — which is exactly what reaping a landed
    # branch does, and exactly what happens when it fails: an unsent branch came back and
    # re-landed itself every two minutes for twenty minutes. So the words stay and each one
    # is followed by what it means in this system.
    #
    # What changed is the FIGURES. "reaped 19 · held 24 · awaiting land 13" was 24h of the
    # reaper's history; none of it said whether anything needs attention. These say what is
    # on the shelf right now.
    local age_col="$C_DIM"
    [ "${SP_UNSENT_OLDEST_H:-0}" = "?" ] || { [ "${SP_UNSENT_OLDEST_H:-0}" -ge 24 ] 2>/dev/null && age_col="$C_WARN"; }
    # PARKED ON PURPOSE, and therefore invisible everywhere else: not in progress, not
    # ready, nothing moving. A count and the oldest one is enough to notice a run that
    # never came back.
    if [ "${SP_AWAITING_N:-0}" != 0 ] && [ "${SP_AWAITING_N:-0}" != "?" ]; then
        local ci_col="$C_DIM"
        case "${SP_AWAITING_AGE:-}" in *h|*d) ci_col="$C_WARN" ;; esac
        printf ' %sCI%s     %s%s bead(s) awaiting CI%s   %soldest%s %s %s(%s)%s\n' \
            "$C_DIM" "$C_RST" "$C_B" "${SP_AWAITING_N}" "$C_RST" \
            "$C_DIM" "$C_RST" "${SP_AWAITING_OLDEST:-?}" \
            "$ci_col" "${SP_AWAITING_AGE:-?}" "$C_RST"
    fi

    printf ' %sSEND%s   %s%s branches unsent%s · %s%s awaiting rites%s · %s%s fiends%s %s(unsent work that came back)%s · %soldest %sh%s\n' \
        "$C_DIM" "$C_RST" "$C_B" "${SP_UNSENT:-?}" "$C_RST" \
        "$( [ "${SP_BRANCH_DONE:-0}" = 0 ] && printf '%s' "$C_DIM" || printf '%s' "$C_WARN")" "${SP_BRANCH_DONE:-?}" "$C_RST" \
        "$fail_col" "${SP_SENT_FAILED:-?}" "$C_RST" "$C_DIM" "$C_RST" \
        "$age_col" "${SP_UNSENT_OLDEST_H:-?}" "$C_RST"

    # 24H — throughput, and whether closing meant landing.
    # TWO POPULATIONS, TWO LINES. "closed 27 ... landed 21 unlanded 0" read as six beads
    # closed without landing. It was not: 27 is every bead closed in 24h INCLUDING ones
    # closed by hand with no branch to land, while landed/unlanded count only beads an
    # aeon worked, all-time. Same row, different denominators — the most misleading shape
    # a dashboard can take, since both numbers were correct.
    printf ' %sBEADS%s  %sflow  24h:%s closed %s %s(%s)%s  %sopened%s %s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_CLOSED_24H:-?}" "$C_DIM" "${SP_CLOSED_KINDS:--}" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_OPENED_24H:-?}"
    printf '        %sof the %s an aeon worked:%s %s landed · %s%s never landed%s %s(closed, but no commit names them)%s\n' \
        "$C_DIM" "${SP_CLOSED:-?}" "$C_RST" "${SP_LANDED:-?}" \
        "$( [ "${SP_UNLANDED:-0}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_BAD$C_B")" "${SP_UNLANDED:-?}" "$C_RST" \
        "$C_DIM" "$C_RST"

    # GRAPH — the beads themselves, kept apart from sessions and asks so the counts cannot
    # be read as the same kind of thing.
    printf '        %sstock now:%s open %s  %sready%s %s  %sin progress%s %s   %spoison%s %s%s%s  %sstranded%s %s\n' \
        "$C_DIM" "$C_RST" "${SP_OPEN:-?}" \
        "$C_DIM" "$C_RST" "${SP_READY:-?}" \
        "$C_DIM" "$C_RST" "${SP_INPROG:-?}" \
        "$C_DIM" "$C_RST" "$( [ "${SP_POISON:-0}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_BAD$C_B")" "${SP_POISON:-?}" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_STRANDS:-?}"

    # HEALTH — the harness watching itself, plus the machine it runs on.
    local judge="${SP_SINCE_JUDGEMENT:-?}" judge_str
    case "$judge" in
        '?')      judge_str="${C_BAD}${C_B}?${C_RST}" ;;
        'n/a')    judge_str="${C_DIM}not needed${C_RST}" ;;
        'NEVER'*) judge_str="${C_BAD}${C_B}${judge}${C_RST}" ;;
        *)        judge_str="${C_DIM}${judge} passes ago${C_RST}" ;;
    esac
    printf ' %sSELF%s   %sactions it had to repeat%s %s%s%s %s(%s in %s passes)%s  %sstalled passes%s %s%s%s  %saeons that died at birth%s %s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "$( [ "${SP_FALSE_ACTS:-?}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_WARN" )" \
        "${SP_FALSE_ACTS:-?}" "$C_RST" \
        "$C_DIM" "${SP_FALSE_PER_PASS:-?}" "${SP_PASSES:-?}" "$C_RST" \
        "$C_DIM" "$C_RST" "$( [ "${SP_STARVED_PASSES:-0}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_WARN")" "${SP_STARVED_PASSES:-?}" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_AEON_STILLBORN:-?}"
    printf ' %sBOX%s    %sdisk%s / %s  %sworkspaces%s %s  %scpu%s %s%% idle  %sload%s %s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "$(num "${SP_DISK_ROOT_PCT:-?}" 85 '%')" \
        "$C_DIM" "$C_RST" "$(num "${SP_DISK_WS_PCT:-?}" 85 '%')" \
        "$C_DIM" "$C_RST" "${SP_CPU_IDLE:-?}" \
        "$C_DIM" "$C_RST" "${SP_LOAD1:-?}"
    printf ' %sGOV%s    %s%s mode%s  %s\n' \
        "$C_DIM" "$C_RST" "$C_B" "${SP_GOVERNOR_MODE:-?}" "$C_RST" \
        "$( [ "${SP_BUDGET:-0}" = 0 ] \
             && printf '%swould withhold — %s%s' "$C_WARN" "${SP_BUDGET_REASON:-no headroom}" "$C_RST" \
             || printf '%s%s aeon(s) affordable%s' "$C_OK" "${SP_BUDGET:-?}" "$C_RST")"
}


# The predecessor section was removed when that harness was retired: a dashboard
# that keeps reporting a system nobody runs trains the eye to skip the pane. Its figures —
# mayor/deacon dots, merge-queue depth, parked beads, orphans, dispatch mode — described
# agents, a scheduler and a queue that no longer exist. Disk stayed, in spira_lines.
frame() { spira_lines; }

# render <rows> — the frame, cut to what the pane can actually show.
#
# The pane is five rows. Seven lines were being written into it, and the terminal scrolled:
# the top two vanished silently on every repaint, which is how the disk line and the ready
# total came to be invisible for weeks without anyone noticing they had been specified.
# Lines are emitted in priority order, the tail is dropped, and the DROP COUNT IS MARKED ON
# THE HEADER — a dashboard that hides content without saying so is the failure it exists to
# prevent. 0 rows means no limit, which is what `once` uses.
render() {
    local rows="${1:-0}" n drop
    local -a all
    mapfile -t all < <(frame)
    n=${#all[@]}
    if [ "$rows" -gt 0 ] && [ "$n" -gt "$rows" ]; then
        drop=$(( n - rows ))
        all[0]="${all[0]}  ${C_DIM}▾${drop}${C_RST}"
        all=("${all[@]:0:$rows}")
    fi
    printf '%s\n' "${all[@]}"
}

# --- flicker-free painting -------------------------------------------------------
# `\e[2J` (clear screen) then redraw is what makes a pane flicker: for one frame the
# terminal shows nothing, and the eye catches it every tick. Four fixes together:
#
#   1. NEVER clear. Home the cursor, then erase each line as it is rewritten (\e[K)
#      and erase whatever is left below (\e[J). The old frame is overwritten in place,
#      so no blank frame ever exists.
#   2. NO TRAILING NEWLINE on the last line. A newline written in the bottom row scrolls
#      the pane by one, which is the other half of why the top lines were disappearing.
#   3. SKIP UNCHANGED FRAMES. Most ticks change nothing; comparing to the previous
#      frame turns those into zero writes. This is why the header shows the COLLECTION
#      time rather than the wall clock — a ticking second hand would defeat it.
#   4. SYNCHRONIZED OUTPUT (DECSET 2026). tmux buffers the whole update and presents it
#      atomically, so a repaint cannot be shown half-finished. Harmless where absent.
#   5. AUTOWRAP OFF (DECAWM). A line wider than the pane must be cut by the terminal, not
#      folded onto a second row: a folded line makes one printed line occupy two rows, and
#      the height arithmetic in `render` is then wrong by however many lines are long —
#      which is the scrolling bug arriving by a second route. Restored on exit.
#
# The cursor is hidden too — a block cursor parked in a dashboard is its own distraction.
# term_rows -> the pane's real height.
#
# `stty size` first, because it asks the TTY by ioctl and needs no terminfo: `tput lines`
# prints nothing and fails when $TERM is unset, which happens to anything launched
# detached — and its failure would fall through to "no limit", which is fail-OPEN on
# exactly the defect this function exists to close. When the height cannot be established
# at all, assume the five rows the cockpit actually gives this pane: showing too few lines
# is visible and recoverable, while showing too many scrolls the top ones away in silence.
term_rows() {
    local r
    r="$(stty size 2>/dev/null | awk '{print $1}')"
    [ -n "${r:-}" ] || r="$(tput lines 2>/dev/null)"
    [ -n "${r:-}" ] || r="${LINES:-}"
    [ -n "${r:-}" ] && [ "$r" -gt 0 ] 2>/dev/null || r=5
    printf '%s' "$r"
}

LAST_FRAME=""
paint() {
    local rows buf i n
    # Re-read every tick rather than trapping SIGWINCH: it is one fork every two seconds,
    # and a resize the frame does not notice re-creates the scrolling bug silently.
    rows="$(term_rows)"
    buf="$(render "$rows")"
    [ "$buf" = "$LAST_FRAME" ] && return
    LAST_FRAME="$buf"
    local -a lines
    mapfile -t lines <<< "$buf"
    n=${#lines[@]}
    {
        printf '\e[?2026h\e[H'
        for (( i = 0; i < n; i++ )); do
            printf '%s\e[K' "${lines[i]}"
            [ $(( i + 1 )) -lt "$n" ] && printf '\n'
        done
        printf '\e[J\e[?2026l'
    } 2>/dev/null
}
cleanup() { printf '\e[?25h\e[?7h\e[?2026l\n' 2>/dev/null; exit 0; }
trap cleanup INT TERM HUP EXIT

case "${1:-loop}" in
once) render 0 ;;
loop) printf '\e[?25l\e[?7l' 2>/dev/null; while :; do paint; sleep 2; done ;;
*) echo "usage: health.sh [once|loop]" >&2; exit 1 ;;
esac
