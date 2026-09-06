#!/usr/bin/env bash
#
# test-archivist.sh — the watcher that notices a session filling up, and the state file it
# writes for the two things that render it.
#
#   ./test-archivist.sh
#
# WHAT THIS SUITE IS GUARDING. The expensive failure here is not a missed sweep, it is a
# CONFIDENT one: a state file saying "safe to clear" about a session the archivist did not
# actually read, on the strength of which the operator throws the work away. So the cases that
# matter most are the ones asserting that a verdict describes the turn it was computed at, that
# a failed run is never recorded as a safe one, and that a crossing fires once — because the
# second-most expensive failure is a watcher that summons a model session every five minutes
# for as long as a session stays full.
#
# EVERY CASE THAT CLAIMS SOMETHING IS ABSENT FIRST PROVES THE SAME PATH CAN FIND IT WHEN IT IS
# THERE (law-absence-needs-a-positive-control): a selector that excluded everything and one
# that excluded the right things look identical from the outside, and the wrong one reports a
# quiet keyboard.
#
# NO MODEL IS EVER RUN. SPIRA_CLAUDE is a stub script, which is the same seam aeon.sh uses and
# for the same reason: conf.sh replaces $PATH outright, so a fake `claude` placed first on PATH
# would run the real one against the operator's account, silently and at full cost.
#
# EVERY CONFIGURED VALUE IS PINNED TO A NON-DEFAULT, and the thresholds here are three-digit
# numbers nothing would arrive at by accident. Asserting against the shipped 200000 would pass
# just as well with the literal written back into the code, which is what the key exists to
# stop. It runs under `env -i` for the same reason: a suite inheriting a real spira.conf
# asserts about one box, and one inheriting SPIRA_TOKEN_PROJECTS reads somebody's actual work
# (law-gates-run-in-a-clean-environment).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
A="$HERE/archivist.sh"
CTX="$HERE/ctx-meter.sh"
SLCHECK="$HERE/statusline-check.py"
HEALTH="$(cd "$HERE/../cockpit" && pwd -P)/health.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1${2:+: $2}"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found [$3] in [$2]" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/home" "$T/run" "$T/projects" "$T/bin"

NONE="$T/no-such.conf"
CW=1500; CH=2500; CL=9000        # ctx warn / high / limit, far from the shipped defaults
IDLE=3600

# ---- the stub agent ----------------------------------------------------------------------
# It records that it ran, and — this is the part that matters — it calls back into
# archivist.sh's `mark` exactly as the real prompt tells the archivist to. So the callback is
# exercised by the suite rather than assumed to work from the other side of a model.
cat > "$T/bin/agent" <<'STUB'
#!/usr/bin/env bash
prompt="$(cat)"
printf '%s' "$prompt" > "$AGENT_PROMPT"
echo "ran" >> "$AGENT_RUNS"
[ -n "${AGENT_FILES:-}" ] && "$AGENT_SELF" mark "$AGENT_SID" archiving "$AGENT_FILES"
exit "${AGENT_RC:-0}"
STUB
chmod +x "$T/bin/agent"
cat > "$T/bin/notify" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOTIFY_LOG"
STUB
chmod +x "$T/bin/notify"

export AGENT_PROMPT="$T/prompt.txt" AGENT_RUNS="$T/runs.txt" NOTIFY_LOG="$T/notify.log"
export AGENT_SELF="$A" AGENT_SID="" AGENT_FILES="" AGENT_RC=0

run() {   # run <args...> — archivist.sh under the fixture's environment and nothing else
    env -i HOME="$T/home" PATH="$T/bin:$PATH" SPIRA_CONF="$NONE" \
        SPIRA_RUN="$T/run" SPIRA_TOKEN_PROJECTS="$T/projects" \
        SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH SPIRA_CTX_LIMIT=$CL \
        SPIRA_ARCHIVIST_AT="${AT:-high}" SPIRA_ARCHIVIST_IDLE=$IDLE \
        SPIRA_ARCHIVIST_TIMEOUT=60 SPIRA_CLAUDE="$T/bin/agent" SPIRA_NOTIFY="$T/bin/notify" \
        AGENT_PROMPT="$AGENT_PROMPT" AGENT_RUNS="$AGENT_RUNS" NOTIFY_LOG="$NOTIFY_LOG" \
        AGENT_SELF="$AGENT_SELF" AGENT_SID="$AGENT_SID" AGENT_FILES="$AGENT_FILES" \
        AGENT_RC="$AGENT_RC" \
        bash "$A" "$@" 2>&1
}
meter() { # meter <transcript> — the same reader the status line uses
    env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" \
        SPIRA_RUN="$T/run" SPIRA_TOKEN_PROJECTS="$T/projects" \
        SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH SPIRA_CTX_LIMIT=$CL \
        bash "$CTX" env "$1" 2>/dev/null
}
val() { sed -n "s/^$1=//p"; }
skey() { sed -n "s/^$2=//p" "$T/run/archivist/$1.state" 2>/dev/null; }

# session <dir> <name> <turns> <ctx-of-last-turn> [lineage-id] — a transcript the meter can
# measure. Growing context, so the last turn's usage is the number both the meter and the sweep
# act on. The lineage id is the field the client writes unchanged across a clear, and is what
# archive.sh chains a conversation on.
session() {
    local d="$T/projects/$1" n="$2" turns="$3" ctx="$4"
    mkdir -p "$d"
    python3 - "$d/$n.jsonl" "$turns" "$ctx" "${5:-}" <<'PY'
import json, os, sys
path, turns, ctx, bridge = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
# WRITTEN BESIDE AND RENAMED INTO PLACE, so re-describing a session gives it a new inode. A
# real transcript only ever grows, and the meter's incremental cursor is entitled to assume
# that: it resumes from a recorded offset whenever the path, the inode and a digest of the
# opening bytes all still match. Truncating this fixture in place keeps the inode and the
# opening bytes, so the meter would resume into a file that had been rewritten underneath it
# and report a context nobody was carrying — a defect in the fixture that would present as a
# defect in the sweep.
tmp = path + ".new"
with open(tmp, "w") as fh:
    for i in range(1, turns + 1):
        first = {"type": "user", "message": {"role": "user", "content": "please do step %d" % i}}
        if bridge and i == 1: first["bridgeSessionId"] = bridge
        fh.write(json.dumps(first) + "\n")
        # The last turn carries the target; the ones before it are a ramp, so growth is real.
        read = ctx if i == turns else ctx * i // (turns + 4)
        fh.write(json.dumps({"type": "assistant", "message": {
            "id": "m%d" % i, "role": "assistant",
            "content": [{"type": "text", "text": "step %d done" % i},
                        {"type": "tool_use", "name": "Bash",
                         "input": {"command": "git status -s"}}],
            "usage": {"input_tokens": 0, "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": read, "output_tokens": 1}}}) + "\n")
        fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "content": "SECRETLY ENORMOUS TOOL OUTPUT " * 40}]}}) + "\n")
os.replace(tmp, path)
PY
}
reset() { rm -rf "$T/run/archivist" "$AGENT_RUNS" "$NOTIFY_LOG" "$AGENT_PROMPT"; }
runs()  { [ -s "$AGENT_RUNS" ] && wc -l < "$AGENT_RUNS" | tr -d ' '; }

# ==========================================================================================
echo
echo "which sessions the sweep can even see"
# ==========================================================================================
# THE POSITIVE CONTROL FIRST. Every exclusion below is asserted as an absence, and an absence
# means nothing until this same code path has been seen to find something.
session -a-project live 30 3000
L="$(run list)"
has "a live session is listed"      "$L" "live"
has "with the context it is carrying" "$L" "3000"

# STALE: everything this rescues is rescued so the session can be cleared, which only matters
# while somebody is still in it.
session -a-project old 30 3000
touch -d '3 hours ago' "$T/projects/-a-project/old.jsonl"
L="$(run list)"
hasnt "a transcript untouched for longer than the idle window is not live" "$L" "old"
has   "while the live one beside it still is"                              "$L" "live"

# EMPTY: a session that has not spoken has nothing to rescue.
: > "$T/projects/-a-project/empty.jsonl"
hasnt "an empty transcript is not a session" "$(run list)" "empty"

# THE HARNESS'S OWN. An aeon's unfinished business is its BEAD, and the archivist's own session
# must be excluded by the same rule or the sweep eventually archives the archivist. The
# exclusion is derived from the runtime directory, so the fixture's own runtime path is what
# makes this case real rather than a literal somebody could delete.
ours="$(python3 -c 'import re,sys,os;print(re.sub(r"[^A-Za-z0-9]","-",os.path.realpath(sys.argv[1])))' "$T/run")"
session "$ours-worktree-sp-xyz" aeon 30 9999
L="$(run list)"
hasnt "a transcript written from inside the runtime directory is the harness's own" "$L" "aeon"
hasnt "and its context is not reported as a live session's"                         "$L" "9999"

# ==========================================================================================
echo
echo "the bands, and firing once per crossing"
# ==========================================================================================
reset
session -a-project live 30 2000          # past warn (1500), below high (2500)
L="$(run list)"
has "a session below the trigger band is held" "$L" "hold"
run sweep >/dev/null
is  "and no archivist is summoned for it" "" "$(runs)"

# The positive control for that hold: raise the context past the trigger and the same session
# is acted on. Without this, a sweep that could never summon anything would pass the case above.
session -a-project live 30 3000           # past high
AGENT_SID=live AGENT_FILES=4 run sweep >/dev/null
is "crossing the configured band summons the archivist" "1" "$(runs)"
is "and the crossing is recorded"                       "2" "$(sed -n 's/^band=//p' "$T/run/archivist/live.hwm")"

run sweep >/dev/null
is "a second pass over the same crossing summons nothing" "1" "$(runs)"

# A DEEPER BAND IS A NEW CROSSING. The turns since the last sweep are the ones nobody has
# persisted, so a session that goes on growing genuinely does need looking at again.
session -a-project live 30 9999           # past the limit
AGENT_SID=live AGENT_FILES=4 run sweep >/dev/null
is "crossing a deeper band summons it again" "2" "$(runs)"

# THE TRIGGER IS CONFIGURATION. Pinning it to `limit` must move the verdict, or the band is a
# literal in the code and the key is decoration.
reset
session -a-project live 30 3000           # past high, below limit
AT=limit run sweep >/dev/null
is "a trigger of limit does not fire at high" "" "$(runs)"
AT=warn AGENT_SID=live AGENT_FILES=1 run sweep >/dev/null
is "and a trigger of warn does"             "1" "$(runs)"

# A BAND THAT DOES NOT EXIST IS REFUSED, LOUDLY. A watcher configured to fire at a threshold
# nothing defines reports nothing forever, and looks exactly like one with nothing to report.
out="$(AT=enormous run sweep)"; rc=$?
is  "an unrecognised trigger band exits non-zero" "1" "$rc"
has "and says which key is wrong"                 "$out" "SPIRA_ARCHIVIST_AT"

# ==========================================================================================
echo
echo "the state file — the contract with the status line and the dashboard"
# ==========================================================================================
reset
session -a-project live 30 3000
AGENT_SID=live AGENT_FILES=6 run sweep >/dev/null
is "a completed archive is safe"         "safe" "$(skey live state)"
is "at the turn the transcript was read" "30"   "$(skey live at_turn)"
is "carrying the count the run itself reported" "6" "$(skey live items_filed)"

# THE COUNT COMES FROM THE RUN'S OWN CALLBACK, not from parsing its output. A run that filed
# nothing must read as zero, and a run that filed six must not — those are the two readings
# the operator is deciding between.
reset
session -a-project live 30 3000
AGENT_SID=live AGENT_FILES="" run sweep >/dev/null
is "a run that filed nothing says zero, and is still safe" "safe" "$(skey live state)"
is "with nothing claimed"                                   "0"    "$(skey live items_filed)"

# A FAILED RUN IS NEVER A SAFE ONE. This is the case the whole suite exists for: the operator
# clears on this verdict.
reset
session -a-project live 30 3000
AGENT_SID=live AGENT_RC=7 run sweep >/dev/null
is "a run that exited non-zero is recorded as failed" "failed" "$(skey live state)"

# SWEEPING IS WRITTEN BEFORE THE RUN, NOT AFTER IT. A long sweep showing nothing is
# indistinguishable from an archivist that never ran. The stub reads the file it was started
# under, which is the only way to observe a state that is replaced moments later.
reset
session -a-project live 30 3000
cat > "$T/bin/agent2" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sed -n 's/^state=//p' "$SPIRA_RUN/archivist/live.state" > "$AGENT_PROMPT"
STUB
chmod +x "$T/bin/agent2"
env -i HOME="$T/home" PATH="$T/bin:$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
    SPIRA_TOKEN_PROJECTS="$T/projects" SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH \
    SPIRA_CTX_LIMIT=$CL SPIRA_ARCHIVIST_AT=high SPIRA_ARCHIVIST_IDLE=$IDLE \
    SPIRA_ARCHIVIST_TIMEOUT=60 SPIRA_CLAUDE="$T/bin/agent2" AGENT_PROMPT="$AGENT_PROMPT" \
    bash "$A" sweep >/dev/null 2>&1
is "the run sees itself as sweeping while it works" "sweeping" "$(cat "$AGENT_PROMPT")"

# ==========================================================================================
echo
echo "what the two readers do with it"
# ==========================================================================================
# ONE MEASUREMENT, THREE READERS. The sweep acts on ctx-meter's numbers and the status line and
# the dashboard render ctx-meter's numbers, so a state written here must arrive intact at both
# — otherwise the operator is reading one thing while the watcher acted on another.
reset
session -a-project live 30 3000
AGENT_SID=live AGENT_FILES=6 run sweep >/dev/null
E="$(meter "$T/projects/-a-project/live.jsonl")"
is "the meter reads the state the archivist wrote"  "safe" "$(val SP_CTX_ARCHIVIST <<<"$E")"
is "and how much it rescued"                        "6"    "$(val SP_CTX_ARCHIVIST_FILED <<<"$E")"
is "a verdict computed at the current turn is fresh" "0"   "$(val SP_CTX_ARCHIVIST_BEHIND <<<"$E")"

# A VERDICT THAT CANNOT GO STALE IS A VERDICT THAT WILL EVENTUALLY LIE. "Safe to clear" is a
# statement about the session as the archivist saw it; forty turns later it describes a session
# that no longer exists, and acting on it discards everything said since.
printf 'state=safe\nat_turn=5\nitems_filed=6\n' > "$T/run/archivist/live.state"
E="$(meter "$T/projects/-a-project/live.jsonl")"
is "a verdict from earlier in the session is reported with its age" "25" \
   "$(val SP_CTX_ARCHIVIST_BEHIND <<<"$E")"

# THE DASHBOARD SAYS HOW MANY. "Safe to clear" alone cannot tell a session with nothing left to
# save from one whose six loose ends are now beads, which are the two readings being chosen
# between.
{ echo "SP_CTX_NOW='3000'"; echo "SP_CTX_TURNS='30'"; echo "SP_CTX_NEXT='limit'"
  echo "SP_CTX_HEADROOM='6000'"; echo "SP_CTX_TURNS_LEFT='-'"; echo "SP_CTX_AGE='3'"
  echo "SP_CTX_ARCHIVIST='safe'"; echo "SP_CTX_ARCHIVIST_BEHIND='0'"
  echo "SP_CTX_ARCHIVIST_FILED='6'"; } > "$T/run/cockpit.env"
F="$(env -i HOME="$T/home" PATH="$PATH" TERM=dumb LC_ALL=C.UTF-8 SPIRA_CONF="$NONE" \
     SPIRA_REPO="$T" SPIRA_RUN="$T/run" bash "$HEALTH" once 0 100 2>/dev/null \
     | sed 's/\x1b\[[?0-9;]*[a-zA-Z]//g')"
has "the dashboard says the session is safe to clear" "$F" "safe to clear"
has "and how many items that verdict rests on"        "$F" "(6 filed)"

# ==========================================================================================
echo
echo "reading the transcript without spending what it is trying to save"
# ==========================================================================================
# THE DIGEST IS THE WHOLE COST STORY. An archivist that read the raw transcript would spend
# more context rescuing the session than the session was carrying, which would make it the
# problem it was summoned to fix.
D="$(run digest "$T/projects/-a-project/live.jsonl" 0)"
has   "the operator's messages are kept"  "$D" "please do step 7"
has   "and one line per tool call"        "$D" "· Bash git status -s"
hasnt "tool results are dropped"          "$D" "SECRETLY ENORMOUS"
raw=$(wc -c < "$T/projects/-a-project/live.jsonl")
small=$(printf '%s' "$D" | wc -c)
[ "$small" -lt $(( raw / 4 )) ] && ok "the digest is a fraction of the transcript" \
    || bad "the digest is a fraction of the transcript" "$small vs $raw bytes"
has "--full brings the results back when they are wanted" \
    "$(run digest "$T/projects/-a-project/live.jsonl" 0 --full)" "SECRETLY ENORMOUS"

# A PROMPT IS NUMBERED FOR THE TURN IT PRODUCES. Read literally it lands one turn early, and at
# the covered mark that is the difference between resuming at the operator's instruction and
# resuming at the answer to it, having dropped the instruction.
D="$(run digest "$T/projects/-a-project/live.jsonl" 20)"
has   "resuming at a turn keeps that turn's instruction" "$D" "please do step 20"
hasnt "and nothing from before it"                       "$D" "please do step 19"

# ==========================================================================================
echo
echo "not filing the same thing twice"
# ==========================================================================================
# A session archived at `high` and again at `limit` is read twice over a transcript whose first
# half is the same both times. The same question filed twice is how one reply comes to close two
# asks and record a verdict nobody gave.
reset
session -a-project live 30 3000
AGENT_SID=live AGENT_FILES=2 run sweep >/dev/null
has "the first pass is told it is the first" "$(cat "$AGENT_PROMPT")" "up to turn 0"
session -a-project live 40 9999
AGENT_SID=live AGENT_FILES=2 run sweep >/dev/null
has "the next pass is told where the last one stopped" "$(cat "$AGENT_PROMPT")" "up to turn 30"

# A FAILED PASS COVERED NOTHING, whatever it read. Advancing the mark on a failure would leave
# the turns it did not manage to file permanently behind the cursor.
reset
session -a-project live 30 3000
AGENT_SID=live AGENT_RC=3 run sweep >/dev/null
session -a-project live 40 9999
AGENT_SID=live AGENT_FILES=1 run sweep >/dev/null
has "a pass after a failure starts again from the beginning" "$(cat "$AGENT_PROMPT")" "up to turn 0"

# ==========================================================================================
echo
echo "the run's own progress writes"
# ==========================================================================================
reset
session -a-project live 30 3000
AGENT_SID=live AGENT_FILES=2 run sweep >/dev/null
out="$(run mark live nonsense 1)"; rc=$?
is  "an unknown state is refused" "1" "$rc"
has "and named"                    "$out" "nonsense"
out="$(run mark never-swept archiving 1)"; rc=$?
is  "marking a session with no run in progress is refused" "1" "$rc"
# AT_TURN IS NEVER INVENTED. A fabricated zero would make every later verdict read as computed
# at turn zero — which renders either as a very stale "safe" or, worse, as a fresh one.
has "because there is no turn to attribute it to" "$out" "no archivist run in progress"

# ==========================================================================================
echo
echo "the one push, and the sessions that are gone"
# ==========================================================================================
# Everything below the top band is already delivered by the two readers at no cost. A notice on
# every archive would put one in front of the operator on every long session, and a standing
# list that never changes becomes wallpaper (law-alerts-must-be-actionable).
reset
session -a-project live 30 3000            # past high, below limit
AGENT_SID=live AGENT_FILES=3 run sweep >/dev/null
is "crossing the middle band sends nothing" "" "$(cat "$NOTIFY_LOG" 2>/dev/null)"

session -a-project live 40 9999            # past the limit
AGENT_SID=live AGENT_FILES=3 run sweep >/dev/null
has "past the ceiling it says so once"  "$(cat "$NOTIFY_LOG")" "safe to clear"
has "and how much is riding on it"      "$(cat "$NOTIFY_LOG")" "3 item(s)"
n="$(wc -l < "$NOTIFY_LOG")"
rm -f "$T/run/archivist/live.hwm"
session -a-project live 50 9999
AGENT_SID=live AGENT_FILES=3 run sweep >/dev/null
is "and never again for that session" "$n" "$(wc -l < "$NOTIFY_LOG")"

# NOTHING RESCUED IS NOTHING TO SAY. A session with no loose ends is a real and common outcome.
reset
session -another quiet 30 9999
AGENT_SID=quiet AGENT_FILES="" run sweep >/dev/null
is "an archive that filed nothing sends nothing" "" "$(cat "$NOTIFY_LOG" 2>/dev/null)"

# STATE IS TIED TO THE TRANSCRIPT, not to a clock: while the client still holds the transcript
# the state is still the truth about it, and once it is gone there is no session to describe.
is "state is kept while the transcript exists" "safe" "$(skey quiet state)"
rm -f "$T/projects/-another/quiet.jsonl"
run sweep >/dev/null
is "and forgotten with it" "" "$(skey quiet state)"

# ==========================================================================================
echo
echo "the status line the operator reads it all through"
# ==========================================================================================
# NOTHING THE HARNESS SHIPS CAN SET THIS — it lives in the client's settings, outside every
# repository — so what the harness owes is to say when it is wrong.
S="$T/settings.json"
sl() { python3 "$SLCHECK" "$S" /opt/spira/ctx-meter.sh; }
printf 'not json at all' > "$S"
has "a settings file that will not parse says so" "$(sl)" "unreadable"
printf '{}\n' > "$S"
is  "no status line at all is its own answer" "absent" "$(sl)"
printf '{"statusLine":{"type":"command","command":"/usr/bin/other"}}\n' > "$S"
has "a status line running something else is named as such" "$(sl)" "other"
printf '{"statusLine":{"type":"command","command":"bash /opt/spira/ctx-meter.sh"}}\n' > "$S"
is "the meter with no refresh interval is the finding this check exists for" "ours -" "$(sl)"
printf '{"statusLine":{"type":"command","command":"bash /opt/spira/ctx-meter.sh","refreshInterval":5}}\n' > "$S"
is "and a configured one is reported with its value" "ours 5" "$(sl)"
# A BOOLEAN WOULD PASS AN isinstance CHECK FOR int, and is a plausible thing to type. It would
# report as a configured timer the client does not honour.
printf '{"statusLine":{"type":"command","command":"bash /opt/spira/ctx-meter.sh","refreshInterval":true}}\n' > "$S"
is "a true is not an interval" "ours -" "$(sl)"

# ==========================================================================================
echo
echo "what came before the transcript"
# ==========================================================================================
# Clearing starts a new transcript with a new session id, so the log in front of the archivist
# is only the tail of the conversation. archive.sh indexes the lineage id the client carries
# across those clears, and asking it is what stops this and the manual salvage path forming
# different views of what one conversation is.
#
# THE REAL ARCHIVE, on a throwaway root, rather than a stub of it: a hand-written model of a
# dependency reproduces the surface you remember, and its gaps show up as failures in correct
# code (law-prefer-the-real-dependency).
reset
rm -rf "$T/archive"
session -a-project older 12 900  chain-42
session -a-project live  30 3000 chain-42
touch -d '2 hours ago' "$T/projects/-a-project/older.jsonl"
env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
    SPIRA_TOKEN_PROJECTS="$T/projects" SPIRA_ARCHIVE="$T/archive" \
    bash "$HERE/archive.sh" sweep >/dev/null 2>&1
arc_rc=$?
if [ "$arc_rc" -ne 0 ]; then
    echo "  skip — archive.sh could not sweep (rc=$arc_rc); the lineage cases need it"
else
    env -i HOME="$T/home" PATH="$T/bin:$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
        SPIRA_TOKEN_PROJECTS="$T/projects" SPIRA_ARCHIVE="$T/archive" \
        SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH SPIRA_CTX_LIMIT=$CL SPIRA_ARCHIVIST_AT=high \
        SPIRA_ARCHIVIST_IDLE=$IDLE SPIRA_ARCHIVIST_TIMEOUT=60 SPIRA_CLAUDE="$T/bin/agent" \
        SPIRA_NOTIFY="$T/bin/notify" AGENT_PROMPT="$AGENT_PROMPT" AGENT_RUNS="$AGENT_RUNS" \
        NOTIFY_LOG="$NOTIFY_LOG" AGENT_SELF="$AGENT_SELF" AGENT_SID=live AGENT_FILES=1 \
        AGENT_RC=0 bash "$A" sweep >/dev/null 2>&1
    P="$(cat "$AGENT_PROMPT" 2>/dev/null)"
    has   "an earlier transcript in the same conversation is named"  "$P" "older.jsonl"
    hasnt "and the one being swept is not listed as its own history" "$P" "    $T/projects/-a-project/live.jsonl"
    has   "which makes it legible as a continuation"                 "$P" "continuation"
fi

# THE NEGATIVE, which needs the positive above to mean anything: a session belonging to no
# chain says so, rather than saying nothing.
reset
session -another alone 30 3000
AGENT_SID=alone AGENT_FILES=1 run sweep >/dev/null
has "a session with no earlier transcript is told the chain is one" \
    "$(cat "$AGENT_PROMPT")" "chain of one"

# ==========================================================================================
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
