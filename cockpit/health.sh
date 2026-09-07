#!/usr/bin/env bash
#
# health.sh — the cockpit's right-hand column: the Spira ops dashboard.
#
#   health.sh             repaint every 2s forever (pane mode)
#   health.sh once        paint one full frame and exit
#   health.sh once <rows> [cols]
#                         paint one frame sized for a pane <rows> tall and <cols> wide, and
#                         exit — the seam the test suite drives the sizing through
#
# Reads the snapshots written by `spira/cockpit.sh` under `spira-cockpit.service`, all of them
# under $SPIRA_RUN. NEVER calls `bd` or `git` itself: the expensive sources cost seconds a pass
# and a pane that shelled out would freeze on every repaint.
#
# WHY ONLY SPIRA
# --------------
# This pane used to instrument only the predecessor harness, while the harness actually running
# the operator's work — sentinel, aeons, the landing gate — had no display at all. A dashboard
# whose subject is a decommissioned system reports on the past, and worse, trains the eye to
# skip the pane.
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
# A `?` means the probe FAILED. It never renders as 0 — a panel that reports a broken check
# as "all clear" displaces the suspicion that would have prompted a look.
#
# THE FRAME IS SIZED TO THE PANE, NOT THE OTHER WAY AROUND
# --------------------------------------------------------
# The pane is a full-height column (layout.sh splits it off the whole window), and how many
# rows that is depends on the operator's terminal. So the four sections that have more to
# say than fits — NOW, NEXT, RECENT, CI — each report every row they COULD show, and the
# renderer hands out the rows that are actually there.
#
# THE SHARE IS ROUND-ROBIN, ONE ROW AT A TIME, and that is the point. Filling each section
# in turn until the space runs out means a busy NOW pushes CI off the bottom, and CI is
# where a run that never came back is found — the section most likely to be starved is the
# one nothing else reports. Every section gets its first row before any gets its second.
#
# Sizing reads the pane's height on every repaint rather than trapping SIGWINCH, so a
# resize reflows on the next tick instead of waiting for fresh data.
#
# A SECTION WITH NOTHING TO SHOW STILL SAYS SO, and says which nothing it means: "no aeon
# working" is the harness idle, "?" is the snapshot unread. Rendering the second as the
# first is the all-clear a broken check must never be able to produce
# (law-absence-needs-a-positive-control).
#
# Lines are still emitted in priority order and the frame is still cut to the terminal's
# real height, with the count of dropped lines marked on the header: seven lines were once
# written into five and the top two scrolled away unannounced, and a dashboard that hides
# its own content is the failure mode it exists to prevent.
set -uo pipefail

# Every path comes from the harness's one configuration surface. It is two directories
# away because the cockpit ships beside the harness, not inside it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../spira" && pwd -P)/conf.sh"

# THE FRAME IS MEASURED IN CHARACTERS, and a good half of them are multibyte — `·`, `—`,
# `↳`, `▾`, `●`. Under systemd, under a gate's `env -i`, and in any detached pane, LANG is
# unset and bash falls back to the C locale, where `${t:0:n}` counts BYTES: a title cut at a
# byte boundary ends in a broken character, and every width calculation is wrong by however
# many multibyte characters the line held. Ask for UTF-8 rather than inherit whatever
# launched the pane.
export LC_ALL="${LC_ALL:-C.UTF-8}"

# EVERY PATH HERE COMES FROM $SPIRA_RUN, NONE OF THEM DERIVED. cockpit.sh and governor.sh
# write under $SPIRA_RUN, and SPIRA_RUN is configurable — a reader that recomputes the path
# from $SPIRA_REPO renders `?` for every row it feeds the moment an operator moves it, and a
# panel that reports a broken read as "nothing happening" displaces the suspicion that would
# have prompted a look. That is not hypothetical: the governor row read a derived
# `$SPIRA_REPO/.runtime/spira/budget.env` and rendered `? mode  would withhold — no headroom`
# against a budget file that was present and current, on an installation where the two differ.
SPIRA_SNAP="$SPIRA_RUN/cockpit.env"
BUDGET_SNAP="$SPIRA_RUN/budget.env"
# SPIRA'S OWN SERIES, beside its own snapshot: a pane drawing trends from a file nothing
# appends to draws a flat line, and a flat line reads as calm rather than absent.
HIST="$SPIRA_RUN/cockpit-history.csv"

C_RST=$'\e[0m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'
C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_ACC=$'\e[36m'

# Sparkline over the last N values of a named column of the time series.
#
# A NON-NUMERIC POINT IS DROPPED, NEVER PLOTTED AS ZERO. The series records `?` for a probe
# that failed, and drawing that as a trough turns a broken instrument into the picture of a
# quiet hour — which is the one thing a dashboard must never invent. With nothing numeric
# left it draws nothing at all, so the absence is visible instead of imagined.
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
    except Exception: pass
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

# fit <text> <cols> -> the text cut to <cols> characters, and MARKED when it was cut.
#
# THE PANE IS A THIRD OF THE WINDOW WIDE NOW, not half, so a line that fitted comfortably in
# the old quadrant runs off this column. Autowrap is off — a long line has to be cut rather
# than folded, or the height arithmetic is wrong by however many lines are long — and the
# terminal's own cut is silent, which is the same defect as dropping rows without saying so.
# Cutting here instead, on the plain text BEFORE any colour is added, keeps the escape
# sequences out of the arithmetic and leaves an ellipsis where the eye can see it.
#
# IT ASSIGNS TO $FIT RATHER THAN PRINTING, because `$(fit ...)` is a fork and this is called
# once per variable-length field — about fifty times a frame, on a loop that re-renders every
# two seconds to decide whether anything changed. A convenience pane must never be able to
# cost the box real work (law-fence-loops-on-shared-hardware).
FIT=""
fit() {                  # fit <text> <cols> -> sets $FIT
    local t="$1" n="$2"
    if [ "$n" -ge 2 ] 2>/dev/null && [ "${#t}" -gt "$n" ]; then FIT="${t:0:$((n-1))}…"; else FIT="$t"; fi
}

# tok <n> -> "494M" / "126k". A `?` or `-` passes through untouched: a probe that failed and a
# probe that measured nothing are different facts and neither is a number.
tok() {
    local v="${1:-?}"
    case "$v" in ''|*[!0-9]*) printf '%s' "${v:-?}"; return ;; esac
    if   [ "$v" -ge 1000000 ]; then printf '%sM' $(( v / 1000000 ))
    elif [ "$v" -ge 1000 ];    then printf '%sk' $(( v / 1000 ))
    else                            printf '%s' "$v"; fi
}

# pct <part> <whole> -> "74%", or `?` when either side is not a number or the whole is zero.
pct() {
    case "${1:-}${2:-}" in *[!0-9]*) printf '?'; return ;; esac
    [ "${2:-0}" -gt 0 ] 2>/dev/null || { printf '?'; return; }
    printf '%s%%' $(( $1 * 100 / $2 ))
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
# SPIRA — the sections, each answering one question, each sized by the caller.
#
# Every section function emits EVERY row it could show, most important first. None of them
# knows how tall the pane is; `frame` decides that, so no section can eat the space of the
# one below it merely by being written first.
# ======================================================================================

# How many rows one elastic section may ever occupy. Past this a section stops being a
# glance and becomes a list, which is what `bd ready` is for. The collector caps its own
# output to match — there is no point emitting rows nothing can show.
MAX_SECTION_ROWS=20

# Read both snapshots into the shell. Called once per frame; every section reads what it
# left behind.
load_snapshot() {
    set +u
    [ -f "$SPIRA_SNAP" ] && . "$SPIRA_SNAP" 2>/dev/null
    [ -f "$BUDGET_SNAP" ] && . "$BUDGET_SNAP" 2>/dev/null
    set -u
}

# A LABELLED SECTION PER QUESTION. The old single line read
# "open 25 ready 17 working 1 aeons 1 poison 1 asks 0 fiends 0" — beads, sessions and
# asks in one undifferentiated row, so nothing could be read at a glance and the counts
# looked like they measured the same kind of thing (the operator, verbatim: "i can't tell
# at a glance what's actually happening"). Each line now answers one question and says
# which one.
# A STOPPED WORLD IS THE FIRST THING ON THE PANE, because every other figure below it is
# then a description of a system that is not running — zero aeons, zero landings and a still
# queue all render exactly as they do on a quiet, healthy afternoon. The operator, watching
# the pane through a halt: "if spira is stopped, i want that to be clear from the pane."
#
# READ FROM SYSTEMD AND THE STAMP DIRECTLY, NOT THROUGH THE SNAPSHOT. Every other row here
# comes from cockpit.env because its probes are too slow to run per repaint; these two are a
# file test and one `systemctl is-active`, and routing them through the collector would mean
# a DEAD collector renders a halted world as a running one — the failure this banner exists
# to prevent, arriving by its own back door.
#
# EITHER CONDITION IS ENOUGH. world.sh writes the stamp, but a timer stopped by hand leaves
# no stamp at all, and that world is just as stopped.
halt_banner() {
    local stamp="$SPIRA_RUN/world.halted" why="" since="" tstate
    # THROUGH THE SAME SEAM sentinel.sh ALREADY USES. A bare `systemctl` here reads the real
    # user session, so this function's output depends on whether the box's own Spira happens
    # to be running — and test-tokens.sh, which renders this pane, therefore failed two
    # assertions for the whole of the day Spira was deliberately halted to repair the gate.
    # The suite was testing the box (law-gates-run-in-a-clean-environment), and it did it in
    # the one situation where the gate most needed to be trustworthy: the gate could not go
    # green while the world was stopped, and the world was stopped in order to fix the gate.
    tstate="$("${SPIRA_SYSTEMCTL:-systemctl}" --user is-active spira-sentinel.timer 2>/dev/null)"
    if [ -f "$stamp" ]; then
        since="$(head -1 "$stamp" 2>/dev/null)"
        why="$(sed -n '''2s/^why: //p''' "$stamp" 2>/dev/null)"
    elif [ "$tstate" = active ]; then
        return 0
    fi
    printf '%s%s ■ SPIRA STOPPED %s%s no aeons are summoned; nothing lands%s\n' \
        "$C_B" "$C_BAD" "$C_RST" "$C_DIM" "$C_RST"
    [ -n "$since" ] && printf '  %ssince%s %s\n' "$C_DIM" "$C_RST" "$since"
    [ -n "$why" ]   && printf '  %swhy%s   %s\n' "$C_DIM" "$C_RST" "${why:0:60}"
    [ "$tstate" != active ] && [ -z "$since" ] \
        && printf '  %ssentinel.timer is %s and no world.sh halt was recorded%s\n' "$C_DIM" "$tstate" "$C_RST"
    printf '  %sstart it:%s spira/world.sh start\n' "$C_DIM" "$C_RST"
}

header_line() {
    local age="?" stale=""
    [ -n "${SP_AT:-}" ] && age=$(( $(date +%s) - SP_AT ))
    [ "$age" != "?" ] && [ "$age" -gt 180 ] && stale="  ${C_BAD}STALE ${age}s${C_RST}"
    halt_banner
    printf '%s%sSPIRA%s %s   %ssentinel%s %s %ss  %sops%s %s %ss%s\n' \
        "$C_B" "$C_ACC" "$C_RST" "$(date +%H:%M)" \
        "$C_DIM" "$C_RST" "$(dot "${SP_SENTINEL_TIMER:-0}")" "${SP_SENTINEL_AGE:-?}" \
        "$C_DIM" "$C_RST" "$(dot "${SP_OPS_TIMER:-0}")" "${SP_OPS_AGE:-?}" "$stale"
}

# TOKENS — what the account is spending, and which half of the system is spending it.
#
# DIRECTLY UNDER THE HEADER AND OUTSIDE THE SHARE, because it is the constraint on everything
# below it: when the account is out of capacity no aeon can be summoned and no bead can move,
# so every other figure on this pane freezes for a reason nothing else here reports. It is the
# leading indicator of the GOV row's "ACCOUNT OUT OF CAPACITY", which only says so once it is
# too late to act. Fixed height by the same rule as the standing figures — each row is one
# number that is always worth its row — so the elastic sections never elide it.
#
# THE SPLIT IS THE WHOLE POINT, and it gets a row each. A single total would not have answered
# the question this was built for, and the answer was not the obvious one: the interactive
# session is about three quarters of the window, so optimising the harness first would have
# been optimising the smaller half. One half per row rather than both on one, because this is
# a column about a third of the window wide and the tail of a long line is silently cut — the
# tail here being the session, which is the larger half and the finding.
#
# CONTEXT PER TURN, NOT OUTPUT. What a rate limit meters is everything a request carried, and
# the whole context is re-read on EVERY turn: cache reads outweigh output here by roughly 175
# to 1. The lever is context size multiplied by turns, so both are on the row.
tokens_section() {
    printf ' %sTOKENS/%sh%s  %s%s%s billed  %s%s%s\n' \
        "$C_DIM" "${SP_TOK_WINDOW_H:-?}" "$C_RST" \
        "$C_B" "$(tok "${SP_TOK_WIN:-?}")" "$C_RST" \
        "$C_ACC" "$(spark tok_win $(( COLS > 46 ? (COLS - 34 > 24 ? 24 : COLS - 34) : 0 )))" "$C_RST"
    local half
    for half in AEON:aeons SESS:session; do
        eval "local w=\${SP_TOK_${half%%:*}_WIN:-?} t=\${SP_TOK_${half%%:*}_TURNS:-?} c=\${SP_TOK_${half%%:*}_CTX:-?}"
        # Fitted like every other variable-length field: on a narrow column the tail is what
        # the terminal would cut, and here the tail is the context-per-turn — half of the
        # product this row exists to show.
        fit "${t}t · $(tok "$c") ctx/turn" $(( COLS - 22 ))
        printf '        %s%-8s%s %-4s %s%s%s\n' \
            "$C_DIM" "${half#*:}" "$C_RST" "$(pct "$w" "${SP_TOK_WIN:-?}")" \
            "$C_DIM" "$FIT" "$C_RST"
    done

    # CTX — the session in front of the operator, and how close it is to the edge.
    #
    # A TOTAL SAYS WHAT WAS SPENT; ONLY THE PROXIMITY SAYS WHETHER TO ACT NOW, and acting is
    # the thing the operator can actually do about any of this. Headroom is quoted to the NEXT
    # threshold rather than to the ceiling — "874k to the limit" is true and useless when what
    # happens next is crossing into the band where clearing pays. Turns-to-threshold is the
    # same fact in the unit the decision is made in, and it appears only while the session is
    # growing: a flat session is approaching nothing, and a fabricated rate would be a number
    # where there is no measurement.
    # THREE STATES, AND THEY MUST NOT COLLAPSE INTO TWO. `-` is "no session is running", which
    # is true and useful; an unset or `?` key is a probe that did not run, which is a fault and
    # says so. Reading the second as the first would report a broken meter as a quiet keyboard
    # — an all-clear that displaces the suspicion that would have prompted a look
    # (law-absence-needs-a-positive-control).
    case "${SP_CTX_NOW:-?}" in
        '-') printf ' %sCTX%s    %sno session at the keyboard%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
             return ;;
        ''|'?'|*[!0-9]*) unread_row CTX "cannot read the live session"; return ;;
    esac
    local ctx_col="$C_OK"
    case "${SP_CTX_NEXT:-}" in
        high)             ctx_col="$C_WARN" ;;
        limit|over|'?')   ctx_col="$C_BAD$C_B" ;;
    esac
    local rest=""
    [ "${SP_CTX_GROWTH:-0}" -gt 0 ] 2>/dev/null && rest=" · +$(tok "$SP_CTX_GROWTH")/turn"
    case "${SP_CTX_NEXT:-}" in
        warn|high|limit)
            rest="$rest · $(tok "${SP_CTX_HEADROOM:-?}") to ${SP_CTX_NEXT}"
            [ "${SP_CTX_TURNS_LEFT:--}" = "-" ] || rest="$rest (~${SP_CTX_TURNS_LEFT}t)" ;;
        over) rest="$rest · past every threshold" ;;
    esac
    fit "$rest" $(( COLS - 18 ))
    printf ' %sCTX%s    %s%s%s %s/%st%s%s\n' \
        "$C_DIM" "$C_RST" "$ctx_col" "$(tok "${SP_CTX_NOW:-?}")" "$C_RST" \
        "$C_DIM" "${SP_CTX_TURNS:-?}" "$FIT" "$C_RST"

    # The archivist is what makes a full context recoverable rather than merely lost, so its
    # state belongs beside the number that says the context is full — and so does the age of
    # the transcript this was read from. The collector has no status-line hook and takes the
    # newest transcript on disk; with nobody at the keyboard that is a session which ended
    # hours ago, and presenting a dead session's context as live is the confident wrong number
    # this pane exists to avoid. The row is emitted only when one of them has something to
    # say, because a row that always reads the same becomes wallpaper.
    local note=""
    case "${SP_CTX_ARCHIVIST:-}" in
        none)               [ "${SP_CTX_NEXT:-}" = warn ] || note="${C_DIM}· not archived${C_RST}" ;;
        # HOW MANY ITEMS, not merely that it finished. "Safe to clear" alone cannot distinguish
        # a session with nothing left to save from one whose fourteen loose ends are now beads,
        # and those are the two readings the operator is actually deciding between.
        safe)               f=""
                            case "${SP_CTX_ARCHIVIST_FILED:-}" in
                                ''|'-'|'?'|*[!0-9]*) ;;
                                *) f=" ${C_DIM}(${SP_CTX_ARCHIVIST_FILED} filed)${C_RST}" ;;
                            esac
                            if [ "${SP_CTX_ARCHIVIST_BEHIND:-0}" -le 2 ] 2>/dev/null
                            then note="${C_OK}✓ safe to clear${C_RST}$f"
                            else note="${C_WARN}✓ safe as of ${SP_CTX_ARCHIVIST_BEHIND}t ago${C_RST}$f"; fi ;;
        sweeping|archiving) note="${C_ACC}⟳ ${SP_CTX_ARCHIVIST}${C_RST}" ;;
        failed)             note="${C_BAD}! archive failed${C_RST}" ;;
        ''|'-')             ;;
        *)                  note="${C_BAD}${C_B}archivist ?${C_RST}" ;;
    esac
    case "${SP_CTX_AGE:-}" in
        ''|'-'|'?') ;;
        *) [ "${SP_CTX_AGE}" -ge 300 ] 2>/dev/null \
               && note="${note:+$note  }${C_DIM}idle $(( SP_CTX_AGE / 60 ))m${C_RST}" ;;
    esac
    [ -n "$note" ] && printf '        %s\n' "$note"
    return 0
}

# `<label> ? <why>` — the shape every section uses when its input could not be read. It is
# deliberately not the shape of "nothing to report": a broken read that renders as an
# all-clear displaces the suspicion that would have prompted a look, and these two states
# are one unset variable apart (law-absence-needs-a-positive-control).
unread_row() {   # unread_row <label> <what could not be read>
    printf ' %s%-6s%s %s%s?%s %s%s%s\n' \
        "$C_DIM" "$1" "$C_RST" "$C_BAD" "$C_B" "$C_RST" "$C_DIM" "$2" "$C_RST"
}

# NOW — who is working, on what, and what they last actually did. An aeon has a name
# so two of them are distinguishable; the action comes from its stream-json trace.
# Three rows per aeon, so this is the section that grows fastest and the one the
# round-robin share exists to keep in its lane.
now_section() {
    if [ -z "${SP_AEON_N:-}" ] || [ "${SP_AEON_N:-}" = "?" ]; then
        unread_row NOW "cannot read the aeon roster"
        return
    fi
    if [ "${SP_AEON_N}" -eq 0 ] 2>/dev/null; then
        printf ' %sNOW%s    %sno aeon working%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
        return
    fi
    local i=0
    while [ "$i" -lt "${SP_AEON_N}" ]; do
        eval "local nm=\${SP_AEON${i}_NAME:-?} fy=\${SP_AEON${i}_FAYTH:-?}"
        eval "local bd=\${SP_AEON${i}_BEAD:-?} mn=\${SP_AEON${i}_MIN:-?} ac=\${SP_AEON${i}_ACT:-}"
        eval "local ti=\${SP_AEON${i}_TITLE:-} pr=\${SP_AEON${i}_PRI:-?}"
        # WHO, then WHAT, then the live action — one question per line. Crammed onto
        # one row the name, the bead, the elapsed time and a shell command ran past the
        # pane width and truncated mid-word.
        printf ' %s%s%s    %s%s%s %sthe %s · %sm%s\n' \
            "$C_DIM" "$([ "$i" = 0 ] && printf 'NOW' || printf '   ')" "$C_RST" \
            "$C_OK$C_B" "$nm" "$C_RST" "$C_DIM" "$fy" "$mn" "$C_RST"
        # Same shape as a NEXT row, deliberately: id in the accent colour, title dim,
        # so a bead being worked and a bead about to be worked read as the same kind of
        # thing in the same place on the line.
        # FOURTEEN COLUMNS OF ID, not twenty-two. Every row under a label starts at the
        # label column, which is eight; a wider id field on top of that was spending more
        # of a third-width pane on alignment than on the title the alignment exists to line
        # up. The budget is computed rather than constant, as in `next_row`.
        # P<n> FIRST, exactly as next_row and the RECENT rows lead — the three sections
        # describe the same beads at three stages of one lifecycle, and until this was here
        # they could not be compared down the column.
        fit "${ti:-?}" $(( COLS - 12 - (${#bd} > 14 ? ${#bd} : 14) ))
        printf '        %sP%s%s %s%-14s%s %s%s%s\n' \
            "$(pri_colour "P$pr")" "$pr" "$C_RST" "$C_ACC" "$bd" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
        if [ -n "$ac" ]; then
            fit "$ac" $(( COLS - 10 ))
            printf '        %s↳ %s%s\n' "$C_DIM" "$FIT" "$C_RST"
        fi
        i=$((i+1))
    done
}

# "P0 sp-id Title..." -> aligned id + dim title, matching NOW.
#
# THE TITLE BUDGET IS COMPUTED, NOT CONSTANT. A `%-14s` field occupies fourteen columns, or
# the id's own length when it is longer — printf pads a short field and never truncates a
# long one, and truncating an id is not an option because half an id is not an id. So the
# prefix width varies per row and the space left for the title varies with it. The ternary
# is written inline rather than as a helper for the same no-forks reason as `fit`.
# ONE VOCABULARY OF COLOUR FOR THE WHOLE COLUMN, because NOW, NEXT and RECENT show the same
# beads at three stages and a reader scans down, not across. P0 and a reopen must look alike
# wherever they appear, or the colour is decoration rather than information.
pri_colour() {          # pri_colour P0 -> the escape for that priority
    case "$1" in
        P0) printf '%s' "$C_BAD$C_B" ;;
        P1) printf '%s' "$C_WARN" ;;
        *)  printf '%s' "$C_DIM" ;;
    esac
}

# A LIFECYCLE VERB IS GREEN WHEN WORK ADVANCED, RED WHEN IT WENT BACKWARDS, AMBER WHEN IT
# ENDED WITHOUT EITHER. The middle case is the one worth seeing: an aeon whose turn ended with
# its bead still in progress is neither a success nor a failure, and it is what repeats.
verb_colour() {
    case "$1" in
        landed|finished|announced)      printf '%s' "$C_OK" ;;
        reopened|poisoned|slain|reaped) printf '%s' "$C_BAD" ;;
        in_progress|ended|reclaimed)    printf '%s' "$C_WARN" ;;
        claimed)                        printf '%s' "$C_ACC" ;;
        *)                              printf '%s' "$C_DIM" ;;
    esac
}

next_row() {
    local raw="$1" pri id rest
    pri="${raw%% *}"; rest="${raw#* }"; id="${rest%% *}"; rest="${rest#* }"
    fit "$rest" $(( COLS - 10 - ${#pri} - (${#id} > 14 ? ${#id} : 14) ))
    printf '        %s%s%s %s%-14s%s %s%s%s\n' \
        "$(pri_colour "$pri")" "$pri" "$C_RST" "$C_ACC" "$id" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
}

# RECENT rows arrive as `<age> <verb> <bead> <title...>`. Split rather than print flat: the
# id and the verb are what a reader is scanning for, and dimming the whole line hid both.
# A row that does not split is printed as it came — a formatter must never drop content it
# failed to parse.
recent_row() {          # recent_row "<age> <verb> <bead> <title>" <indent-cols>
    local raw="$1" pad="$2" age verb id rest
    # THE AGE IS TWO WORDS. The collector emits `%-7s` of a relative time — "2m ago", "18h
    # ago" — so splitting on the first space made the verb "ago" and the id "landed", and
    # every row rendered its colours one field to the left. Matched as a whole rather than
    # counted in spaces, because the padding width is the collector's to change.
    if [[ "$raw" =~ ^([0-9]+[smhd][[:space:]]+ago)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
        age="${BASH_REMATCH[1]}"; verb="${BASH_REMATCH[2]}"; id="${BASH_REMATCH[3]}"; rest="${BASH_REMATCH[4]}"
    else
        # UNPARSED IS PRINTED AS IT CAME. A formatter must never drop content it could not
        # split — the event is the load-bearing half and the colour is the ornament.
        printf '%s%s%s\n' "$C_DIM" "$raw" "$C_RST"; return
    fi
    fit "$rest" $(( COLS - pad - 10 - ${#verb} - (${#id} > 14 ? ${#id} : 14) ))
    printf '%s%-7s%s %s%s%s %s%-14s%s %s%s%s\n' \
        "$C_DIM" "$age" "$C_RST" \
        "$(verb_colour "$verb")" "$verb" "$C_RST" \
        "$C_ACC" "$id" "$C_RST" \
        "$C_DIM" "$FIT" "$C_RST"
}

# NEXT — the order the graph will actually be claimed in.
# CLAIM ORDER, not "the top of each priority". These are literally the next beads
# `bd ready --claim` would take, in that order. The count on the header is the WHOLE
# queue; the rows beneath it are as much of the head of that queue as the pane can hold.
next_section() {
    if [ -z "${SP_NEXT_N:-}" ] || [ "${SP_NEXT_N:-}" = "?" ]; then
        unread_row NEXT "cannot read the ready queue"
        return
    fi
    if [ "${SP_NEXT_N}" -eq 0 ] 2>/dev/null; then
        printf ' %sNEXT%s   %s0 ready%s %s— nothing to claim%s\n' \
            "$C_DIM" "$C_RST" "$C_B" "$C_RST" "$C_DIM" "$C_RST"
        return
    fi
    printf ' %sNEXT%s   %s%s ready%s %s— next to be claimed:%s\n' "$C_DIM" "$C_RST" \
        "$C_B" "${SP_NEXT_N}" "$C_RST" "$C_DIM" "$C_RST"
    local i=0 raw
    while [ "$i" -lt "$MAX_SECTION_ROWS" ]; do
        eval "raw=\${SP_NEXT$i:-}"
        [ -n "$raw" ] || break
        next_row "$raw"
        i=$((i+1))
    done
}

# RECENT — what the harness did, newest first. The label shares the first row with the
# newest event rather than sitting on a line of its own: a section allocated one row must
# spend it on content, not on its own name.
recent_section() {
    local ev i
    eval "ev=\${SP_EVENT0:-}"
    if [ -z "$ev" ]; then
        # An empty log and an unread snapshot look identical from here, so they are
        # distinguished by whether the file exists at all rather than left as one dash.
        if [ -f "$SPIRA_SNAP" ]; then
            printf ' %sRECENT%s %snothing in the window%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
        else
            unread_row RECENT "no snapshot to read"
        fi
        return
    fi
    printf ' %sRECENT%s %s' "$C_DIM" "$C_RST" "$(recent_row "$ev" 8)"
    i=1
    while [ "$i" -lt "$MAX_SECTION_ROWS" ]; do
        eval "ev=\${SP_EVENT$i:-}"
        [ -n "$ev" ] || break
        printf '        %s' "$(recent_row "$ev" 8)"
        i=$((i+1))
    done
}

# CI — work parked ON PURPOSE, and therefore invisible everywhere else on this pane: not
# in progress, not ready, nothing moving. The summary row answers "is anything parked";
# the rows beneath answer "which of them has been parked since yesterday", which is the
# question a run that never came back is found by.
#
# IT PRINTS EVEN AT ZERO. It used to print nothing at all when nothing was parked, so
# "nothing parked" and "this section is broken" were the same absence of pixels.
#
# TWO POPULATIONS, AND ONE LINE SAID BOTH. "Waiting on a run" is routine. "Parked with no
# run to wait for" is a bead that will wait forever: only a repository that lands through
# pull requests has a run at all, and the park label excludes a bead from every persona's
# predicate AND from the stranded-work report while it waits. So the second figure is a
# fault, is coloured like one, and is counted separately — a section reading "in CI" over a
# park nothing can end is the one description that stops the question being asked.
ci_section() {
    if [ -z "${SP_AWAITING_N:-}" ] || [ "${SP_AWAITING_N:-}" = "?" ]; then
        unread_row CI "cannot read what is parked on CI"
        return
    fi
    # BOTH COUNTS MUST BE ZERO for "nothing parked". Testing the first alone would report an
    # empty section over a queue of parks that no run will ever end, which is the failure this
    # section was split to make impossible.
    if [ "${SP_AWAITING_N}" -eq 0 ] 2>/dev/null && [ "${SP_AWAITING_STUCK:-0}" -eq 0 ] 2>/dev/null; then
        printf ' %sCI%s     %snothing parked on CI%s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
        return
    fi
    local ci_col="$C_DIM" stuck_txt=""
    case "${SP_AWAITING_AGE:-}" in *h|*d) ci_col="$C_WARN" ;; esac
    if [ "${SP_AWAITING_STUCK:-0}" != 0 ]; then
        stuck_txt="$(printf '   %s%s parked with no run to wait for%s %s(%s)%s' \
            "$C_WARN" "${SP_AWAITING_STUCK}" "$C_RST" \
            "$C_DIM" "${SP_AWAITING_STUCK_ID:-?}" "$C_RST")"
    fi
    printf ' %sCI%s     %s%s bead(s) waiting on a run%s   %soldest%s %s %s(%s)%s%s\n' \
        "$C_DIM" "$C_RST" "$C_B" "${SP_AWAITING_N}" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_AWAITING_OLDEST:-?}" \
        "$ci_col" "${SP_AWAITING_AGE:-?}" "$C_RST" "$stuck_txt"
    local i=0 row
    while [ "$i" -lt "$MAX_SECTION_ROWS" ]; do
        eval "row=\${SP_AWAITING$i:-}"
        [ -n "$row" ] || break
        fit "$row" $(( COLS - 8 ))
        printf '        %s%s%s\n' "$C_DIM" "$FIT" "$C_RST"
        i=$((i+1))
    done
}

# The standing figures. Fixed height by construction — each is one number that is always
# worth a row — so they are not part of the share and are never elided by it.
standing_lines() {
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
    # TWO LINES, FOR THE THIRD TIME AND THE SAME REASON. At ~98 characters this ran off a
    # column a third of a 214-wide window, and the terminal cuts rather than folds — so the
    # gloss that makes "fiends" mean anything was the part that disappeared. The counts stay
    # on the first row; the word that needs explaining takes the second.
    printf ' %sSEND%s   %s%s branches unsent%s · %s%s awaiting rites%s · %soldest %sh%s\n' \
        "$C_DIM" "$C_RST" "$C_B" "${SP_UNSENT:-?}" "$C_RST" \
        "$( [ "${SP_BRANCH_DONE:-0}" = 0 ] && printf '%s' "$C_DIM" || printf '%s' "$C_WARN")" "${SP_BRANCH_DONE:-?}" "$C_RST" \
        "$age_col" "${SP_UNSENT_OLDEST_H:-?}" "$C_RST"
    printf '        %s%s fiends%s %s— unsent work that came back%s\n' \
        "$fail_col" "${SP_SENT_FAILED:-?}" "$C_RST" "$C_DIM" "$C_RST"

    # 24H — throughput, and whether closing meant landing.
    # TWO POPULATIONS, TWO LINES. "closed 27 ... landed 21 unlanded 0" read as six beads
    # closed without landing. It was not: 27 is every bead closed in 24h INCLUDING ones
    # closed by hand with no branch to land, while landed/unlanded count only beads an
    # aeon worked, all-time. Same row, different denominators — the most misleading shape
    # a dashboard can take, since both numbers were correct.
    printf ' %sBEADS%s  %s24h%s  closed %s · %sopened%s %s\n' \
        "$C_DIM" "$C_RST" "$C_DIM" "$C_RST" "${SP_CLOSED_24H:-?}" \
        "$C_DIM" "$C_RST" "${SP_OPENED_24H:-?}"
    # The kinds are a breakdown of the number above, so they read as one when they sit under
    # it — and on their own row they can be four kinds rather than however many fit.
    fit "${SP_CLOSED_KINDS:--}" $(( COLS - 8 ))
    printf '        %s%s%s\n' "$C_DIM" "$FIT" "$C_RST"
    printf '        %sof the %s an aeon worked:%s %s landed · %s%s never landed%s\n' \
        "$C_DIM" "${SP_CLOSED:-?}" "$C_RST" "${SP_LANDED:-?}" \
        "$( [ "${SP_UNLANDED:-0}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_BAD$C_B")" "${SP_UNLANDED:-?}" "$C_RST"
    printf '        %snever landed = closed, but no commit names it%s\n' "$C_DIM" "$C_RST"

    # GRAPH — the beads themselves, kept apart from sessions and asks so the counts cannot
    # be read as the same kind of thing.
    printf '        %sopen%s %s · %sready%s %s · %sworking%s %s · %spoison%s %s%s%s · %sstranded%s %s\n' \
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
    printf ' %sSELF%s   %sactions it had to repeat%s %s%s%s %s(%s in %s passes)%s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "$( [ "${SP_FALSE_ACTS:-?}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_WARN" )" \
        "${SP_FALSE_ACTS:-?}" "$C_RST" \
        "$C_DIM" "${SP_FALSE_PER_PASS:-?}" "${SP_PASSES:-?}" "$C_RST"
    printf '        %sstalled passes%s %s%s%s · %sdied at birth%s %s\n' \
        "$C_DIM" "$C_RST" "$( [ "${SP_STARVED_PASSES:-0}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_WARN")" "${SP_STARVED_PASSES:-?}" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_AEON_STILLBORN:-?}"
    printf ' %sBOX%s    %sdisk%s / %s  %sworkspaces%s %s  %scpu%s %s%% idle  %sload%s %s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "$(num "${SP_DISK_ROOT_PCT:-?}" 85 '%')" \
        "$C_DIM" "$C_RST" "$(num "${SP_DISK_WS_PCT:-?}" 85 '%')" \
        "$C_DIM" "$C_RST" "${SP_CPU_IDLE:-?}" \
        "$C_DIM" "$C_RST" "${SP_LOAD1:-?}"
    # THE ACCOUNT OUTRANKS THE BOX on this line. The governor withholds over CPU, memory and
    # disk; a capacity pause is the API refusing to answer at all, and while one is in force
    # the governor's verdict is not the reason nothing is moving. Reported on the same row
    # rather than a line of its own because the GOV row already answers "why is the harness
    # withholding", and this is now the commonest answer.
    if [ "${SP_CAPACITY_PAUSED:-0}" = 1 ]; then
        printf ' %sGOV%s    %s%sACCOUNT OUT OF CAPACITY%s until %s%s%s %s(%sm)%s  %ssummoning paused%s\n' \
            "$C_DIM" "$C_RST" "$C_BAD" "$C_B" "$C_RST" \
            "$C_B" "${SP_CAPACITY_AT:-?}" "$C_RST" \
            "$C_DIM" "$(( ${SP_CAPACITY_LEFT:-0} / 60 ))" "$C_RST" \
            "$C_DIM" "$C_RST"
    else
        # HEADROOM, not the total: "3 affordable" beside three running said nothing. A
        # snapshot from before the governor reported headroom falls back to its budget.
        # The withholding reason already carries the average; only the affordable line adds it.
        printf ' %sGOV%s    %s%s mode%s  %s\n' \
            "$C_DIM" "$C_RST" "$C_B" "${SP_GOVERNOR_MODE:-?}" "$C_RST" \
            "$( [ "${SP_HEADROOM:-${SP_BUDGET:-0}}" = 0 ] \
                 && printf '%swould withhold — %s%s' "$C_WARN" "${SP_BUDGET_REASON:-no headroom}" "$C_RST" \
                 || printf '%s%s more aeon(s) affordable%s %s(idle avg %s%%)%s' "$C_OK" "${SP_HEADROOM:-${SP_BUDGET:-?}}" "$C_RST" \
                           "$C_DIM" "${SP_CPU_IDLE_AVG:-?}" "$C_RST")"
    fi
}

# share <rows> <fixed> <want...> -> one allocation per want, on its own line
#
# ROUND-ROBIN, ONE ROW AT A TIME. Filling each section to its cap in turn is the obvious
# implementation and the wrong one: NOW spends three rows per working aeon, so on a busy
# day it would take the whole column and CI — the section that reports a run parked since
# yesterday, and the only place that fact appears — would be the one to vanish.
#
# EVERY SECTION KEEPS ITS FIRST ROW even when there is no budget for it. The overflow then
# falls off the BOTTOM of the frame in `render`, which marks the count on the header; a
# section quietly allocated zero rows would leave no such mark.
share() {
    local rows="$1" fixed="$2"; shift 2
    local -a want=("$@") give=()
    local n=${#want[@]} i budget moved
    for (( i = 0; i < n; i++ )); do
        if [ "${want[i]}" -gt 0 ]; then give[i]=1; else give[i]=0; fi
    done
    # 0 rows means no limit, which is what `once` uses: give every section everything.
    [ "$rows" -le 0 ] && { printf '%s\n' "${want[@]}"; return; }
    budget=$(( rows - fixed ))
    for (( i = 0; i < n; i++ )); do budget=$(( budget - give[i] )); done
    moved=1
    while [ "$budget" -gt 0 ] && [ "$moved" = 1 ]; do
        moved=0
        for (( i = 0; i < n; i++ )); do
            [ "$budget" -gt 0 ] || break
            if [ "${give[i]}" -lt "${want[i]}" ]; then
                give[i]=$(( give[i] + 1 )); budget=$(( budget - 1 )); moved=1
            fi
        done
    done
    printf '%s\n' "${give[@]}"
}

# The predecessor section was removed when that harness was retired: a dashboard
# that keeps reporting a system nobody runs trains the eye to skip the pane. Its figures —
# mayor/deacon dots, merge-queue depth, parked beads, orphans, dispatch mode — described
# agents, a scheduler and a queue that no longer exist. Disk stayed, in standing_lines.
#
# frame <rows> <cols> — assemble one frame for a pane of this size (0 rows = unlimited).
#
# The four elastic sections are rendered IN FULL first and then cut to their allocation.
# Building them first is what makes the share honest: the allocator is told what each
# section could actually use, rather than a guess made before the data was read.
frame() {
    local rows="${1:-0}"
    # A GLOBAL, DELIBERATELY. Every section needs the width and none of them takes an
    # argument for it — they are called through process substitution and would have to
    # thread it through unchanged. Set once per frame, so a resize reflows on the next tick.
    COLS="${2:-0}"; [ "$COLS" -gt 0 ] 2>/dev/null || COLS=80
    load_snapshot
    local -a HEAD TOKENS NOW NEXT RECENT CI STANDING give
    mapfile -t HEAD     < <(header_line)
    mapfile -t TOKENS   < <(tokens_section)
    mapfile -t NOW      < <(now_section)
    mapfile -t NEXT     < <(next_section)
    mapfile -t RECENT   < <(recent_section)
    mapfile -t CI       < <(ci_section)
    mapfile -t STANDING < <(standing_lines)

    # Each want is capped at MAX_SECTION_ROWS here as well as at the collector, because the
    # two caps guard different failures: the collector's stops it writing rows nothing can
    # show, and this one stops a section that grows from a variable-length source — NOW
    # emits three rows per aeon — from taking the column when the collector was generous.
    local -a want=("${#NOW[@]}" "${#NEXT[@]}" "${#RECENT[@]}" "${#CI[@]}")
    local i
    for (( i = 0; i < ${#want[@]}; i++ )); do
        [ "${want[i]}" -gt "$MAX_SECTION_ROWS" ] && want[i]="$MAX_SECTION_ROWS"
    done
    # TOKENS counts as FIXED, alongside the header and the standing figures: every one of its
    # rows is a number that is always worth its row, and the constraint that stops all other
    # work must not be what the allocator elides on a short pane.
    mapfile -t give < <(share "$rows" \
        $(( ${#HEAD[@]} + ${#TOKENS[@]} + ${#STANDING[@]} )) "${want[@]}")

    printf '%s\n' "${HEAD[@]}"
    printf '%s\n' "${TOKENS[@]}"
    [ "${give[0]}" -gt 0 ] && printf '%s\n' "${NOW[@]:0:${give[0]}}"
    [ "${give[1]}" -gt 0 ] && printf '%s\n' "${NEXT[@]:0:${give[1]}}"
    [ "${give[2]}" -gt 0 ] && printf '%s\n' "${RECENT[@]:0:${give[2]}}"
    [ "${give[3]}" -gt 0 ] && printf '%s\n' "${CI[@]:0:${give[3]}}"
    printf '%s\n' "${STANDING[@]}"
    return 0
}

# render <rows> <cols> — the frame, cut to what the pane can actually show.
#
# The share above already fits the elastic sections to the pane, so this is the backstop for
# the case it cannot solve: a pane too short even for one row of each section plus the
# standing figures. Seven lines were once written into five and the terminal scrolled — the
# top two vanished silently on every repaint, which is how the disk line and the ready total
# came to be invisible for weeks without anyone noticing they had been specified. Lines are
# emitted in priority order, the tail is dropped, and the DROP COUNT IS MARKED ON THE HEADER:
# a dashboard that hides content without saying so is the failure it exists to prevent.
# 0 rows means no limit, which is what `once` uses.
render() {
    local rows="${1:-0}" cols="${2:-0}" n drop
    local -a all
    mapfile -t all < <(frame "$rows" "$cols")
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
# at all, assume a small pane: under-rendering shows a ▾ count on the header and is visible
# and recoverable, while over-rendering scrolls the top lines away in silence. Five is
# deliberately pessimistic — the cockpit gives this pane a full column, so a fallback sized
# for one would be a guess that fails in the unsafe direction.
term_rows() {
    local r
    r="$(stty size 2>/dev/null | awk '{print $1}')"
    [ -n "${r:-}" ] || r="$(tput lines 2>/dev/null)"
    [ -n "${r:-}" ] || r="${LINES:-}"
    [ -n "${r:-}" ] && [ "$r" -gt 0 ] 2>/dev/null || r=5
    printf '%s' "$r"
}

# The same question in the other dimension, and it is asked for the same reason: the column
# is a percentage of a window whose width is the operator's, so nothing here may assume one.
# The fallback is 80 — the width every terminal has had since before any of this.
term_cols() {
    local c
    c="$(stty size 2>/dev/null | awk '{print $2}')"
    [ -n "${c:-}" ] || c="$(tput cols 2>/dev/null)"
    [ -n "${c:-}" ] || c="${COLUMNS:-}"
    [ -n "${c:-}" ] && [ "$c" -gt 0 ] 2>/dev/null || c=80
    printf '%s' "$c"
}

LAST_FRAME=""
paint() {
    local rows cols buf i n
    # Re-read every tick rather than trapping SIGWINCH: it is a couple of forks every two
    # seconds, and a resize the frame does not notice re-creates the scrolling bug silently.
    rows="$(term_rows)"; cols="$(term_cols)"
    buf="$(render "$rows" "$cols")"
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
# An explicit row count makes the share observable from outside the pane. Without it a
# suite would have to fake a TTY of a given height to see how the rows were divided, and
# an allocator nobody has watched divide anything is a hypothesis.
once) render "${2:-0}" "${3:-0}" ;;
loop) printf '\e[?25l\e[?7l' 2>/dev/null; while :; do paint; sleep 2; done ;;
*) echo "usage: health.sh [once [rows [cols]]|loop]" >&2; exit 1 ;;
esac
