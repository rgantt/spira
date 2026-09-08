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

# NEXT AND RECENT ARE ELASTIC, AND THE ALLOCATOR — NOT A CONSTANT — DECIDES HOW TALL THEY ARE.
# They were held to five each, which spent the pane's slack rather than the pane: on the
# 52-row column this runs in, an idle harness rendered about eighteen rows and left thirty
# blank, because once every section had reached its `want` the round-robin had nowhere left
# to put the budget. The operator, watching that: "i still see a lot of unused vertical rows
# ... if there are no aeons running? more next, more recent. if there are aeons? scale those
# down."
#
# So these are no longer the size of the section. They are a CEILING on how much the section
# may ever ask for, set high enough that on any real pane the height is decided by `share`
# and by how much data actually exists. `share` already scales correctly in both directions
# — it is round-robin, one row at a time, so a NOW that grows by four rows per live aeon
# takes its rows out of these two and hands them back when the aeons finish.
#
# THEY STAY TWO KEYS RATHER THAN ONE. They answer different questions and will not stay the
# same number — a shared constant is how two sections come to be resized together by someone
# who meant to resize one.
#
# THE COLLECTOR MUST AGREE. A ceiling here that the collector does not emit rows for is a
# section that silently stays five tall; `spira/cockpit.sh` caps SP_NEXT and SP_EVENT to the
# same figure, and the two are commented at each other on purpose.
#
# The generic cap above still governs CI, which is a list of work parked since yesterday and
# has no fixed useful length.
MAX_NEXT_ROWS=40
MAX_RECENT_ROWS=40

# THE FIVE THAT WERE THE WHOLE SECTION ARE NOW ITS FLOOR. Elastic does not mean unguaranteed:
# these are what NEXT and RECENT are given before any section is taken past its base, so a
# short or busy pane still shows the same five queued beads and five events it always did.
# The ceilings above are only what they may grow INTO once every other section is satisfied.
NEXT_BASE_ROWS=5
RECENT_BASE_ROWS=5

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

    # RATE LIMIT WINDOWS. The two windows that end a working day when full, now visible before
    # that happens. SP_RATELIM_5H_PCT / _7D_PCT are 0–100 integers from the newest
    # rate_limit_event across live aeon traces. SP_RATELIM_*_MIN is minutes until reset.
    # SP_RATELIM_*_ETA is seconds to full from the last hour's slope ('-' resets first,
    # '?' no slope). SP_RATELIM_AGE is seconds since the newest trace reading.
    #
    # A MISSING READING RENDERS '?', NOT 0. A window shown at 0% is the best possible news;
    # a broken probe must never produce that reading (law-absence-needs-a-positive-control).
    #
    # COLOUR BANDS match ctx-meter.sh: green < 70%, yellow 70–90%, red ≥ 90%.
    local p5="${SP_RATELIM_5H_PCT:-?}" p7="${SP_RATELIM_7D_PCT:-?}"
    local m5="${SP_RATELIM_5H_MIN:-?}" m7="${SP_RATELIM_7D_MIN:-?}"
    local e5="${SP_RATELIM_5H_ETA:-?}" e7="${SP_RATELIM_7D_ETA:-?}"
    local cage="${SP_RATELIM_AGE:-?}"

    # Colour for each window
    local c5="$C_OK" c7="$C_OK"
    [ "${p5:-0}" -ge 90 ] 2>/dev/null && c5="${C_BAD}${C_B}" || \
    [ "${p5:-0}" -ge 70 ] 2>/dev/null && c5="$C_WARN"
    [ "${p7:-0}" -ge 90 ] 2>/dev/null && c7="${C_BAD}${C_B}" || \
    [ "${p7:-0}" -ge 70 ] 2>/dev/null && c7="$C_WARN"

    # Minutes → human-readable duration. Pure-bash, no subshell.
    local DUR5 DUR7
    _dur_m() {  # _dur_m <minutes> <varname>
        local _m="$1" _v="$2"
        case "$_m" in ''|'?'|*[!0-9]*) printf -v "$_v" '%s' "${_m:-?}"; return ;; esac
        if   [ "$_m" -eq 0 ];    then printf -v "$_v" '0m'
        elif [ "$_m" -lt 60 ];   then printf -v "$_v" '%dm' "$_m"
        elif [ "$_m" -lt 1440 ]; then printf -v "$_v" '%dh%dm' $(( _m / 60 )) $(( _m % 60 ))
        else printf -v "$_v" '%dd%dh' $(( _m / 1440 )) $(( _m % 1440 / 60 )); fi
    }
    _dur_m "$m5" DUR5; _dur_m "$m7" DUR7

    # ETA suffix for each window (empty when not projectable)
    local eta5_sfx="" eta7_sfx=""
    case "$e5" in
        '-'|'?'|'') ;;
        '0') eta5_sfx=" ${C_BAD}${C_B}FULL${C_RST}" ;;
        *[!0-9]*) ;;
        *)  local _em5=$(( e5 / 60 ))
            local _ed5
            _dur_m "$_em5" _ed5
            eta5_sfx=" ${C_DIM}→full ${_ed5}${C_RST}" ;;
    esac
    case "$e7" in
        '-'|'?'|'') ;;
        '0') eta7_sfx=" ${C_BAD}${C_B}FULL${C_RST}" ;;
        *[!0-9]*) ;;
        *)  local _em7=$(( e7 / 60 ))
            local _ed7
            _dur_m "$_em7" _ed7
            eta7_sfx=" ${C_DIM}→full ${_ed7}${C_RST}" ;;
    esac

    # Stale-reading note: if the newest trace sample is more than 15 minutes old, say so.
    local age_sfx=""
    [ "${cage:-0}" -ge 900 ] 2>/dev/null \
        && age_sfx=" ${C_DIM}($(( cage / 60 ))m ago)${C_RST}"

    printf ' %sWIN%s   5h %s%s%%%s  %sreset %s%s%s%s\n' \
        "$C_DIM" "$C_RST" \
        "$c5" "${p5:-?}" "$C_RST" \
        "$C_DIM" "$DUR5" "$C_RST" \
        "$eta5_sfx" "$age_sfx"
    printf '        7d %s%s%%%s  %sreset %s%s%s\n' \
        "$c7" "${p7:-?}" "$C_RST" \
        "$C_DIM" "$DUR7" "$C_RST" \
        "$eta7_sfx"
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

# model_short <id> -> a name that fits a third-width pane: claude-opus-4-6 -> opus 4.6.
#
# THE UNKNOWNS PASS STRAIGHT THROUGH. `?` means the collector could not read the trace and `-`
# means the trace held no init event; neither is turned into a plausible model name, because a
# pane that invents one is worse than a pane that admits it does not know
# (law-absence-needs-a-positive-control). Anything this does not recognise is printed as it
# came, so a new model id shows up ugly rather than silently as something else.
model_short() {
    case "${1:-?}" in
        ""|"?"|"-") printf '%s' "${1:-?}" ;;
        # THE DATE STAMP COMES OFF FIRST. `claude-haiku-4-5-20251001` otherwise matches the
        # version rule on its last two groups and renders "haiku-4 5.20251001", which reads as
        # a version number nobody has. A dated id is the normal shape for a pinned model, so
        # this is the common case rather than a curiosity.
        claude-*)   printf '%s' "${1#claude-}" \
                      | sed -E 's/-[0-9]{8}$//; s/-([0-9]+)-([0-9]+)$/ \1.\2/; s/-([0-9]+)$/ \1/' ;;
        *)          printf '%s' "$1" ;;
    esac
}

# NOW — who is working, on what, HOW THE SESSION IS DOING, and the last thing it said.
#
# FOUR ROWS PER AEON, because three of them answered "is it alive" and none answered "is it
# well". A name and a last command cannot distinguish a session forty turns in and near its
# context ceiling from one that started a minute ago, nor either from one that stopped
# writing to its trace twenty minutes back — and that last case is the one worth catching,
# since it is the state the stall detector is about to act on. The figures come from the
# collector, which reads each trace once a pass; this section only formats them.
#
# It is therefore the section that grows fastest, and the one the round-robin share exists to
# keep in its lane. It is NOT the section the generic cap trims — see `frame`.
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
        eval "local ti=\${SP_AEON${i}_TITLE:-} pr=\${SP_AEON${i}_PRI:-?} pa=\${SP_AEON${i}_PARTITION:-?}"
        # EVERY ONE OF THESE DEFAULTS TO `?`, NEVER TO 0 OR TO EMPTY. An unset key here means
        # the collector could not read the trace, and a session whose trace cannot be read
        # rendering as "0 turns, 0 files" is an all-clear that displaces the suspicion which
        # would have prompted a look (law-absence-needs-a-positive-control).
        eval "local tn=\${SP_AEON${i}_TURNS:-?} cx=\${SP_AEON${i}_CTX:-?}"
        eval "local md=\${SP_AEON${i}_MODEL:-?}"
        eval "local fl=\${SP_AEON${i}_FILES:-?} qt=\${SP_AEON${i}_QUIET:-?}"
        eval "local sd=\${SP_AEON${i}_SAID:-}"
        # WHO, then WHAT, then the live action — one question per line. Crammed onto
        # one row the name, the bead, the elapsed time and a shell command ran past the
        # pane width and truncated mid-word.
        #
        # THE STATS SHARE THE NAME'S ROW because they describe the same thing the name does:
        # the session, not the bead. Only the tail is fitted — the name is the one field on
        # this row that must never be cut, since it is how two aeons are told apart.
        # THE MODEL, BECAUSE THE PERSONAE NO LONGER SHARE ONE. Ops runs Haiku 4.5, the
        # builders Sonnet 4.6, spike Opus 5, and a bead that went slowly or answered oddly is a
        # different fact depending on which was behind it. It sits on the
        # NAME's row rather than the bead's because a model is a property of the SESSION, like
        # the turns and the context beside it, and not of the work.
        #
        # IT IS READ FROM THE AEON'S OWN TRACE, never from the fayth file. The two disagree
        # exactly when it matters — a fayth edited mid-flight leaves the running session on
        # the model it was summoned with — and a pane sourcing the file would relabel live
        # work at the moment somebody is looking (law-long-lived-processes-pin-their-config).
        fit "the $fy on $(model_short "$md") · ${mn}m · $tn turns · ctx $(tok "$cx") · $fl files" \
            $(( COLS - 9 - ${#nm} ))
        printf ' %s%s%s    %s%s%s %s%s%s\n' \
            "$C_DIM" "$([ "$i" = 0 ] && printf 'NOW' || printf '   ')" "$C_RST" \
            "$C_OK$C_B" "$nm" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
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
        local pw=8; [ "${#pa}" -gt "$pw" ] && pw=${#pa}
        fit "${ti:-?}" $(( COLS - 13 - pw - (${#bd} > 14 ? ${#bd} : 14) ))
        printf '        %sP%s%s %s%-*s%s %s%-14s%s %s%s%s\n' \
            "$(pri_colour "P$pr")" "$pr" "$C_RST" \
            "$C_DIM" "$pw" "$pa" "$C_RST" \
            "$C_ACC" "$bd" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
        # THE ACTION AND THE SILENCE ON ONE ROW, at opposite ends of it. They are one fact
        # read together and useless read apart: `Bash gh run watch` quiet for eleven minutes
        # is a session waiting correctly, and the same command quiet for twenty-five is the
        # one the reaper is coming for. The thresholds are the stall detector's own — 300s is
        # where a silence stops being ordinary thinking, and 1200s is ten beats of 120s,
        # after which the heartbeat stops and the lease starts running out.
        local qs qcol
        if [ "$qt" = "?" ] || [ "$qt" = "-" ]; then qs="quiet $qt"; qcol="$C_BAD$C_B"
        else
            if [ "$qt" -lt 120 ] 2>/dev/null; then qs="quiet ${qt}s"; else qs="quiet $(( qt / 60 ))m"; fi
            if   [ "$qt" -ge 1200 ] 2>/dev/null; then qcol="$C_BAD$C_B"
            elif [ "$qt" -ge 300 ]  2>/dev/null; then qcol="$C_WARN"
            else                                      qcol="$C_DIM"; fi
        fi
        # TRAILING MOMENTS — the N most recent things the session did, oldest first, from
        # the collector's trace_tail read. The newest carries the quiet indicator; the older
        # ones are dim context answering "what led here". When the snapshot holds no ACT{j}
        # keys — N=0, or an older collector — the single ACT line and the SAID line render
        # as before.
        local tl="${SPIRA_COCKPIT_TRACE_LINES:-3}" trail_n=0
        if [ "$tl" -gt 0 ] 2>/dev/null; then
            local j=0
            while [ "$j" -lt "$tl" ]; do
                eval "[ -n \"\${SP_AEON${i}_ACT${j}:-}\" ]" || break
                trail_n=$((trail_n+1))
                j=$((j+1))
            done
        fi
        if [ "$trail_n" -gt 0 ]; then
            local j=0
            while [ "$j" -lt "$trail_n" ]; do
                eval "local trail_line=\${SP_AEON${i}_ACT${j}:-}"
                if [ "$j" -eq $((trail_n - 1)) ]; then
                    local aw=$(( COLS - 12 - ${#qs} )); [ "$aw" -lt 2 ] && aw=2
                    fit "${trail_line:--}" "$aw"
                    local pad=$(( COLS - 10 - ${#FIT} - ${#qs} )); [ "$pad" -lt 1 ] && pad=1
                    printf '        %s↳ %s%s%*s%s%s%s\n' \
                        "$C_RST" "$FIT" "$C_RST" "$pad" "" "$qcol" "$qs" "$C_RST"
                else
                    fit "$trail_line" $(( COLS - 12 ))
                    printf '        %s↳ %s%s\n' "$C_DIM" "$FIT" "$C_RST"
                fi
                j=$((j+1))
            done
        else
            # No trailing moments: original single-line behaviour.
            local aw=$(( COLS - 12 - ${#qs} )); [ "$aw" -lt 2 ] && aw=2
            fit "${ac:--}" "$aw"
            local pad=$(( COLS - 10 - ${#FIT} - ${#qs} )); [ "$pad" -lt 1 ] && pad=1
            printf '        %s↳ %s%s%*s%s%s%s\n' \
                "$C_DIM" "$FIT" "$C_RST" "$pad" "" "$qcol" "$qs" "$C_RST"
            # WHAT IT LAST SAID, IN ITS OWN WORDS — kept only in single-line mode.
            # When trailing moments are shown the said text appears naturally among them.
            case "$sd" in ''|'-'|'?') ;; *)
                fit "$sd" $(( COLS - 12 ))
                printf '        %s“ %s ”%s\n' "$C_DIM" "$FIT" "$C_RST" ;;
            esac
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
        reopened|poisoned|slain|sent)   printf '%s' "$C_BAD" ;;
        in_progress|ended|reclaimed)    printf '%s' "$C_WARN" ;;
        claimed)                        printf '%s' "$C_ACC" ;;
        *)                              printf '%s' "$C_DIM" ;;
    esac
}

part_colour() {
    case "$1" in
        ops) printf '%s' "$C_WARN" ;;
        *)   printf '%s' "$C_DIM"  ;;
    esac
}

next_row() {
    local raw="$1" pri part id rest pw
    pri="${raw%% *}"; rest="${raw#* }"; part="${rest%% *}"; rest="${rest#* }"; id="${rest%% *}"; rest="${rest#* }"
    pw=8; [ "${#part}" -gt "$pw" ] && pw=${#part}
    fit "$rest" $(( COLS - 11 - ${#pri} - pw - (${#id} > 14 ? ${#id} : 14) ))
    printf '        %s%s%s %s%-*s%s %s%-14s%s %s%s%s\n' \
        "$(pri_colour "$pri")" "$pri" "$C_RST" \
        "$C_DIM" "$pw" "$part" "$C_RST" \
        "$C_ACC" "$id" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
}

# "P1 sp-id 12m Title..." -> next_row's format plus an age since close, coloured by threshold.
# Age past hours is the actionable signal; the count alone is the normal healthy state of a
# working system, and colouring it would make this section wallpaper within a day.
unlanded_row() {
    local raw="$1" pri id age rest
    pri="${raw%% *}"; rest="${raw#* }"; id="${rest%% *}"; rest="${rest#* }"; age="${rest%% *}"; rest="${rest#* }"
    local age_col="$C_DIM"
    case "$age" in *h|*d) age_col="$C_WARN" ;; esac
    local aw=${#age}; [ "$aw" -lt 4 ] && aw=4
    fit "$rest" $(( COLS - 12 - ${#pri} - (${#id} > 14 ? ${#id} : 14) - aw ))
    printf '        %s%s%s %s%-14s%s %s%-4s%s %s%s%s\n' \
        "$(pri_colour "$pri")" "$pri" "$C_RST" "$C_ACC" "$id" "$C_RST" \
        "$age_col" "$age" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
}

# RECENT rows arrive as `<age> <actor> <partition> <verb> <bead> <title...>`. The actor
# column shows who acted (sentinel, overseer, ryan, or fayth/aeon-name); the partition column
# shows which queue the bead belongs to. Split rather than print flat: the verb and id are
# what a reader is scanning for. A row that cannot be parsed is printed as-is.
recent_row() {          # recent_row "<age> <actor> <partition> <verb> <bead> <title>" <indent-cols>
    local raw="$1" pad="$2" age actor part verb id rest vw
    # THREE FIXED FIELDS then body. The age is two words ("2m ago"), captured as one group
    # by the leading digits. Actor may carry a slash (builder/bahamut). Body is verb + bead
    # (or count) + optional title.
    if [[ "$raw" =~ ^([0-9]+[smhd][[:space:]]+ago)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
        age="${BASH_REMATCH[1]}"; actor="${BASH_REMATCH[2]}"; part="${BASH_REMATCH[3]}"
        verb="${BASH_REMATCH[4]}"; id="${BASH_REMATCH[5]}"; rest="${BASH_REMATCH[6]}"
    else
        # UNPARSED IS PRINTED AS IT CAME. A formatter must never drop content it could not
        # split — the event is the load-bearing half and the colour is the ornament.
        # IT IS STILL CUT TO THE PANE. Autowrap is off, so a row wider than the pane is cut by
        # the terminal instead, and the terminal's cut is silent — the one thing this pane must
        # never do. Failing to parse a row is not a licence to overflow the column.
        fit "$raw" $(( COLS - pad ))
        printf '%s%s%s\n' "$C_DIM" "$FIT" "$C_RST"; return
    fi
    # THE FIFTH FIELD IS NOT ALWAYS A BEAD. Some sentinel ACTs are AGGREGATES over a pass —
    # "escalated 3 stranded item(s)", "announced and ..." — where the word after the verb is a
    # COUNT or a preposition. Dropped into the id column it wore the same accent colour every
    # real id wears. A bead reference is an `sp-` id, optionally carrying its branch prefix
    # (`spira/sp-d0c2`); anything else is prose, and prose is printed as prose across the id
    # and title columns rather than being cut in half by them.
    if [[ ! "$id" =~ (^|/)sp-[A-Za-z0-9._-]+$ ]]; then
        rest="$id${rest:+ $rest}"
        vw=${#verb}; if [ "$vw" -lt 9 ]; then vw=9; fi
        # fit width: 7(age)+1+12(actor)+1+8(part)+1+vw+1+fit = COLS-pad
        # → fit = COLS - pad - 31 - vw
        fit "$rest" $(( COLS - pad - 31 - vw ))
        printf '%s%-7s%s %s%-12s%s %s%-8s%s %s%-9s%s %s%s%s\n' \
            "$C_DIM" "$age" "$C_RST" \
            "$C_DIM" "$actor" "$C_RST" \
            "$(part_colour "$part")" "$part" "$C_RST" \
            "$(verb_colour "$verb")" "$verb" "$C_RST" \
            "$C_DIM" "$FIT" "$C_RST"
        return
    fi
    # THE VERB IS PADDED, like the age and the id either side of it. Unpadded, the id and
    # title columns began wherever the verb happened to end — `ended` to `reclaimed` is five
    # columns of drift in the one section whose purpose is to be scanned straight down. Nine
    # is the longest verb the collector emits; a longer one widens its own row rather than
    # being cut, so the arithmetic below takes whichever is greater.
    vw=${#verb}; if [ "$vw" -lt 9 ]; then vw=9; fi
    # fit width: 7(age)+1+12(actor)+1+8(part)+1+vw+1+max(14,id)+1+fit = COLS-pad
    # → fit = COLS - pad - 32 - vw - max(14, id_len)
    fit "$rest" $(( COLS - pad - 32 - vw - (${#id} > 14 ? ${#id} : 14) ))
    printf '%s%-7s%s %s%-12s%s %s%-8s%s %s%-9s%s %s%-14s%s %s%s%s\n' \
        "$C_DIM" "$age" "$C_RST" \
        "$C_DIM" "$actor" "$C_RST" \
        "$(part_colour "$part")" "$part" "$C_RST" \
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
    printf ' %sNEXT%s   %s%s ready%s %s— across all partitions:%s\n' "$C_DIM" "$C_RST" \
        "$C_B" "${SP_NEXT_N}" "$C_RST" "$C_DIM" "$C_RST"
    local i=0 raw
    while [ "$i" -lt "$MAX_NEXT_ROWS" ]; do
        eval "raw=\${SP_NEXT$i:-}"
        [ -n "$raw" ] || break
        next_row "$raw"
        i=$((i+1))
    done
}

# UNLANDED — closed beads whose branch has not yet reached the base. This is the one
# lifecycle stage the pane cannot otherwise show: between "an aeon closed it" and "a commit
# on the base branch names it" there is a queue that was previously invisible. A non-zero
# count is the normal healthy state of a working system; age past a threshold is the
# actionable signal (law-alerts-must-be-actionable).
unlanded_section() {
    if [ -z "${SP_PEND_N:-}" ] || [ "${SP_PEND_N:-}" = "?" ]; then
        unread_row UNLND "cannot read the unlanded queue"
        return
    fi
    if [ "${SP_PEND_N}" -eq 0 ] 2>/dev/null; then
        printf ' %sUNLND%s  %snothing waiting to land%s\n' \
            "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
        return
    fi
    local age_col="$C_DIM"
    case "${SP_PEND_OLDEST:-}" in *h|*d) age_col="$C_WARN" ;; esac
    printf ' %sUNLND%s  %s%s closed, not on base%s %s— oldest%s %s%s%s\n' \
        "$C_DIM" "$C_RST" "$C_B" "${SP_PEND_N}" "$C_RST" \
        "$C_DIM" "$C_RST" "$age_col" "${SP_PEND_OLDEST:-?}" "$C_RST"
    local i=0 raw
    while [ "$i" -lt "$MAX_SECTION_ROWS" ]; do
        eval "raw=\${SP_PEND$i:-}"
        [ -n "$raw" ] || break
        unlanded_row "$raw"
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
    # THE `\n` IS LOAD-BEARING, and it belongs to these format strings rather than to
    # recent_row: `$( )` strips trailing newlines, so the row's own one never survives being
    # captured. Without it every event was emitted onto one physical line — and because
    # `frame` sizes this section by the number of LINES it produced, the allocator was then
    # told RECENT wanted a single row and handed the rest of the column to NEXT. The section
    # rendering itself wrong and the column's arithmetic being wrong were one defect.
    printf ' %sRECENT%s %s\n' "$C_DIM" "$C_RST" "$(recent_row "$ev" 8)"
    # FROM ONE, BECAUSE THE HEADER ALREADY SPENT EVENT ZERO. The cap counts EVENTS, not the
    # rows beneath the label — five events is five events whether or not the newest of them
    # shares a line with the word RECENT.
    i=1
    while [ "$i" -lt "$MAX_RECENT_ROWS" ]; do
        eval "ev=\${SP_EVENT$i:-}"
        [ -n "$ev" ] || break
        printf '        %s\n' "$(recent_row "$ev" 8)"
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
    local unadopt_seg=""
    [ "${SP_UNADOPTED:-0}" != 0 ] && unadopt_seg="$(printf ' · %s%s unadopted%s' "$C_WARN" "${SP_UNADOPTED}" "$C_RST")"
    printf ' %sSEND%s   %s%s branches unsent%s · %s%s awaiting rites%s · %soldest %sh%s%s\n' \
        "$C_DIM" "$C_RST" "$C_B" "${SP_UNSENT:-?}" "$C_RST" \
        "$( [ "${SP_BRANCH_DONE:-0}" = 0 ] && printf '%s' "$C_DIM" || printf '%s' "$C_WARN")" "${SP_BRANCH_DONE:-?}" "$C_RST" \
        "$age_col" "${SP_UNSENT_OLDEST_H:-?}" "$C_RST" "$unadopt_seg"
    printf '        %s%s fiends%s %s— unsent work that came back%s\n' \
        "$fail_col" "${SP_SENT_FAILED:-?}" "$C_RST" "$C_DIM" "$C_RST"

    # 24H — throughput, and whether closing meant landing.
    printf ' %sBEADS%s  %s24h%s  closed %s · %sopened%s %s\n' \
        "$C_DIM" "$C_RST" "$C_DIM" "$C_RST" "${SP_CLOSED_24H:-?}" \
        "$C_DIM" "$C_RST" "${SP_OPENED_24H:-?}"
    # Sparklines: opened and closed share a row (they are a flow balance); landed is its
    # own row (bursty, different scale). Each series is scaled to itself — the question is
    # "rising or falling" for that series, not a cross-series comparison. A `?` from the
    # probe means the source could not be read (law-absence-needs-a-positive-control).
    printf '        %sopened%s %s  %sclosed%s %s\n' \
        "$C_DIM" "$C_RST" "${SP_BEADS_SPARK_OPENED:-?}" \
        "$C_DIM" "$C_RST" "${SP_BEADS_SPARK_CLOSED:-?}"
    printf '        %slanded%s %s  %s%s%s in 24h\n' \
        "$C_DIM" "$C_RST" "${SP_BEADS_SPARK_LANDED:-?}" \
        "$C_DIM" "${SP_BEADS_LANDED_24H:-?}" "$C_RST"
    # The kinds are a breakdown of the number above, so they read as one when they sit under
    # it — and on their own row they can be four kinds rather than however many fit.
    fit "${SP_CLOSED_KINDS:--}" $(( COLS - 8 ))
    printf '        %s%s%s\n' "$C_DIM" "$FIT" "$C_RST"
    # THE ROW STATES ITS OWN WINDOW. Previously it inherited "24h" from the header while its
    # population was all-time, so comparing it against the 24h closed/opened counts above
    # produced nonsense — 59% of the row was outside its header's window.
    printf '        %s24h worked %s:%s %s landed · %s%s awaiting%s · %s%s never landed%s\n' \
        "$C_DIM" "${SP_CLOSED:-?}" "$C_RST" "${SP_LANDED:-?}" \
        "$C_DIM" "${SP_AWAITING_LAND:-0}" "$C_RST" \
        "$( [ "${SP_UNLANDED:-0}" = 0 ] && printf '%s' "$C_OK" || printf '%s' "$C_BAD$C_B")" "${SP_UNLANDED:-?}" "$C_RST"
    fit "never landed = closed, no commit names it, no branch" $(( COLS - 8 ))
    printf '        %s%s%s\n' "$C_DIM" "$FIT" "$C_RST"

    # LAND — the DONE-to-LANDED stretch. The operator (2026-09-07): "there's currently a
    # lot that happens between 'DONE' and 'LANDED' and the ops dashboard shows none of it."
    #
    # The landing pass's own state renders from landing.status without the collector
    # recomputing any of it; live gate runs render with their branch, age, and whether they
    # are waiting on the tree lock or running suites.
    local land_age="?"
    if [ -n "${SP_LAND_AT:-}" ] && [ "${SP_LAND_AT:-?}" != "?" ]; then
        land_age=$(( $(date +%s) - SP_LAND_AT ))
    fi
    local land_rc_col
    case "${SP_LAND_RC:-?}" in
        0) land_rc_col="$C_OK" ;;
        '?') land_rc_col="$C_BAD$C_B" ;;
        *) land_rc_col="$C_WARN" ;;
    esac
    printf ' %sLAND%s   %slast%s %s  %src%s %s%s%s  %sbranches%s %s  %smoved%s %s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "$(age_str "$land_age" 600)" \
        "$C_DIM" "$C_RST" "$land_rc_col" "${SP_LAND_RC:-?}" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_LAND_BRANCHES:-?}" \
        "$C_DIM" "$C_RST" "${SP_LAND_MOVED:-?}"
    if [ "${SP_GATE_LIVE:-0}" != "0" ] && [ "${SP_GATE_LIVE:-0}" != "?" ]; then
        printf '        %s%s gate(s) running:%s\n' "$C_B" "${SP_GATE_LIVE}" "$C_RST"
        local gi=0
        while [ "$gi" -lt "${SP_GATE_N:-0}" ] 2>/dev/null; do
            eval "local gs=\${SP_GATE${gi}_SLUG:-?} ga=\${SP_GATE${gi}_AGE:-?}"
            eval "local gp=\${SP_GATE${gi}_PHASE:-?} gw=\${SP_GATE${gi}_WHY:-}"
            local age_s
            if [ "$ga" = "?" ]; then age_s="?"
            elif [ "$ga" -lt 120 ] 2>/dev/null; then age_s="${ga}s"
            else age_s="$(( ga / 60 ))m"; fi
            local phase_col="$C_DIM"
            [ "$gp" = waiting ] && phase_col="$C_WARN"
            fit "${gw:+ · $gw}" $(( COLS - 30 - ${#gs} - ${#age_s} ))
            printf '        %s%s%s  %s%-7s%s  %s%s%s%s\n' \
                "$C_ACC" "$gs" "$C_RST" \
                "$phase_col" "$gp" "$C_RST" \
                "$C_DIM" "$age_s" "$C_RST" \
                "$( [ -n "${gw:-}" ] && printf ' %s%s%s' "$C_DIM" "$FIT" "$C_RST" )"
            gi=$((gi+1))
        done
    elif [ "${SP_GATE_LIVE:-?}" = "?" ]; then
        printf '        %s%s? cannot read gate state%s\n' "$C_BAD" "$C_B" "$C_RST"
    fi
    # Landing progress — per-branch outcomes of the pass in flight.
    if [ "${SP_LANDPROG_N:-0}" != "0" ] && [ "${SP_LANDPROG_N:-0}" != "?" ]; then
        local li=0
        while [ "$li" -lt "${SP_LANDPROG_N:-0}" ] 2>/dev/null; do
            eval "local lp=\${SP_LANDPROG${li}:-}"
            if [ -n "$lp" ]; then
                fit "$lp" $(( COLS - 10 ))
                printf '        %s%s%s\n' "$C_DIM" "$FIT" "$C_RST"
            fi
            li=$((li+1))
        done
    fi

    # GRAPH — the beads themselves, kept apart from sessions and asks so the counts cannot
    # be read as the same kind of thing.
    # STRANDED IS THE GHOST COUNT, NOT THE LEDGER SIZE. strands.json holds every disposition
    # strand.sh classifies and only `ghost` is a claimed bead whose holder is gone; the size
    # rendered under that name made a childless epic read as a dead worker. The ledger total
    # stays alongside in parentheses, because it is context rather than an alarm.
    local _graph
    _graph="$(printf 'open %s · ready %s · working %s · poison %s · strand %s (ledger %s)' \
        "${SP_OPEN:-?}" "${SP_READY:-?}" "${SP_INPROG:-?}" "${SP_POISON:-?}" \
        "${SP_STRAND_GHOST:-?}" "${SP_STRANDS:-?}")"
    fit "$_graph" $(( COLS - 8 ))
    printf '        %s%s%s\n' \
        "$( [ "${SP_POISON:-0}" = 0 ] && printf '%s' "$C_DIM" || printf '%s' "$C_WARN")" "$FIT" "$C_RST"

    # GATE — is the check between work and its landings buying anything? The pane already
    # instruments what the harness COSTS; this is the only line that says whether one of its
    # costs is earning its place (law-gate-earns-its-place). It is here because the previous
    # gate was deleted after twelve hours of fallout rather than on evidence, and every fact
    # needed to delete it a fortnight earlier was already being written down.
    #
    # UNKNOWN GETS ITS OWN FIGURE AND IS NEVER FOLDED INTO EITHER. A yield of "3 defect, 8
    # fault" reads as a complete accounting; if half the reds were never classified, the
    # ratio is a fiction and only a visible unknown count says so.
    #
    # SOLO AND CONTENDED, BOTH, because a landing gate never runs solo — every aeon runs one
    # before it closes and the landing pass runs one per branch — so a solo figure describes
    # a condition the gate is never in. The gap between the two is what decides whether it is
    # affordable, and quoting only the first is how one was adopted at 101s and turned out to
    # cost 329s.
    local fault_col
    case "${SP_YIELD_FAULT:-?}" in
        0)  fault_col="$C_OK" ;;
        '?') fault_col="$C_BAD$C_B" ;;   # unreadable is a fault of its own, not all-clear
        *)  fault_col="$C_WARN" ;;
    esac
    # A UNIT ON AN UNREADABLE FIELD INVITES READING IT AS A MEASUREMENT: `?s` looks like a
    # duration somebody forgot to fill in, and a `?` here means this probe could not read the
    # gate log at all.
    local solo="${SP_YIELD_SOLO_MED:-?}" conc="${SP_YIELD_CONC_MED:-?}"
    [ "$solo" = "?" ] || solo="${solo}s"
    [ "$conc" = "?" ] || conc="${conc}s"
    printf ' %sGATE%s   %sreds%s %s · %sdefect%s %s · %sgate fault%s %s%s%s · %sunknown%s %s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_YIELD_REDS:-?}" \
        "$C_DIM" "$C_RST" "${SP_YIELD_DEFECT:-?}" \
        "$C_DIM" "$C_RST" "$fault_col" "${SP_YIELD_FAULT:-?}" "$C_RST" \
        "$C_DIM" "$C_RST" "${SP_YIELD_UNKNOWN:-?}"
    printf '        %scost%s %s solo · %s with another gate overlapping %s(median)%s\n' \
        "$C_DIM" "$C_RST" "$solo" "$conc" "$C_DIM" "$C_RST"

    # HEALTH — the harness watching itself.
    #
    # THREE INDEPENDENT SIGNALS. Each is rendered only when it has something actionable to say:
    #
    # REPEATING: an ACT text that appeared in consecutive passes ending at the most recent one
    # within SPIRA_SELF_WINDOW (default 60 min). A 24h burst that stopped before the window
    # produces nothing here — "repeating now" means the last pass also had the act. Nothing
    # repeating → no SELF row (law-alerts-must-be-actionable; the same rule that moved the
    # #ryan list: a row that always reads the same becomes wallpaper).
    #
    # BIRTH / STALL: regression tripwires for two fixed bugs. 0 is their correct value and a
    # row that always reads 0 is wallpaper. They appear only when non-zero within the window,
    # in the BAD colour, with the count and the last occurrence time.
    #
    # JUDGE: passes since the judgement tier fired — always shown, because "never fired" and
    # "fired 40 passes ago" look identical from outside and mean opposite things.
    local judge="${SP_SINCE_JUDGEMENT:-?}" judge_str
    case "$judge" in
        '?')      judge_str="${C_BAD}${C_B}?${C_RST}" ;;
        'n/a')    judge_str="${C_DIM}not needed${C_RST}" ;;
        'NEVER'*) judge_str="${C_BAD}${C_B}${judge}${C_RST}" ;;
        *)        judge_str="${C_DIM}${judge} passes ago${C_RST}" ;;
    esac

    # REPEATING rows: one per distinct active repeating pattern.
    local srep="${SP_SELF_REPEATING_N:-0}" srep_i=0
    while [ "$srep_i" -lt "${srep:-0}" ] 2>/dev/null; do
        eval "local srtxt=\${SP_SELF_REPEATING${srep_i}:-}"
        if [ -n "$srtxt" ]; then
            fit "$srtxt" $(( COLS - 20 ))
            if [ "$srep_i" -eq 0 ]; then
                printf ' %sSELF%s   %s%sREPEATING%s  %s%s%s\n' \
                    "$C_DIM" "$C_RST" "$C_BAD" "$C_B" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
            else
                printf '        %s%sREPEATING%s  %s%s%s\n' \
                    "$C_BAD" "$C_B" "$C_RST" "$C_DIM" "$FIT" "$C_RST"
            fi
        fi
        srep_i=$(( srep_i + 1 ))
    done

    # BIRTH alert: aeons that died at birth within the short window.
    local sb="${SP_SELF_STILLBORN_W:-0}"
    if [ "$sb" != "?" ] && [ "$sb" -gt 0 ] 2>/dev/null; then
        printf ' %sBIRTH%s  %s%s%s%s died at birth%s %s· last %s%s\n' \
            "$C_BAD" "$C_RST" \
            "$C_BAD" "$C_B" "$sb" "$C_RST" \
            "$C_DIM" "$C_RST" "${SP_SELF_STILLBORN_LAST:-?}" "$C_RST"
    fi

    # STALL alert: stalled passes (open work, nothing ready, nothing running) in the window.
    local sv="${SP_SELF_STARVED_W:-0}"
    if [ "$sv" != "?" ] && [ "$sv" -gt 0 ] 2>/dev/null; then
        printf ' %sSTALL%s  %s%s%s%s stalled passes%s %s· last %s%s\n' \
            "$C_BAD" "$C_RST" \
            "$C_BAD" "$C_B" "$sv" "$C_RST" \
            "$C_DIM" "$C_RST" "${SP_SELF_STARVED_LAST:-?}" "$C_RST"
    fi

    # JUDGE: always shown. Distinguishes "never fired" from "fired 40 passes ago".
    printf ' %sSELF%s   %sjudgement%s %s\n' "$C_DIM" "$C_RST" "$C_DIM" "$C_RST" "$judge_str"
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

    # OPS — the SOP shelf. Which runbooks have never been exercised (dead weight in context),
    # and which have been applied but did not hold within the window.
    # `?` for either field means the shelf or the ledger could not be read; see sop_keys() in
    # cockpit.sh. A recurrence of 0 is the healthy state; never-fired >0 is expected on a new
    # install and becomes a signal as the shelf ages.
    printf ' %sOPS%s    %snever-fired%s %s · %srecurred (no hold)%s %s\n' \
        "$C_DIM" "$C_RST" \
        "$C_DIM" "$C_RST" "$(num "${SP_SOP_NEVER_FIRED:-?}" 5)" \
        "$C_DIM" "$C_RST" "$(bad_unless_zero "${SP_SOP_RECURRED:-?}")"
}

# share <rows> <fixed> <base:max...> -> one allocation per section, on its own line
#
# ROUND-ROBIN, ONE ROW AT A TIME. Filling each section to its cap in turn is the obvious
# implementation and the wrong one: NOW spends four rows per working aeon, so on a busy
# day it would take the whole column and CI — the section that reports a run parked since
# yesterday, and the only place that fact appears — would be the one to vanish.
#
# TWO TIERS, BECAUSE ONE ROUND-ROBIN CANNOT SAY BOTH THINGS. Every section names a BASE it
# needs and a MAX it could use, and the base of every section is satisfied before any section
# is taken past it. Without the split, giving NEXT and RECENT a high ceiling so they could
# absorb the pane's slack also let them out-vote NOW in the ordinary case: a fair one-row-each
# share handed NOW 8 of the 12 rows its three live aeons wanted on a 45-row pane, while NEXT
# and RECENT grew past the five they need — the section describing work in flight trimmed to
# feed the two sections that exist to fill space around it. Tier one is the rationing that
# protects CI on a short pane; tier two is the slack, and only the elastic sections bid for it.
#
# EVERY SECTION KEEPS ITS FIRST ROW even when there is no budget for it. The overflow then
# falls off the BOTTOM of the frame in `render`, which marks the count on the header; a
# section quietly allocated zero rows would leave no such mark.
share() {
    local rows="$1" fixed="$2"; shift 2
    local -a spec=("$@") base=() max=() give=()
    local n=${#spec[@]} i budget moved tier lim
    for (( i = 0; i < n; i++ )); do
        base[i]="${spec[i]%%:*}"; max[i]="${spec[i]##*:}"
        # A MAX BELOW ITS BASE IS THE BASE. The two are computed independently at the call
        # site — one from a constant, one from how many rows the section actually rendered —
        # and a section with three rows of data must not be asked for five.
        [ "${max[i]}" -lt "${base[i]}" ] 2>/dev/null && max[i]="${base[i]}"
        if [ "${max[i]}" -gt 0 ]; then give[i]=1; else give[i]=0; fi
    done
    # 0 rows means no limit, which is what `once` uses: give every section everything.
    [ "$rows" -le 0 ] && { printf '%s\n' "${max[@]}"; return; }
    budget=$(( rows - fixed ))
    for (( i = 0; i < n; i++ )); do budget=$(( budget - give[i] )); done
    for tier in 1 2; do
        moved=1
        while [ "$budget" -gt 0 ] && [ "$moved" = 1 ]; do
            moved=0
            for (( i = 0; i < n; i++ )); do
                [ "$budget" -gt 0 ] || break
                if [ "$tier" = 1 ]; then lim="${base[i]}"; else lim="${max[i]}"; fi
                if [ "${give[i]}" -lt "$lim" ]; then
                    give[i]=$(( give[i] + 1 )); budget=$(( budget - 1 )); moved=1
                fi
            done
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
# The five elastic sections are rendered IN FULL first and then cut to their allocation.
# Building them first is what makes the share honest: the allocator is told what each
# section could actually use, rather than a guess made before the data was read.
frame() {
    local rows="${1:-0}"
    # A GLOBAL, DELIBERATELY. Every section needs the width and none of them takes an
    # argument for it — they are called through process substitution and would have to
    # thread it through unchanged. Set once per frame, so a resize reflows on the next tick.
    COLS="${2:-0}"; [ "$COLS" -gt 0 ] 2>/dev/null || COLS=80
    load_snapshot
    local -a HEAD TOKENS NOW NEXT UNLANDED RECENT CI STANDING give
    mapfile -t HEAD     < <(header_line)
    mapfile -t TOKENS   < <(tokens_section)
    mapfile -t NOW      < <(now_section)
    mapfile -t NEXT     < <(next_section)
    mapfile -t UNLANDED < <(unlanded_section)
    mapfile -t RECENT   < <(recent_section)
    mapfile -t CI       < <(ci_section)
    mapfile -t STANDING < <(standing_lines)

    # THE GENERIC CAP APPLIES TO CI AND TO NOTHING ELSE NOW.
    #
    # NEXT and RECENT bound themselves at MAX_NEXT_ROWS and MAX_RECENT_ROWS while rendering,
    # so a second cap over them would only ever be dead code that looked load-bearing.
    #
    # AND NOW IS DELIBERATELY UNCAPPED HERE. Its want is four rows per live aeon, which is
    # already its own bound — a figure set by how many sessions are running, not by a number
    # written down here. Holding it to twenty as well would mean the section that just got
    # four rows deep is the first one the allocator trims, which is exactly backwards: it is
    # the section describing work in flight.
    #
    # NOW IS ALSO WHY THE OTHER TWO ARE ELASTIC RATHER THAN FIXED. NOW's want is the only one
    # on this pane that swings with the state of the world, so it is the one the column has
    # to absorb: every row it takes when three aeons wake up has to come from somewhere, and
    # every row it gives back when they finish has to go somewhere. With NEXT and RECENT
    # pinned at five, the giving-back had nowhere to go and the bottom of the pane simply
    # went blank. Their ceilings are now high enough that the round-robin is what sizes them.
    #
    # CI and UNLANDED keep the generic cap because they are lists rather than a glance, and
    # an unbounded one could otherwise take the whole column.
    #
    # EACH SECTION BIDS A BASE AND A MAX. NOW, UNLANDED and CI bid the same for both: their
    # size is set by how many aeons are awake and how much is pending/parked, so there is no
    # slack in them to give away and nothing to gain by asking for more than they have. NEXT
    # and RECENT bid the five they have always been guaranteed as their base, and everything
    # they rendered as their max — they are the two sections that exist to fill the column,
    # so they are the two that bid for the slack.
    #
    # INDICES ARE POSITIONAL: NOW=0, NEXT=1, UNLANDED=2, RECENT=3, CI=4. Adding a section
    # in the middle shifts every index after it; they must be updated together.
    local -a want=("${#NOW[@]}" "${#NEXT[@]}" "${#UNLANDED[@]}" "${#RECENT[@]}" "${#CI[@]}")
    [ "${want[2]}" -gt "$MAX_SECTION_ROWS" ] && want[2]="$MAX_SECTION_ROWS"
    [ "${want[4]}" -gt "$MAX_SECTION_ROWS" ] && want[4]="$MAX_SECTION_ROWS"
    # THE BASES ARE IN LINES, NOT ITEMS, because that is what the allocator hands out. NEXT
    # spends a line of its own on its header, so five queued beads is six lines; RECENT puts
    # the newest event on its header line, so five events is five. Getting this wrong would
    # quietly move one of them off the guarantee by a row.
    local -a spec=(
        "${want[0]}:${want[0]}"
        "$(( NEXT_BASE_ROWS + 1 )):${want[1]}"
        "${want[2]}:${want[2]}"
        "$RECENT_BASE_ROWS:${want[3]}"
        "${want[4]}:${want[4]}"
    )
    # TOKENS counts as FIXED, alongside the header and the standing figures: every one of its
    # rows is a number that is always worth its row, and the constraint that stops all other
    # work must not be what the allocator elides on a short pane.
    mapfile -t give < <(share "$rows" \
        $(( ${#HEAD[@]} + ${#TOKENS[@]} + ${#STANDING[@]} )) "${spec[@]}")

    printf '%s\n' "${HEAD[@]}"
    printf '%s\n' "${TOKENS[@]}"
    [ "${give[0]}" -gt 0 ] && printf '%s\n' "${NOW[@]:0:${give[0]}}"
    [ "${give[1]}" -gt 0 ] && printf '%s\n' "${NEXT[@]:0:${give[1]}}"
    [ "${give[2]}" -gt 0 ] && printf '%s\n' "${UNLANDED[@]:0:${give[2]}}"
    [ "${give[3]}" -gt 0 ] && printf '%s\n' "${RECENT[@]:0:${give[3]}}"
    [ "${give[4]}" -gt 0 ] && printf '%s\n' "${CI[@]:0:${give[4]}}"
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
