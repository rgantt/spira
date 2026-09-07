#!/usr/bin/env bash
#
# test-tokens.sh — the token meter, the live-context meter, and the series they feed.
#
#   ./test-tokens.sh
#
# WHAT THIS SUITE IS GUARDING. The instrument reports on the constraint that stops all other
# work, so its expensive failure is not a missing number but a confident wrong one: a token
# panel showing zero spend looks like good news, and good news displaces the suspicion that
# would have prompted a look. So every case that claims something is absent first proves the
# same code path can find it when it IS there (law-absence-needs-a-positive-control), and the
# `-`/`?`/0 distinction is asserted directly rather than assumed.
#
# EVERY CONFIGURED VALUE IS PINNED TO A NON-DEFAULT. Asserting a 5-hour window against the
# shipped 5 would pass just as well with the literal written back into the code, which is
# precisely what the key exists to stop. The window here is 3 hours and the context thresholds
# are three-digit numbers nothing would arrive at by accident.
#
# AND IT RUNS UNDER `env -i`. A suite that inherits the operator's spira.conf asserts against
# one box, and one that inherits SPIRA_TOKEN_PROJECTS would read their real transcripts —
# thousands of turns of someone's actual work, against fixtures expecting four
# (law-gates-run-in-a-clean-environment).
#
# covers: spira/ctx-meter.sh spira/tokens.sh spira/cockpit.sh spira/statusline-check.py cockpit/health.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
TOKENS="$HERE/tokens.sh"
CTX="$HERE/ctx-meter.sh"
COCKPIT="$HERE/cockpit.sh"
HEALTH="$(cd "$HERE/../cockpit" && pwd -P)/health.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1${2:+: $2}"; }
is()  { # is <name> <want> <got>
    [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"
}
has() { # has <name> <haystack> <needle>
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in [$2]" ;; esac
}
hasnt() { # hasnt <name> <haystack> <needle>
    case "$2" in *"$3"*) bad "$1" "found [$3] in [$2]" ;; *) ok "$1" ;; esac
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/home" "$T/run" "$T/projects/-a-project" "$T/projects/-another"

# The three fixture knobs, all non-default. NONE points the config reader at a path that does
# not exist, which is how it is told to read no file at all — otherwise it would find the
# operator's own and this suite would assert against their box.
NONE="$T/no-such.conf"
WINDOW_H=3
CW=900; CH=1800; CL=2700          # ctx warn / high / limit, pinned well away from the defaults

# run <script> [args...] — under a minimal environment carrying only the fixture's settings.
run() {
    local s="$1"; shift
    env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" \
        SPIRA_RUN="$T/run" SPIRA_TOKEN_PROJECTS="$T/projects" \
        SPIRA_TOKEN_WINDOW_H="$WINDOW_H" \
        SPIRA_CTX_WARN="$CW" SPIRA_CTX_HIGH="$CH" SPIRA_CTX_LIMIT="$CL" \
        bash "$s" "$@" 2>/dev/null
}
val() { sed -n "s/^$1=//p"; }        # pull one key out of a key=value block

# turn <id> <hours-ago> <in> <cachecreate> <cacheread> <out> -> one transcript line
turn() {
    local when; when="$(date -u -d "$2 hours ago" +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
        "$when" "$1" "$3" "$4" "$5" "$6"
}

# ==========================================================================================
echo
echo "tokens.sh env — the window, and which half of the system filled it"
# ==========================================================================================
# One aeon turn and one session turn INSIDE the window, and one of each outside it. The pair
# outside is the positive control for the window filter: without them, a filter that excluded
# everything and a filter that excluded nothing would produce the same verdict here.
turn a1 1 100 200 3000 50   > "$T/run/aeon-one.log"
turn a2 9 111 222 9999 99  >> "$T/run/aeon-one.log"
turn s1 1 400 600 7000 80   > "$T/projects/-a-project/sess.jsonl"
turn s2 9 111 222 9999 99  >> "$T/projects/-a-project/sess.jsonl"

E="$(run "$TOKENS" env)"
is "the window comes from configuration, not a literal" "$WINDOW_H" "$(val SP_TOK_WINDOW_H <<<"$E")"
# 100 + 200 + 3000 + 50. Everything the request carried, cache reads included — that is what
# a rate limit meters, and counting output alone understates it by two orders of magnitude.
is "an aeon turn inside the window is billed in full"  "3350" "$(val SP_TOK_AEON_WIN <<<"$E")"
is "a session turn inside the window is billed in full" "8080" "$(val SP_TOK_SESS_WIN <<<"$E")"
is "and the total is the two halves"                  "11430" "$(val SP_TOK_WIN <<<"$E")"
# THE POSITIVE CONTROL, read the other way: the turns nine hours old are excluded, and the
# lines above prove the reader could see them if the cutoff had let it.
is "a turn outside the window is excluded (aeons)"        "1" "$(val SP_TOK_AEON_TURNS <<<"$E")"
is "a turn outside the window is excluded (session)"      "1" "$(val SP_TOK_SESS_TURNS <<<"$E")"
is "context per turn is the cache re-read, not the output" "3000" "$(val SP_TOK_AEON_CTX <<<"$E")"
is "and the same for the session half"                 "7000" "$(val SP_TOK_SESS_CTX <<<"$E")"

# A WIDER WINDOW MUST SEE MORE. This is the second half of the same control: if the window
# were being ignored, both runs would agree.
E9="$(WINDOW_H=12 run "$TOKENS" env)"
is "widening the window admits the older turns" "2" "$(val SP_TOK_AEON_TURNS <<<"$E9")"

# DEDUPE BY MESSAGE ID, ACROSS FILES. A resumed session copies earlier turns into a new
# transcript, and counting per file inflated the real corpus by 11,600 turns.
cp "$T/projects/-a-project/sess.jsonl" "$T/projects/-another/resumed.jsonl"
E="$(run "$TOKENS" env)"
is "a turn copied into a second transcript is billed once" "1" "$(val SP_TOK_SESS_TURNS <<<"$E")"
rm -f "$T/projects/-another/resumed.jsonl"

# AN AEON TRACE IS STREAM-JSON AND CARRIES MORE THAN ASSISTANT TURNS. A user echo with a
# usage block would double-count the same work against the harness's half.
printf '{"type":"user","timestamp":"%s","message":{"id":"u1","usage":{"input_tokens":5000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$T/run/aeon-one.log"
E="$(run "$TOKENS" env)"
is "a non-assistant line in an aeon trace is not billed" "3350" "$(val SP_TOK_AEON_WIN <<<"$E")"

# NOTHING TO READ IS ZERO SPEND, AND IT IS ALSO THE STATE A MISCONFIGURED PATH PRODUCES. It is
# reported as zero here on purpose — the counter genuinely counted, and found nothing — which
# is why the pane never derives "healthy" from it and why SPIRA_TOKEN_PROJECTS is a config key
# rather than a guess: the guess is what turns a moved directory into silent good news.
E0="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" \
      SPIRA_RUN="$T/empty" SPIRA_TOKEN_PROJECTS="$T/empty" \
      SPIRA_TOKEN_WINDOW_H="$WINDOW_H" bash "$TOKENS" env 2>/dev/null)"
is "an empty corpus counts zero rather than failing" "0" "$(val SP_TOK_WIN <<<"$E0")"

# EVERY KEY THE PANE READS MUST BE EMITTED. A key the collector never writes reads as unset,
# and the pane renders `?` for it forever while the collector looks perfectly healthy.
missing=""
for k in SP_TOK_WINDOW_H SP_TOK_AEON_WIN SP_TOK_SESS_WIN SP_TOK_WIN SP_TOK_AEON_TURNS \
         SP_TOK_SESS_TURNS SP_TOK_AEON_CTX SP_TOK_SESS_CTX SP_TOK_AEON_OUT SP_TOK_SESS_OUT; do
    grep -q "^$k=" <<<"$E" || missing="$missing $k"
done
is "every key the pane reads is emitted" "" "$missing"

# ==========================================================================================
echo
echo "ctx-meter.sh env — the live session, and how close it is to the edge"
# ==========================================================================================
# Twenty-one turns climbing by 100 each, so the growth rate is a fact rather than a guess:
# the meter averages over the last twenty, which is the shortest span that is not noise.
: > "$T/projects/-a-project/live.jsonl"
for i in $(seq 0 20); do
    turn "m$i" 0 0 0 $(( 1000 + i * 100 )) 10 >> "$T/projects/-a-project/live.jsonl"
done

C="$(run "$CTX" env)"
is "context carried is the last turn's, not the sum"  "3000" "$(val SP_CTX_NOW <<<"$C")"
is "turns are counted"                                  "21" "$(val SP_CTX_TURNS <<<"$C")"
is "growth is measured over the last twenty turns"     "100" "$(val SP_CTX_GROWTH <<<"$C")"
# THE NEXT THRESHOLD, NOT THE CEILING. At 3000 with warn 900 and high 1800 both behind it, the
# thing that happens next is the limit at 2700 — which is already past, so it says so.
is "past every threshold is named as such"            "over" "$(val SP_CTX_NEXT <<<"$C")"

# Back inside the bands, where the headroom is the number the operator acts on.
turn m99 0 0 0 1200 10 > "$T/projects/-a-project/live.jsonl"
C="$(run "$CTX" env)"
is "the next threshold above the current context wins" "high" "$(val SP_CTX_NEXT <<<"$C")"
is "headroom is measured to that threshold"             "600" "$(val SP_CTX_HEADROOM <<<"$C")"
# A single turn cannot establish a rate, and inventing one would put a number where there is
# no measurement — "34 turns to warn" is a claim, and a false one is worse than a dash.
is "turns-to-threshold is withheld without a growth rate" "-" "$(val SP_CTX_TURNS_LEFT <<<"$C")"

# THE THRESHOLDS ARE CONFIGURATION. Moving them must move the verdict, or the code is reading
# its own literals and the keys are decoration.
C="$(CW=1300 CH=2600 CL=3900 run "$CTX" env)"
is "raising the thresholds moves the verdict" "warn" "$(val SP_CTX_NEXT <<<"$C")"
is "and moves the headroom with it"           "100"  "$(val SP_CTX_HEADROOM <<<"$C")"

# THE NEWEST TRANSCRIPT IS THE LIVE ONE. With no status-line hook there is nothing else to go
# on, and picking any fixed project would report a session that ended yesterday as live.
turn old1 0 0 0 500 10 > "$T/projects/-another/stale.jsonl"
touch -d '2 hours ago' "$T/projects/-another/stale.jsonl"
C="$(run "$CTX" env)"
is "the newest transcript is the one measured" "1200" "$(val SP_CTX_NOW <<<"$C")"
touch "$T/projects/-another/stale.jsonl"
C="$(run "$CTX" env)"
is "and it follows when a different one is written" "500" "$(val SP_CTX_NOW <<<"$C")"
rm -f "$T/projects/-another/stale.jsonl"

# ITS AGE IS PUBLISHED, so the pane can say "idle 40m" instead of presenting a dead session's
# context as the live one. In a directory of its own, because "the newest transcript" is the
# selection rule and a fresher fixture elsewhere would be the one measured.
mkdir -p "$T/aged/-a-project"
turn aged 0 0 0 1200 10 > "$T/aged/-a-project/live.jsonl"
touch -d '40 minutes ago' "$T/aged/-a-project/live.jsonl"
age="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
       SPIRA_TOKEN_PROJECTS="$T/aged" SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH \
       SPIRA_CTX_LIMIT=$CL bash "$CTX" env 2>/dev/null | val SP_CTX_AGE)"
[ "${age:-0}" -ge 2340 ] 2>/dev/null && ok "the transcript's age is reported" \
                                     || bad "the transcript's age is reported" "got [$age]"

# NO SESSION IS `-`, NEVER 0. Zero context is the best possible news and would be read as one.
mkdir -p "$T/nosessions"
C="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
     SPIRA_TOKEN_PROJECTS="$T/nosessions" SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH \
     SPIRA_CTX_LIMIT=$CL bash "$CTX" env 2>/dev/null)"
is "no session reads as a dash"      "-" "$(val SP_CTX_NOW <<<"$C")"
hasnt "and never as a zero context" "$C" "SP_CTX_NOW=0"

# THE ARCHIVIST'S STATE IS READ FROM THE RUNTIME DIRECTORY, which is where it writes. The
# meter used to look it up in an environment variable that conf.sh deliberately does not
# export, so the lookup could never resolve and every session read as "not archived".
sid="$(basename "$T/projects/-a-project/live.jsonl" .jsonl)"
mkdir -p "$T/run/archivist"
printf 'state=safe\nat_turn=1\nitems_filed=4\n' > "$T/run/archivist/$sid.state"
C="$(run "$CTX" env)"
is "the archivist's state is found under the runtime directory" "safe" "$(val SP_CTX_ARCHIVIST <<<"$C")"
rm -rf "$T/run/archivist"
C="$(run "$CTX" env)"
is "and its absence is a state of its own, not a failure" "none" "$(val SP_CTX_ARCHIVIST <<<"$C")"

# THE STATUS LINE STILL WORKS. It is the same program and the same measurement, and a change
# made for the pane must not silently break the half that runs on every keystroke.
line="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
        SPIRA_TOKEN_PROJECTS="$T/projects" SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH \
        SPIRA_CTX_LIMIT=$CL bash "$CTX" \
        <<<"{\"transcript_path\":\"$T/projects/-a-project/live.jsonl\"}" 2>/dev/null)"
has "the status line still renders a measurement" "$line" "ctx 1k"
line="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
        SPIRA_TOKEN_PROJECTS="$T/projects" bash "$CTX" <<<'{"cwd":"/nowhere/at/all"}' 2>/dev/null)"
has "and a transcript it cannot find renders ?" "$line" "ctx ?"

# ==========================================================================================
echo
echo "ctx-meter.sh line — the headline comes from the client, not from the transcript"
# ==========================================================================================
# hook <session-id> <transcript-path> [total_input_tokens] [window] [used_percentage]
# With the last three omitted the blob carries context_window.current_usage = null, which is
# what the client sends before a session's first API response.
# CWD IS THE FIXTURE'S REAL WORKING DIRECTORY, not a placeholder. The newest-by-mtime fallback
# resolves <projects>/<slug of cwd>/, so a cwd that slugs to nothing means the fallback finds
# nothing — and a test where the fallback CANNOT fire proves nothing about it being gated.
# /two/sessions slugs to -two-sessions, which is where these fixtures live.
hook() {
    if [ $# -ge 5 ]; then
        printf '{"session_id":"%s","transcript_path":"%s","cwd":"/two/sessions","context_window":{"total_input_tokens":%s,"context_window_size":%s,"current_usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1},"used_percentage":%s}}' \
            "$1" "$2" "$3" "$4" "$5"
    else
        printf '{"session_id":"%s","transcript_path":"%s","cwd":"/two/sessions","context_window":{"total_input_tokens":0,"context_window_size":%s,"current_usage":null,"used_percentage":null}}' \
            "$1" "$2" "${3:-200000}"
    fi
}
# line <hook-json> — the status line, under the same minimal environment as `run`.
line() {
    env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" \
        SPIRA_RUN="$T/run" SPIRA_TOKEN_PROJECTS="$T/projects" \
        SPIRA_TOKEN_WINDOW_H="$WINDOW_H" \
        SPIRA_CTX_WARN="$CW" SPIRA_CTX_HIGH="$CH" SPIRA_CTX_LIMIT="$CL" \
        bash "$CTX" <<<"$1" 2>/dev/null
}

# A DIRECTORY WITH TWO SESSIONS IN IT, which is the whole hazard: one working directory can
# host more than one agent, and they share a project slug. `mine` carries 2200; `other` is
# written afterwards so it is unambiguously the newest by mtime and carries 7000 — a number the
# meter must never print while the hook is naming `mine`.
P="$T/projects/-two-sessions"; mkdir -p "$P"
: > "$P/mine.jsonl"
for i in $(seq 0 20); do turn "n$i" 0 0 0 $(( 2000 + i * 10 )) 10 >> "$P/mine.jsonl"; done
turn o1 0 0 0 7000 10 > "$P/other.jsonl"
touch -d '1 minute ago' "$P/mine.jsonl"; touch "$P/other.jsonl"

# THE POSITIVE CONTROL FOR THE FALLBACK ITSELF. Every assertion below says the newest-by-mtime
# glob did NOT fire; this one says it can, and that it lands on `other`. Without it, a glob
# broken in any way — a wrong slug, a wrong root — would satisfy the whole section by finding
# nothing, and the gating those cases exist to check would be untested.
has "with no session named, the newest transcript in the directory is used" \
    "$(line '{"cwd":"/two/sessions"}')" "ctx 7k"

# THE POSITIVE CONTROL FOR THE WHOLE SECTION. Before asserting that the transcript's number is
# NOT what gets printed, prove this fixture's transcript does produce a number of its own —
# otherwise "the JSON won" and "the transcript was unreadable" look identical.
L="$(line "{\"session_id\":\"mine\",\"transcript_path\":\"$P/mine.jsonl\"}")"
has "a hook without a context_window still reads the transcript" "$L" "ctx 2k"
has "and reports the turns it counted there"                     "$L" "/21t"

# THE SUPPLIED FIELD WINS. 44000 is nowhere near the transcript's 2200, so a meter still
# re-deriving the headline cannot accidentally agree.
L="$(line "$(hook mine "$P/mine.jsonl" 44000 200000 22)")"
has "the headline is the client's total_input_tokens" "$L" "ctx 44k"
hasnt "and not the transcript's own sum"              "$L" "ctx 2k"
has "while the turn count still comes from the transcript" "$L" "/21t"

# AND IT MATCHES used_percentage, which the client pre-computes as
# round(total_input_tokens / context_window_size * 100). Asserting the tokens and the
# percentage against each other is what makes "the same number the client reports" checkable
# rather than merely claimed.
for pct in 5 22 61; do
    tok=$(( 200000 * pct / 100 ))
    got="$(line "$(hook mine "$P/mine.jsonl" "$tok" 200000 "$pct")" | sed -n 's/.*ctx \([0-9]*\)k.*/\1/p')"
    is "ctx at ${pct}% of the window reads as $(( tok / 1000 ))k" "$(( tok / 1000 ))" "$got"
done
# The extended-context window is a different size, and the headline must follow the tokens
# rather than the percentage's scale.
L="$(line "$(hook mine "$P/mine.jsonl" 610000 1000000 61)")"
has "an extended-context window reports its own token count" "$L" "ctx 610k"

# THIS SESSION, NOT THE NEWEST ONE. `other` is newer by mtime and carries a different number.
L="$(line "$(hook mine "$P/mine.jsonl" 44000 200000 22)")"
hasnt "a newer sibling transcript is not the one measured" "$L" "ctx 7k"
L="$(line "{\"session_id\":\"mine\",\"cwd\":\"/two/sessions\",\"transcript_path\":\"$P/other.jsonl\"}")"
has "session_id outranks a transcript_path pointing elsewhere" "$L" "ctx 2k"
hasnt "so the sibling's context is never reported"             "$L" "ctx 7k"

# ==========================================================================================
echo
echo "ctx-meter.sh line — fresh, unreadable, and the difference between them"
# ==========================================================================================
# A SESSION THE HOOK NAMED BUT THAT HAS NOT SPOKEN YET IS FRESH. This is the state for the few
# seconds after a clear, and it is exactly where reporting the newest OTHER session's number
# does the most damage: the operator reads a discarded session's total as the live one.
L="$(line "$(hook brandnew "$P/brandnew.jsonl")")"
has "a named session with no transcript yet reads as fresh" "$L" "ctx fresh"
hasnt "and never the newest sibling's number"               "$L" "ctx 7k"
hasnt "and never as a zero context"                         "$L" "ctx 0k"
hasnt "and never as an unreadable gauge"                    "$L" "ctx ?"

# A transcript that exists but carries no assistant usage row is the same state.
: > "$P/empty.jsonl"
L="$(line "$(hook empty "$P/empty.jsonl")")"
has "a transcript with no usage row yet is fresh too" "$L" "ctx fresh"
hasnt "and not the sibling that does have one"        "$L" "ctx 7k"

# `?` IS STILL RESERVED FOR A GAUGE THAT COULD NOT READ. With no session named at all there is
# nothing to be fresh about, and the meter must not claim a state it did not establish.
L="$(line '{"cwd":"/nowhere/at/all"}')"
has "an unnamed session with nothing to read stays ?" "$L" "ctx ?"
hasnt "and does not borrow the fresh state"           "$L" "fresh"

# ==========================================================================================
echo
echo "ctx-meter.sh — the incremental read, because this now runs every few seconds"
# ==========================================================================================
# THE SAVING IS ASSERTED AS A NUMBER, not as elapsed time: a wall-clock threshold on a shared
# box is a flake, and the property that actually makes it fast is that a second pass reads
# only what was appended. SP_CTX_SCAN_BYTES is that property, published.
mkdir -p "$T/incr/-a-project" "$T/incrrun"
IJ="$T/incr/-a-project/live.jsonl"
: > "$IJ"; for i in $(seq 0 20); do turn "p$i" 0 0 0 $(( 500 + i * 5 )) 10 >> "$IJ"; done
ienv() {
    env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/incrrun" \
        SPIRA_TOKEN_PROJECTS="$T/incr" SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH \
        SPIRA_CTX_LIMIT=$CL bash "$CTX" env 2>/dev/null
}
size() { wc -c < "$1" | tr -d ' '; }

C="$(ienv)"
is "the first pass reads the whole transcript" "$(size "$IJ")" "$(val SP_CTX_SCAN_BYTES <<<"$C")"
is "and counts every turn in it"                            "21" "$(val SP_CTX_TURNS <<<"$C")"
cold_now="$(val SP_CTX_NOW <<<"$C")"

C="$(ienv)"
is "a pass with nothing appended reads nothing"  "0" "$(val SP_CTX_SCAN_BYTES <<<"$C")"
is "and still reports the same turn count"      "21" "$(val SP_CTX_TURNS <<<"$C")"
is "and the same context"           "$cold_now" "$(val SP_CTX_NOW <<<"$C")"

before="$(size "$IJ")"
turn p99 0 0 0 9000 10 >> "$IJ"
C="$(ienv)"
is "an appended turn costs only its own bytes" "$(( $(size "$IJ") - before ))" "$(val SP_CTX_SCAN_BYTES <<<"$C")"
is "the turn is counted"                       "22" "$(val SP_CTX_TURNS <<<"$C")"
is "and it is the one reported"              "9000" "$(val SP_CTX_NOW <<<"$C")"

# THE CURSOR MAY ONLY MAKE THIS FASTER, NEVER DIFFERENT. Reading the same file with the cursor
# thrown away must produce the same answer; if it does not, every incremental figure above is
# a number the cold path would disagree with.
rm -rf "$T/incrrun/ctx-meter"
C="$(ienv)"
is "a cold read agrees with the incremental one" "22" "$(val SP_CTX_TURNS <<<"$C")"
is "on the context too"                        "9000" "$(val SP_CTX_NOW <<<"$C")"

# A TRANSCRIPT REWRITTEN IN PLACE KEEPS ITS INODE and can regrow past the recorded offset, so
# the offset alone is not enough to resume on: doing that would splice two sessions' turns into
# one count. The cursor carries a digest of the file's opening bytes for exactly this.
old="$(size "$IJ")"
: > "$IJ"; for i in $(seq 0 4); do turn "q$i" 0 0 0 $(( 100 + i )) 10 >> "$IJ"; done
while [ "$(size "$IJ")" -le "$old" ]; do turn "q$(date +%s%N)" 0 0 0 104 10 >> "$IJ"; done
C="$(ienv)"
fresh_turns="$(grep -c '"usage"' "$IJ")"
is "a rewritten transcript is re-read from the start" "$fresh_turns" "$(val SP_CTX_TURNS <<<"$C")"
is "and the whole of it is scanned"      "$(size "$IJ")" "$(val SP_CTX_SCAN_BYTES <<<"$C")"

# A HALF-WRITTEN LAST LINE IS NOT CONSUMED. The client appends while this runs, so the final
# line can be a fragment; a cursor advanced past it would drop that turn permanently.
turn r1 0 0 0 4242 10 | head -c 40 >> "$IJ"
C="$(ienv)"
is "a partial line is not counted as a turn" "$fresh_turns" "$(val SP_CTX_TURNS <<<"$C")"
printf '%s' "$(turn r1 0 0 0 4242 10 | tail -c +41)" >> "$IJ"; echo >> "$IJ"
C="$(ienv)"
is "and is counted once the rest of it lands" "$(( fresh_turns + 1 ))" "$(val SP_CTX_TURNS <<<"$C")"
is "with its context reported"                                 "4242" "$(val SP_CTX_NOW <<<"$C")"

# ONE DEFINITION, TWO READERS. Where there is no hook to supply total_input_tokens, `env` sums
# it off the transcript by the client's own formula — input_tokens AND both cache fields. Every
# other fixture here leaves input_tokens at zero, so a reader that dropped the uncached term
# would agree with all of them and still disagree with the status line on every real session.
mkdir -p "$T/defn/-a-project"
turn d1 0 250 1000 4000 10 > "$T/defn/-a-project/live.jsonl"
C="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/defnrun" \
     SPIRA_TOKEN_PROJECTS="$T/defn" SPIRA_CTX_WARN=$CW SPIRA_CTX_HIGH=$CH \
     SPIRA_CTX_LIMIT=$CL bash "$CTX" env 2>/dev/null)"
is "the transcript-side context is input plus both cache fields" "5250" "$(val SP_CTX_NOW <<<"$C")"

# ==========================================================================================
echo
echo "the series — because a gauge cannot answer \"over time\""
# ==========================================================================================
HIST="$T/run/cockpit-history.csv"
cat > "$T/run/cockpit.env" <<'EOF'
SP_AT='1700000000'
SP_TOK_WIN='11430'
SP_TOK_AEON_WIN='3350'
SP_TOK_SESS_WIN='8080'
SP_TOK_AEON_TURNS='1'
SP_TOK_SESS_TURNS='1'
SP_CTX_NOW='1200'
EOF
run "$COCKPIT" history >/dev/null
is "the header names the columns" \
   "ts,tok_win,tok_aeon_win,tok_sess_win,tok_aeon_turns,tok_sess_turns,ctx_now" \
   "$(head -1 "$HIST")"
is "a row carries the snapshot's own figures" "1700000000,11430,3350,8080,1,1,1200" \
   "$(sed -n 2p "$HIST")"
run "$COCKPIT" history >/dev/null
is "a second pass appends rather than rewriting" "3" "$(wc -l < "$HIST")"
is "and writes the header once"                  "1" "$(grep -c '^ts,' "$HIST")"

# A FAILED PROBE IS CARRIED INTO THE SERIES AS `?`. Collapsing it to 0 here would put the
# difference between "measured nothing" and "could not measure" beyond recovery for every
# reader downstream, and a trough is exactly what a quiet hour looks like.
printf "SP_AT='1700000060'\nSP_TOK_WIN='?'\n" > "$T/run/cockpit.env"
run "$COCKPIT" history >/dev/null
has "a failed probe is recorded as ?" "$(tail -1 "$HIST")" "1700000060,?,"
hasnt "and never as a zero"          "$(tail -1 "$HIST")" "1700000060,0,"

# THE SERIES IS BOUNDED. Unbounded, a row a minute is half a million lines a year in a file
# the pane re-reads on every repaint.
hdr="$(head -1 "$HIST")"
{ echo "$hdr"; for i in $(seq 1 40); do echo "$i,1,1,1,1,1,1"; done; } > "$HIST"
env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
    SPIRA_TOKEN_PROJECTS="$T/projects" SPIRA_COCKPIT_HISTORY_MAX=10 \
    bash "$COCKPIT" history >/dev/null 2>&1
is "it is bounded to the newest rows plus the header" "11" "$(wc -l < "$HIST")"
is "and the oldest rows are the ones dropped" "32,1,1,1,1,1,1" "$(sed -n 2p "$HIST")"

# TWO PASSES IN ONE PROCESS, which is what `loop` actually is. The snapshot is sourced to build
# the row, and sourcing it into the long-lived collector would leave its keys set — so a later
# pass whose probe wrote nothing at all would silently reuse the previous pass's figure instead
# of `?`. A stale number presented as current is indistinguishable from a healthy flat line.
rm -f "$HIST"
# The FIRST pass must carry real figures, or there is nothing distinctive left behind for the
# second to leak and the case would pass against the bug it exists to catch.
printf "SP_AT='111'\nSP_TOK_WIN='11430'\nSP_TOK_AEON_WIN='3350'\nSP_CTX_NOW='1200'\n" \
    > "$T/run/cockpit.env"
env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$NONE" SPIRA_RUN="$T/run" \
    SPIRA_TOKEN_PROJECTS="$T/projects" bash -c '
        . "$0" history >/dev/null 2>&1
        printf "SP_AT=\x27222\x27\n" > "$1"
        . "$0" history >/dev/null 2>&1
    ' "$COCKPIT" "$T/run/cockpit.env" 2>/dev/null
is "the first pass records what it measured" "111,11430,3350,?,?,?,1200" "$(sed -n 2p "$HIST")"
is "a later pass with no probe writes ?" "222,?,?,?,?,?,?" "$(tail -1 "$HIST")"

# A CHANGED COLUMN SET ROTATES THE FILE. Every reader takes line one as the header, so a second
# one appended mid-file is parsed as data and every column after it is read under a wrong name.
printf 'ts,something,else\n1,2,3\n' > "$HIST"
run "$COCKPIT" history >/dev/null
is "a stale column set is replaced, not appended to" \
   "ts,tok_win,tok_aeon_win,tok_sess_win,tok_aeon_turns,tok_sess_turns,ctx_now" \
   "$(head -1 "$HIST")"
is "and the file carries exactly one header"  "1" "$(grep -c '^ts,tok_win' "$HIST")"
is "the superseded rows are kept, not deleted" "1,2,3" \
   "$(cat "$HIST".[0-9]* 2>/dev/null | sed -n 2p)"
rm -f "$HIST".[0-9]*

# ==========================================================================================
echo
echo "the pane — the numbers reaching the operator, and the ? that must reach them too"
# ==========================================================================================
cat > "$T/run/cockpit.env" <<'EOF'
SP_AT='1700000000'
SP_TOK_WINDOW_H='3'
SP_TOK_WIN='493858838'
SP_TOK_AEON_WIN='126045349'
SP_TOK_SESS_WIN='367813489'
SP_TOK_AEON_TURNS='1007'
SP_TOK_SESS_TURNS='2063'
SP_TOK_AEON_CTX='123132'
SP_TOK_SESS_CTX='175627'
SP_CTX_NOW='1200'
SP_CTX_TURNS='30'
SP_CTX_GROWTH='100'
SP_CTX_NEXT='high'
SP_CTX_HEADROOM='600'
SP_CTX_TURNS_LEFT='6'
SP_CTX_AGE='12'
SP_CTX_ARCHIVIST='none'
SP_CTX_ARCHIVIST_BEHIND='0'
EOF
# The pane takes its own size, so the fixture drives it explicitly rather than inheriting a
# terminal's. LC_ALL matters: the frame is full of multibyte characters and a suite run from
# the gate inherits the C locale, where a byte count and a column count disagree.
paint() {   # paint [rows] [cols] -> the frame, ANSI stripped
    env -i HOME="$T/home" PATH="$PATH" TERM=dumb LC_ALL=C.UTF-8 SPIRA_CONF="$NONE" \
        SPIRA_REPO="$T" SPIRA_RUN="$T/run" bash "$HEALTH" once "${1:-0}" "${2:-100}" 2>/dev/null \
        | sed 's/\x1b\[[?0-9;]*[a-zA-Z]//g'
}
F="$(paint)"
tokline="$(grep 'TOKENS' <<<"$F")"
ctxline="$(grep '^ CTX' <<<"$F")"
has "the window total is rendered"            "$tokline" "493M billed"
has "the window length is the configured one" "$tokline" "TOKENS/3h"
# THE SPLIT IS THE POINT. A single total would not have answered the question this was built
# for, and the answer was not the obvious one — the interactive session is the larger half.
# A row each, because the tail of a long line is what a narrow column silently cuts.
has "the aeon share has its own row"    "$F" "aeons    25%"
has "the session share has its own row" "$F" "session  74%"
has "turns are on the row"              "$F" "1007t"
has "and so is context per turn"        "$F" "123k ctx/turn"
has "the live session's context is rendered"  "$ctxline" "1k"
has "with its headroom to the next threshold" "$ctxline" "600 to high"
has "and that headroom in turns"              "$ctxline" "~6t"

# WIDTH IS A CORRECTNESS CONSTRAINT. Autowrap is off in the pane, so an over-long line is CUT
# by the terminal — and the tail is the context-per-turn and the headroom, the numbers these
# rows exist to show. Driven with the widest plausible figures: a billion-token window,
# five-digit turn counts and a full sparkline, against the narrowest column the cockpit gives.
{ echo "ts,tok_win,tok_aeon_win,tok_sess_win,tok_aeon_turns,tok_sess_turns,ctx_now"
  for i in $(seq 1 40); do echo "$i,$(( i * 7919 )),1,1,1,1,1"; done; } > "$T/run/cockpit-history.csv"
sed -e "s/SP_TOK_WIN='.*'/SP_TOK_WIN='1234567890'/" \
    -e "s/SP_TOK_AEON_TURNS='.*'/SP_TOK_AEON_TURNS='12345'/" \
    -e "s/SP_TOK_SESS_TURNS='.*'/SP_TOK_SESS_TURNS='23456'/" \
    -e "s/SP_CTX_NOW='.*'/SP_CTX_NOW='987654'/" \
    -e "s/SP_CTX_TURNS='.*'/SP_CTX_TURNS='1234'/" \
    -e "s/SP_CTX_ARCHIVIST='.*'/SP_CTX_ARCHIVIST='safe'/" \
    -i "$T/run/cockpit.env"
wide="$(paint 40 70 | grep -E 'TOKENS|ctx/turn|^ CTX|safe to clear' \
        | python3 -c 'import sys; print(max([len(l) for l in sys.stdin.read().splitlines()] or [0]))')"
[ "${wide:-999}" -le 70 ] 2>/dev/null \
    && ok "no token row overflows the column the cockpit gives it" \
    || bad "no token row overflows the column the cockpit gives it" "widest is $wide columns"
# THE POSITIVE CONTROL FOR THE FIT, both ways. A column too narrow for the row must CUT it and
# MARK the cut — a silent truncation is the defect, not the cutting — and a column with room
# must mark nothing, or the first assertion proves only that an ellipsis is always printed.
# Matched on the label rather than on the tail: at the narrowest width the tail is precisely
# what is gone, so grepping for it would find no row at all and the case would pass vacuously.
hasnt "a column with room to spare marks no cut" "$(paint 40 200 | grep 'aeons')" "…"
has   "and one without room cuts and marks it"   "$(paint 40 30  | grep 'aeons')" "…"
rm -f "$T/run/cockpit-history.csv"

# THE POSITIVE CONTROL FOR THE PANE. Everything above proves it can render figures; this
# proves a collector that stopped writing them renders `?` and not a comforting zero.
printf "SP_AT='1700000000'\n" > "$T/run/cockpit.env"
F="$(paint)"
tokline="$(grep 'TOKENS' <<<"$F")"
has "a missing token probe renders ?"     "$tokline" "? billed"
hasnt "and never renders a zero total"    "$tokline" "0 billed"
# THREE STATES, NOT TWO. An unread probe is a fault; "no session at the keyboard" is a true
# and useful state. Rendering the first as the second reports a broken meter as a quiet one.
has "an unread context probe says it could not read" "$F" "cannot read the live session"
printf "SP_AT='1700000000'\nSP_CTX_NOW='-'\n" > "$T/run/cockpit.env"
has "and a genuinely idle keyboard says that instead" "$(paint)" "no session at the keyboard"

# THE TWO SECTIONS ARE FIXED, NOT ELASTIC: they sit directly under the header and the row
# allocator never elides them. The constraint that stops all other work must not be what a
# short pane drops.
short="$(paint 6 100)"
has "TOKENS is on the row below the header" "$(sed -n 2p <<<"$short")" "TOKENS"
has "and CTX survives a pane with six rows" "$short" "CTX"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo "PASS: tokens"; exit 0; fi
echo "FAIL: tokens"; exit 1
