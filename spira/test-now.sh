#!/usr/bin/env bash
#
# test-now.sh — the NOW rows, and the caps that pay for them.
#
#   ./test-now.sh
#
# NOW says who holds a bead, how the session holding it is DOING, and the last thing it
# said. The figures come from the aeon's own stream-json trace, read once a pass by the
# collector; this suite covers the reader (`trace_stats`) and the four rows the pane builds
# from it, plus the NEXT and RECENT caps that gave NOW the room.
#
# It is written for this change and stands alone deliberately. The expensive failure for a
# dashboard is not a missing number but a confident wrong one — a session whose trace could
# not be read rendering as a fresh, idle, zero-turn agent is an all-clear nobody goes
# looking behind — so every case here has its negative beside it.
#
# No database, no network, under a second.
#
# covers: cockpit/health.sh spira/lib.sh spira/cockpit.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PANE="$HERE/../cockpit/health.sh"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# is_n <name> <want> <got> — an equality check, named. Defined once at the top because the
# sections below are independent: a suite where the assertion helper is declared inside one
# section silently skips every check in the next when that section is not reached.
is_n() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL  %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fi; }

echo "trace_stats — how healthy a session is, read once from its own trace"

# THE FIXTURE IS THE STREAM SHAPE, NOT A CONVENIENT ONE. `claude -p --include-partial-messages`
# writes one row per CONTENT BLOCK, and the rows of a single assistant message share that
# message id while carrying different blocks. So this trace is three assistant ROWS holding
# two MESSAGES — which is the whole reason turns are a set of ids and tools are a running
# count. A reader that counted rows would say three turns here and be wrong by however
# chatty each turn was.
TD="$TMP/trace"; mkdir -p "$TD"
cat > "$TD/sp-fix.log" <<'TRACE'
{"type":"system","subtype":"init","session_id":"s1"}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3},"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la /tmp"}}]}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/w/a.rs"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000},"content":[{"type":"text","text":"running the token\nsuite = before touching the meter"}]}}
TRACE

# An explicit minimal environment, as every check here runs in: an inherited spira.conf would
# let one operator installation decide these verdicts (law-gates-run-in-a-clean-environment).
stats() {
    env -i PATH="$PATH" HOME="$TMP" LC_ALL=C.UTF-8 SPIRA_CONF="$TMP/no.conf" \
        bash -c '. "$1"/lib.sh; trace_stats "$2"' _ "$HERE" "$1" 2>/dev/null
}
field() { sed -n "s/^$2=//p" <<< "$1"; }

st="$(stats "$TD/sp-fix.log")"
is_n "two messages across three rows are two turns" 2 "$(field "$st" TURNS)"
is_n "and both tool_use blocks are counted" 2 "$(field "$st" TOOLS)"
is_n "one Edit is one file" 1 "$(field "$st" FILES)"
# THE LAST USAGE, NOT THE SUM AND NOT THE FIRST. A context window is a level; summing every
# usage would report 6012 and reading the first would report 6, and both are numbers that
# look entirely plausible on a dashboard. The fixture is built so all three differ.
is_n "ctx is the LAST usage summed across its three fields" 6000 "$(field "$st" CTX)"
# THE ALLOWLIST RUNS BEFORE THE WHITESPACE COLLAPSE, so the `=` becomes a space and then
# vanishes into the one beside it. That ordering is the point: a value carrying `=` is what
# breaks a KEY=value file, and it must not survive as a run of blanks either.
is_n "said is the last text block, sanitised to one line" \
     "running the token suite before touching the meter" "$(field "$st" SAID)"

# THE SANITISER IS LOAD-BEARING, NOT COSMETIC. These values are pasted into a KEY=value file
# that the pane SOURCES with no parser: the newline above would inject a line and the `=`
# would make a bogus key, and every key after it would silently read as unset while the
# collector looked healthy. Asserting the shape is not enough — the file has to source.
#
# THE KEYS ARE NAMED, NOT COUNTED. A bare count of 7 was the first version of this, and it
# failed the day an eighth key was legitimately added — reporting "a pane cannot source this"
# about output that sourced perfectly. A count cannot tell a NEW KEY from an INJECTED LINE,
# which are the opposite of each other; the set can.
WANT_KEYS='ACT CTX FILES MODEL QUIET SAID TOOLS TURNS'
GOT_KEYS="$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' <<< "$st" | sort | tr '\n' ' ' | sed 's/ $//')"
if ( set -u; eval "$(sed 's/=\(.*\)$/='"'"'\1'"'"'/' <<< "$st")" ) 2>/dev/null \
   && [ "$GOT_KEYS" = "$WANT_KEYS" ]; then
    pass=$((pass+1)); printf '  ok    exactly the expected keys, and every one of them sources cleanly\n'
else
    fail=$((fail+1)); printf '  FAIL  trace_stats emitted something a pane cannot source:\n    want keys [%s]\n    got  keys [%s]\n%s\n' "$WANT_KEYS" "$GOT_KEYS" "$st"
fi

# A TRACE THAT CANNOT BE READ AND ONE WITH NOTHING IN IT ARE DIFFERENT FACTS, and neither of
# them is zero. This is the failure the whole panel is built against: a broken read that
# renders as an idle session is an all-clear nobody goes looking behind
# (law-absence-needs-a-positive-control).
gone="$(stats "$TD/no-such.log")"
: > "$TD/empty.log"
blank="$(stats "$TD/empty.log")"
for k in TURNS CTX TOOLS FILES QUIET ACT SAID; do
    is_n "an unreadable trace renders $k as ?" "?" "$(field "$gone" "$k")"
done
for k in TURNS CTX TOOLS FILES ACT SAID; do
    is_n "an empty trace renders $k as - and not 0" "-" "$(field "$blank" "$k")"
done
# QUIET is the one figure an empty trace still has: the file exists, so its silence is
# measurable and is exactly what the stall detector acts on.
case "$(field "$blank" QUIET)" in
    ''|*[!0-9]*) fail=$((fail+1)); printf '  FAIL  an empty trace gave no QUIET reading\n' ;;
    *) pass=$((pass+1)); printf '  ok    but an empty trace still has a QUIET reading\n' ;;
esac

# THE CURRENT ATTEMPT, NOT THE FILE. One log is held across attempts on a bead, so a fresh
# attempt that has written one turn must not inherit the previous session two. The positive
# control is the first segment being LARGER: a reader taking the whole file would say three
# turns here, which is a number that would never look wrong.
{
    cat "$TD/sp-fix.log"
    printf '=== spira attempt 2 aeon=valefor at=2026-01-01T00:00:00Z kept=0\n'
    printf '%s\n' '{"type":"assistant","message":{"id":"m9","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","name":"Bash","input":{"command":"cargo test"}}]}}'
} > "$TD/sp-two.log"
two="$(stats "$TD/sp-two.log")"
is_n "a reopened bead reports THIS attempt, not the file" 1 "$(field "$two" TURNS)"
is_n "and this attempt ctx, not the previous session one" 7 "$(field "$two" CTX)"
is_n "and this attempt last action" "Bash cargo test" "$(field "$two" ACT)"

if [ ! -f "$PANE" ]; then
    fail=$((fail+1)); printf '  FAIL  cannot find the pane at %s\n' "$PANE"
else

PD="$TMP/pane"; mkdir -p "$PD/repo/.runtime/spira" "$PD/home"
SNAPF="$PD/repo/.runtime/spira/cockpit.env"

# Written the way the collector writes it: every value SINGLE-QUOTED. `SP_NEXT0=P1 sp-a A
# title` unquoted is not an assignment, it is an assignment followed by a command, and the
# value arrives as one word with the rest run as a program.
snap() {
    python3 -c '
import sys
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    k, _, v = line.partition("=")
    print("%s=%s" % (k, "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27"))
' > "$SNAPF"
}

# An explicit minimal environment, and SPIRA_CONF pointed at a file that does not exist so
# no operator spira.conf can decide a verdict here (law-gates-run-in-a-clean-environment).
# LC_ALL IS PASSED THROUGH, because the assertions count CHARACTERS and half the frame is
# multibyte. Without it the suite would measure bytes and disagree with the pane about what
# fits — and the pane would be right.
pane() {                 # pane <rows> [cols] -> the frame, ANSI stripped
    env -i PATH="$PATH" HOME="$PD/home" TERM=dumb LC_ALL=C.UTF-8 \
        SPIRA_CONF="$PD/no.conf" SPIRA_REPO="$PD/repo" SPIRA_RUN="$PD/repo/.runtime/spira" \
        bash "$PANE" once "$1" "${2:-0}" 2>/dev/null | sed 's/\x1b\[[?0-9;]*[a-zA-Z]//g'
}
rows_of() { printf '%s\n' "$1" | awk -v l=" $2" 'index($0,l)==1{n=1;next} n && /^ [A-Z]/{exit} n{n++} END{print n+0}'; }

echo
echo "the NOW rows say how healthy each aeon is"

# COLOUR IS THE ASSERTION HERE, so this renders WITHOUT stripping ANSI. The quiet figure is
# the one number on the pane whose value is useless without its threshold: twelve seconds and
# twelve hundred are the same characters and opposite facts. The thresholds are the stall
# detectors own — 1200s is ten heartbeats of 120s, after which the beat stops and the lease
# begins running out.
quiet_col() {   # quiet_col <seconds> -> the colour code the quiet field was painted in
    { printf 'SP_AEON_N=1\nSP_AEON0_NAME=n\nSP_AEON0_FAYTH=builder\nSP_AEON0_BEAD=sp-q\n'
      printf 'SP_AEON0_MIN=1\nSP_AEON0_TURNS=3\nSP_AEON0_CTX=1000\nSP_AEON0_FILES=0\n'
      printf 'SP_AEON0_ACT=Bash x\nSP_AEON0_QUIET=%s\nSP_NEXT_N=0\nSP_AWAITING_N=0\n' "$1"; } | snap
    env -i PATH="$PATH" HOME="$PD/home" TERM=dumb LC_ALL=C.UTF-8 \
        SPIRA_CONF="$PD/no.conf" SPIRA_REPO="$PD/repo" SPIRA_RUN="$PD/repo/.runtime/spira" \
        bash "$PANE" once 0 96 2>/dev/null \
      | python3 -c '
# THE WHOLE RUN OF ESCAPES IMMEDIATELY BEFORE THE WORD, not the last one. A colour here is
# two sequences — red then bold — and a pattern that took only the nearest would read
# 31;1 and 1 as the same reading, which is exactly the two states this is separating.
import sys, re
for line in sys.stdin:
    m = re.search(r"((?:\x1b\[[0-9;]*m)+)quiet", line)
    if m:
        print(";".join(re.findall(r"\x1b\[([0-9;]*)m", m.group(1))))
        break
'
}
is_n "a session acting seconds ago is dim"      "2"    "$(quiet_col 12)"
is_n "five minutes of silence is a warning"     "33"   "$(quiet_col 300)"
is_n "twenty minutes is the reapers threshold"  "31;1" "$(quiet_col 1200)"
is_n "and an unreadable quiet is not a low one" "31;1" "$(quiet_col '?')"

# THE FIGURES REACH THE ROW, and a session whose trace could not be read says so on every one
# of them rather than reporting a fresh, idle, zero-turn agent.
{ printf 'SP_AEON_N=1\nSP_AEON0_NAME=valefor\nSP_AEON0_FAYTH=builder\nSP_AEON0_BEAD=sp-7xn\n'
  printf 'SP_AEON0_MIN=11\nSP_AEON0_TURNS=37\nSP_AEON0_CTX=123400\nSP_AEON0_FILES=4\n'
  printf 'SP_AEON0_QUIET=12\nSP_AEON0_ACT=Bash ./spira/test-tokens.sh 2 1\n'
  printf 'SP_AEON0_TITLE=a bead\nSP_AEON0_SAID=running the token suite\nSP_NEXT_N=0\nSP_AWAITING_N=0\n'; } | snap
row="$(pane 0)"
for want in '37 turns' 'ctx 123k' '4 files' 'quiet 12s' '“ running the token suite ”'; do
    if grep -qF "$want" <<< "$row"; then
        pass=$((pass+1)); printf '  ok    the NOW row says "%s"\n' "$want"
    else
        fail=$((fail+1)); printf '  FAIL  the NOW row did not say "%s":\n%s\n' "$want" "$row"
    fi
done
is_n "and it is four rows for one aeon" 4 "$(rows_of "$row" NOW)"

echo
echo "trailing moments — the last N actions rendered under each aeon"

# THREE TRAILING MOMENTS FROM THE SNAPSHOT. These are the sanitised lines the collector
# would emit from trace_tail; the pane reads them as ACT{j} keys.
{ printf 'SP_AEON_N=1\nSP_AEON0_NAME=valefor\nSP_AEON0_FAYTH=builder\nSP_AEON0_BEAD=sp-7xn\n'
  printf 'SP_AEON0_MIN=11\nSP_AEON0_TURNS=37\nSP_AEON0_CTX=123400\nSP_AEON0_FILES=4\n'
  printf 'SP_AEON0_QUIET=12\nSP_AEON0_ACT=Bash test-sentinel.sh\n'
  printf 'SP_AEON0_ACT0=Read spira/lib.sh\n'
  printf 'SP_AEON0_ACT1=Grep trace_tail\n'
  printf 'SP_AEON0_ACT2=Bash test-sentinel.sh\n'
  printf 'SP_AEON0_TITLE=a bead\nSP_AEON0_PRI=1\nSP_NEXT_N=0\nSP_AWAITING_N=0\n'; } | snap
trail="$(pane 0)"
for want in 'Read spira/lib.sh' 'Grep trace_tail' 'Bash test-sentinel.sh'; do
    if grep -qF "$want" <<< "$trail"; then
        pass=$((pass+1)); printf '  ok    trailing moment "%s" appears\n' "$want"
    else
        fail=$((fail+1)); printf '  FAIL  trailing moment "%s" missing:\n%s\n' "$want" "$trail"
    fi
done
is_n "three trailing moments are 2+3=5 rows per aeon" 5 "$(rows_of "$trail" NOW)"
if grep -qF 'quiet 12s' <<< "$trail"; then
    pass=$((pass+1)); printf '  ok    the newest moment carries quiet\n'
else
    fail=$((fail+1)); printf '  FAIL  quiet indicator missing:\n%s\n' "$trail"
fi

# N=0 RESTORES THE OLD SINGLE-LINE BEHAVIOUR, including the SAID row, even when ACT{j}
# keys are in the snapshot.
{ printf 'SP_AEON_N=1\nSP_AEON0_NAME=valefor\nSP_AEON0_FAYTH=builder\nSP_AEON0_BEAD=sp-7xn\n'
  printf 'SP_AEON0_MIN=11\nSP_AEON0_TURNS=37\nSP_AEON0_CTX=123400\nSP_AEON0_FILES=4\n'
  printf 'SP_AEON0_QUIET=12\nSP_AEON0_ACT=Bash test-sentinel.sh\n'
  printf 'SP_AEON0_ACT0=Read spira/lib.sh\n'
  printf 'SP_AEON0_ACT1=Grep trace_tail\n'
  printf 'SP_AEON0_ACT2=Bash test-sentinel.sh\n'
  printf 'SP_AEON0_TITLE=a bead\nSP_AEON0_PRI=1\nSP_AEON0_SAID=running something\n'
  printf 'SP_NEXT_N=0\nSP_AWAITING_N=0\n'; } | snap
trail0="$(env -i PATH="$PATH" HOME="$PD/home" TERM=dumb LC_ALL=C.UTF-8 \
    SPIRA_CONF="$PD/no.conf" SPIRA_REPO="$PD/repo" SPIRA_RUN="$PD/repo/.runtime/spira" \
    SPIRA_COCKPIT_TRACE_LINES=0 \
    bash "$PANE" once 0 0 2>/dev/null | sed 's/\x1b\[[?0-9;]*[a-zA-Z]//g')"
is_n "N=0 is four rows (name + bead + act + said)" 4 "$(rows_of "$trail0" NOW)"
if grep -qF 'running something' <<< "$trail0"; then
    pass=$((pass+1)); printf '  ok    N=0 shows the SAID row\n'
else
    fail=$((fail+1)); printf '  FAIL  N=0 did not show SAID:\n%s\n' "$trail0"
fi

# THE SANITISER MAKES EVERY LINE SAFE FOR A SOURCED FILE. A trace with a newline inside a
# JSON value, an "=", and non-ASCII — each would break a KEY=value file the pane sources.
cat > "$TD/sp-dirty.log" <<'TRACE'
{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo foo=bar\nbaz"}}]}}
{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"résumé → done"}]}}
{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/tëst"}}]}}
TRACE
dirty="$(env -i PATH="$PATH" HOME="$TMP" LC_ALL=C.UTF-8 SPIRA_CONF="$TMP/no.conf" \
    bash -c '. "$1"/lib.sh; trace_tail "$2" 3' _ "$HERE" "$TD/sp-dirty.log" 2>/dev/null \
    | python3 -c '
import sys, re
ALLOW = re.compile(r"[^ A-Za-z0-9._/:,()#+-]")
n = int(sys.argv[1])
lines = []
for raw in sys.stdin:
    c = re.sub(r"\s+", " ", ALLOW.sub(" ", raw)).strip()[:96]
    if c:
        lines.append(c)
for j, l in enumerate(lines[-n:]):
    print("SP_AEON0_ACT%d=%s" % (j, l))
' 3 2>/dev/null)"
dk="$(sed -n 's/=.*//p' <<< "$dirty" | sort | tr '\n' ' ' | sed 's/ $//')"
is_n "dirty trace produces exactly 3 well-formed keys" "SP_AEON0_ACT0 SP_AEON0_ACT1 SP_AEON0_ACT2" "$dk"
if ( set -u; eval "$(python3 -c '
import sys
for line in sys.stdin:
    line = line.rstrip("\n")
    if "=" not in line: continue
    k, _, v = line.partition("=")
    print("%s=%s" % (k, "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27"))' <<< "$dirty")" ) 2>/dev/null; then
    pass=$((pass+1)); printf '  ok    sanitised trace output sources cleanly\n'
else
    fail=$((fail+1)); printf '  FAIL  sanitised output does not source:\n%s\n' "$dirty"
fi

# The same aeon with no trace to read. Every figure must be `?` — a `0` here is the panel
# saying all-clear about a session it cannot see at all.
{ printf 'SP_AEON_N=1\nSP_AEON0_NAME=valefor\nSP_AEON0_FAYTH=builder\nSP_AEON0_BEAD=sp-7xn\n'
  printf 'SP_AEON0_MIN=11\nSP_AEON0_TITLE=a bead\nSP_NEXT_N=0\nSP_AWAITING_N=0\n'; } | snap
dark="$(pane 0)"
for want in '? turns' 'ctx ?' '? files' 'quiet ?'; do
    if grep -qF "$want" <<< "$dark"; then
        pass=$((pass+1)); printf '  ok    an unreadable trace renders "%s"\n' "$want"
    else
        fail=$((fail+1)); printf '  FAIL  an unreadable trace did not render "%s":\n%s\n' "$want" "$dark"
    fi
done
case "$dark" in *'0 turns'*|*'0 files'*)
        fail=$((fail+1)); printf '  FAIL  an unreadable trace reported a zero:\n%s\n' "$dark" ;;
    *)  pass=$((pass+1)); printf '  ok    and never a zero\n' ;; esac
# ...and NOW is still a section, not an absence. The rows must be there to carry the `?`,
# and the quoted line is the only one that is dropped: there is nothing it could quote.
is_n "and NOW still renders its rows" 3 "$(rows_of "$dark" NOW)"

echo
echo "NEXT and RECENT stop at five, and the rows they give back go to NOW"

# THE PANE IS 200 ROWS TALL, WHICH IS THE POSITIVE CONTROL. A "5" measured in a pane that
# could only fit five would be the pane speaking, not the cap: at this height nothing but
# MAX_NEXT_ROWS and MAX_RECENT_ROWS can be what limits them
# (law-absence-needs-a-positive-control).
#
# COUNTED AS ITEMS, NOT AS LINES OF SECTION. NEXT spends a line of its own on its header, so
# five beads is six lines; RECENT puts the newest event on its header line, so five events is
# five. Both show five items, and it is the items the operator asked to cap.
{
    printf 'SP_AEON_N=3\n'
    for i in 0 1 2; do
        printf 'SP_AEON%d_NAME=aeon%d\nSP_AEON%d_FAYTH=builder\nSP_AEON%d_BEAD=sp-w%d\n' "$i" "$i" "$i" "$i" "$i"
        printf 'SP_AEON%d_MIN=5\nSP_AEON%d_ACT=doing a thing\nSP_AEON%d_TITLE=A worked bead\n' "$i" "$i" "$i"
        # THE SESSION FIGURES ARE PART OF THE FIXTURE, not an optional extra: without SAID
        # the section emits three rows per aeon and the height assertion below would be
        # measuring the OLD shape while passing.
        printf 'SP_AEON%d_TURNS=7\nSP_AEON%d_CTX=90000\nSP_AEON%d_TOOLS=19\n' "$i" "$i" "$i"
        printf 'SP_AEON%d_FILES=2\nSP_AEON%d_QUIET=30\nSP_AEON%d_SAID=thinking about it\n' "$i" "$i" "$i"
    done
    # FOURTEEN OF EACH, more than the cap and more than the collector would now emit. The
    # renderer has to hold the line on its own: a snapshot written by an older collector, or
    # by one whose cap was widened, must still render five.
    printf 'SP_NEXT_N=25\n'
    for i in $(seq 0 13); do printf 'SP_NEXT%d=P1 sp-n%d A queued bead\n' "$i" "$i"; done
    for i in $(seq 0 13); do printf 'SP_EVENT%d=%dm ago landed spira/sp-e%d\n' "$i" "$i" "$i"; done
    printf 'SP_AWAITING_N=0\n'
} | snap

tall="$(pane 200)"
# THE IDS THEMSELVES, NOT A COUNT OF LINES MATCHING A PATTERN. A count is the one assertion
# here that passes when the section renders NOTHING, and "no rows" and "five rows" are the
# two answers this is separating — the first draft of this counted `landed spira/sp-e0`,
# which the renderer pads to `landed    spira/sp-e0`, so it measured zero and the cap
# assertion beside it passed for the same wrong reason.
ids_of() { printf '%s\n' "$tall" | grep -o "$1" | tr '\n' ' ' | sed 's/ $//'; }
is_n "fourteen ready beads render as the five head NEXT rows" \
     "sp-n0 sp-n1 sp-n2 sp-n3 sp-n4" "$(ids_of 'sp-n[0-9]*')"
is_n "and fourteen events render as the five newest RECENT rows" \
     "sp-e0 sp-e1 sp-e2 sp-e3 sp-e4" "$(ids_of 'sp-e[0-9]*')"
# THE ROWS THE CAPS GAVE BACK GO TO NOW, which is the whole point of capping them: the
# section describing work in flight is the one that must not be trimmed, and it takes all
# twelve of its rows in a pane this tall. NOW is deliberately not held by the generic
# MAX_SECTION_ROWS — its want is four rows per LIVE AEON, a figure set by how many sessions
# are running, and capping it too would make the section that just got wider the first the
# allocator trims.
is_n "NOW takes all four rows of all three aeons in a tall pane" 12 "$(rows_of "$tall" NOW)"

# AT THE HEIGHT THE PANE ACTUALLY IS. 200 rows proves the cap is the cap; 45 proves the
# trade was worth making, and it is the only figure the operator can check by looking. All
# twelve NOW rows, five and five below them — which is the whole exchange this bead is:
# NEXT and RECENT gave up rows so the section describing work in flight could have them.
real="$(pane 45)"
is_n "a 45-row pane gives NOW all twelve of its rows" 12 "$(rows_of "$real" NOW)"
is_n "with NEXT still at five" 5 "$(printf '%s\n' "$real" | grep -c 'sp-n[0-9]')"
is_n "and RECENT still at five" 5 "$(printf '%s\n' "$real" | grep -c 'sp-e[0-9]')"

# AND THE CAPS ARE NOT WHAT KEEPS THE PANE HONEST WHEN IT IS SHORT. At twenty rows the
# sections still contend, so the round-robin must still ration NOW rather than let it take
# all twelve — otherwise CI, the last section in the order and the only place a bead parked
# since yesterday appears, is starved out of the pane entirely.
busy="$(pane 20)"
n_now="$(rows_of "$busy" NOW)"
if [ "$n_now" -ge 1 ] && [ "$n_now" -lt 12 ]; then
    pass=$((pass+1)); printf '  ok    a twelve-row NOW is held to %s rows in a 20-row pane\n' "$n_now"
else
    fail=$((fail+1)); printf '  FAIL  NOW took %s of its 12 rows — nothing was rationed\n' "$n_now"
fi
if grep -q '^ CI ' <<< "$busy"; then
    pass=$((pass+1)); printf '  ok    and CI still has its row\n'
else
    fail=$((fail+1)); printf '  FAIL  CI was starved out of a 20-row pane:\n%s\n' "$busy"
fi
is_n "a 20-row pane is filled to exactly 20 rows" 20 "$(printf '%s\n' "$busy" | wc -l)"

# THE PANE MUST NOT WRAP, AND THE NOW ROWS CARRY THE LONGEST STRINGS ON IT: an agent last
# shell command and its last sentence are the two fields here with no bound at all. Row
# three is also the only one that RIGHT-ALIGNS anything, so it is the only place a fit and a
# pad can disagree and push the line one column past the pane — and the terminal has
# autowrap off, so it would cut that silently.
{
    printf 'SP_AEON_N=1\nSP_AEON0_NAME=verywidename\nSP_AEON0_FAYTH=builder\n'
    printf 'SP_AEON0_BEAD=sp-longbead\nSP_AEON0_MIN=5\nSP_AEON0_TURNS=1234\n'
    printf 'SP_AEON0_CTX=987654\nSP_AEON0_TOOLS=456\nSP_AEON0_FILES=78\nSP_AEON0_QUIET=1500\n'
    printf 'SP_AEON0_TITLE=%s\n' "$(printf 't%.0s' $(seq 1 120))"
    printf 'SP_AEON0_ACT=Bash %s\n' "$(printf 'a%.0s' $(seq 1 120))"
    printf 'SP_AEON0_SAID=%s\n' "$(printf 's%.0s' $(seq 1 120))"
    printf 'SP_NEXT_N=1\nSP_NEXT0=P1 sp-longtitle %s\n' "$(printf 'x%.0s' $(seq 1 120))"
    printf 'SP_EVENT0=2m ago %s\n' "$(printf 'y%.0s' $(seq 1 120))"
    printf 'SP_AWAITING_N=0\n'
} | snap
# MEASURED IN CHARACTERS, WITH PYTHON, NOT WITH awk. The frame is full of multibyte
# characters and a suite run from a gate inherits the C locale, where awk counts BYTES — the
# ellipsis this very case is checking for is three bytes and one column, so the assertion
# would fail by exactly two on every line it cut, and blame the pane.
over_by() { python3 -c '
import sys
w = int(sys.argv[1])
print("\n".join("%d: %s" % (len(l), l) for l in sys.stdin.read().splitlines() if len(l) > w))' "$1"; }
for w in 70 96; do
    over="$(pane 40 "$w" | over_by "$w")"
    if [ -z "$over" ]; then
        pass=$((pass+1)); printf '  ok    every row fits %s columns\n' "$w"
    else
        fail=$((fail+1)); printf '  FAIL  a row ran past %s columns:\n%s\n' "$w" "$over"
    fi
done
fi

# ---------------------------------------------------------------------------------------
# THE MODEL THE SESSION IS ACTUALLY RUNNING. The personae no longer share one — Ops is on
# Sonnet, the builders on Opus 4.6 — so "which model produced this" stopped being a constant
# and started being a fact the pane has to carry.
#
# IT COMES FROM THE TRACE, NOT THE FAYTH FILE, and the negative case is the one that matters:
# a trace whose init names no model must render as `-`, never as whatever the fayth currently
# says. Those two disagree exactly when somebody edits a fayth while an aeon is mid-flight,
# which is the moment a wrong label would be believed.
# ---------------------------------------------------------------------------------------
is_n "an init with no model field is - , never a guess" "-" "$(field "$st" MODEL)"

cat > "$TD/sp-model.log" <<'TRACE'
{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-4-6"}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1},"content":[{"type":"text","text":"hi"}]}}
TRACE
is_n "the model is read from the init event" "claude-opus-4-6" \
     "$(field "$(stats "$TD/sp-model.log")" MODEL)"

# A TRACE THAT CANNOT BE READ AT ALL reports `?`, which is a different answer from `-`: one
# says the init carried no model, the other says nothing could be read. Folding them would
# make an unreadable trace indistinguishable from a readable one lacking a field
# (law-absence-needs-a-positive-control).
is_n "an unreadable trace is ? , not - and not a model" "?" \
     "$(field "$(stats "$TD/nonexistent.log")" MODEL)"

# model_short — what the pane actually prints. Extracted from the pane rather than
# reimplemented, so this cannot pass against a copy that has drifted from the real one.
eval "$(sed -n '/^model_short() {/,/^}/p' "$PANE")"
is_n "a dated id keeps its version and loses its date" "haiku 4.5"  "$(model_short claude-haiku-4-5-20251001)"
is_n "a two-part version reads as a version"           "opus 4.6"   "$(model_short claude-opus-4-6)"
is_n "a one-part version keeps its single number"      "sonnet 5"   "$(model_short claude-sonnet-5)"
is_n "an unknown id is printed as it came"             "weird-thing" "$(model_short weird-thing)"
is_n "? passes straight through"                       "?"          "$(model_short '?')"
is_n "- passes straight through"                       "-"          "$(model_short '-')"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
