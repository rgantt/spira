#!/usr/bin/env bash
#
# test-archive.sh — the transcript archive: what it stores, what it refuses to touch twice,
# and whether a lineage can still be found once the client has moved on.
#
#   ./test-archive.sh
#
# WHAT THIS SUITE IS GUARDING. The archive exists because the transcripts are the only record
# of every decision taken in conversation that never became a bead, and they live somewhere
# nothing versions and nobody promises to keep. So the expensive failure here is not a crash
# — it is an archive that reports success while holding a body that no longer matches, or an
# index that answers "no rows" because it was looking at the wrong place. Every case that
# asserts something is ABSENT first plants the same shape present and proves the code path
# finds it (law-absence-needs-a-positive-control), and every claim that the store is sound is
# made by re-hashing bytes rather than by trusting a row.
#
# THE CONFIGURED VALUES ARE PINNED TO NON-DEFAULTS, and one of them is set from a CONFIG FILE
# rather than the environment, because an archive root asserted against the shipped default
# would pass just as well with the path written back into the code — which is the thing the
# key exists to stop.
#
# AND IT RUNS UNDER `env -i`. A suite that inherited the operator's spira.conf would archive
# their real transcripts into their real archive — gigabytes of somebody's actual work, on
# fixtures expecting four files (law-gates-run-in-a-clean-environment).
#
# covers: spira/archive.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ARCHIVE_SH="$HERE/archive.sh"
CONF_SH="$HERE/conf.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1${2:+: $2}"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "found [$3] in [$2]" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/home" "$T/projects/-one-project" "$T/projects/-other-project"
ARCH="$T/store"                      # non-default: the default derives from SPIRA_RUN
CONF="$T/spira.conf"
printf 'SPIRA_ARCHIVE = %s\n' "$ARCH" > "$CONF"

# run <mode> [args...] — the tool under a minimal environment. The archive root comes from
# the CONFIG FILE; only the transcript directory is handed in, because that is the fixture.
run() {
    env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$CONF" \
        SPIRA_TOKEN_PROJECTS="$T/projects" \
        bash "$ARCHIVE_SH" "$@" 2>"$T/err"
}
err() { cat "$T/err"; }
mtimes() { find "$1" -printf '%p %T@\n' 2>/dev/null | sort; }

# turn <ts> <id> -> one assistant record. Fractional seconds on purpose: the client writes
# them and the index must canonicalise them, or a string comparison sorts a fraction BEFORE
# the same instant without one.
turn() { printf '{"type":"assistant","timestamp":"%s.250Z","message":{"id":"%s"}}\n' "$1" "$2"; }
bridge() { printf '{"type":"bridge-session","sessionId":"%s","bridgeSessionId":"%s"}\n' "$1" "$2"; }

P="$T/projects"
# ONE LINEAGE OF TWO, spanning a clear: same bridge id, different session ids and days.
{ bridge sess-a cse_CHAIN; turn 2026-03-01T10:00:00 a1; turn 2026-03-01T12:00:00 a2; } > "$P/-one-project/sess-a.jsonl"
{ bridge sess-b cse_CHAIN; turn 2026-03-04T09:00:00 b1; }                              > "$P/-one-project/sess-b.jsonl"
# A SECOND LINEAGE, in another project directory — the positive control for every filter
# below. Without it, a query that excluded everything and one that excluded nothing would
# produce the same verdict.
{ bridge sess-c cse_OTHER; turn 2026-03-02T11:00:00 c1; }                               > "$P/-other-project/sess-c.jsonl"
# A TRANSCRIPT WITH NO LINEAGE ID AT ALL. Some are written before one is assigned.
{ turn 2026-03-09T08:00:00 d1; }                                                        > "$P/-other-project/sess-d.jsonl"

# ==========================================================================================
echo
echo "the first pass — one body and one row per transcript"
# ==========================================================================================
out="$(run sweep)"
has "the sweep says what it stored"        "$out" "4 stored"
is  "one row per transcript"          "4" "$(wc -l < "$ARCH/index.jsonl")"
is  "and one body per transcript"     "4" "$(find "$ARCH/bodies" -type f | wc -l)"
has "the root came from the config file, not a default" "$(run where)" "$ARCH"
# THE BODIES ARE FILED UNDER THE PROJECT DIRECTORY they came from, so the archive can still
# say which conversation a transcript belonged to once the client's own directory is gone.
is  "bodies keep the project directory" "1" \
    "$(find "$ARCH/bodies/-one-project" -name 'sess-a.jsonl.*' | wc -l)"

echo
echo "the index — what a row has to carry to be worth querying"
row() { python3 -c 'import json,sys
for ln in open(sys.argv[1]):
    r=json.loads(ln)
    if r["session_id"]==sys.argv[2]: print(r.get(sys.argv[3],"")); break' "$ARCH/index.jsonl" "$1" "$2"; }
is "the lineage id is indexed"      "cse_CHAIN"            "$(row sess-a bridge_session_id)"
is "the project directory is indexed" "-one-project"       "$(row sess-a cwd_slug)"
is "turns are counted"              "2"                    "$(row sess-a turns)"
# CANONICAL WHOLE SECONDS, UTC. The source said 10:00:00.250Z; a raw fraction sorts before
# the same instant without one, so the window query would be right almost always.
is "the first timestamp is canonicalised" "2026-03-01T10:00:00Z" "$(row sess-a first_ts)"
is "and the last one is the file's last"  "2026-03-01T12:00:00Z" "$(row sess-a last_ts)"
is "a measured range says so"             "transcript"           "$(row sess-a ts_source)"
is "the index is sorted by first_ts"  "sess-a" \
   "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["session_id"])' "$ARCH/index.jsonl")"
# NO MESSAGE CONTENT IN THE INDEX. It is the only artefact anyone might reasonably keep in a
# repository, and it is metadata precisely so that it can be.
hasnt "no transcript content reaches the index" "$(cat "$ARCH/index.jsonl")" '"message"'

echo
echo "the second pass — nothing changed, so nothing is touched"
before_idx="$(stat -c %y "$ARCH/index.jsonl")"
before_bodies="$(mtimes "$ARCH/bodies")"
out="$(run sweep)"
has "it says the index was left alone" "$out" "index untouched"
has "and that it stored nothing"       "$out" "0 stored"
is  "the index file is not rewritten"  "$before_idx" "$(stat -c %y "$ARCH/index.jsonl")"
is  "and no body is rewritten"         "$before_bodies" "$(mtimes "$ARCH/bodies")"

echo
echo "a GROWING transcript — the positive control for that silence"
# Without this, "touched nothing" and "cannot see anything" are the same result. A live
# session's transcript is appended to for hours, so this is the ordinary case, not the edge.
turn 2026-03-01T15:00:00 a3 >> "$P/-one-project/sess-a.jsonl"
out="$(run sweep)"
has "the grown transcript is stored again"  "$out" "1 stored"
has "and the index is rewritten"            "$out" "index rewritten"
is  "the row's range grows with it"    "2026-03-01T15:00:00Z" "$(row sess-a last_ts)"
is  "its turn count grows with it"     "3"                    "$(row sess-a turns)"
is  "and it REPLACED rather than duplicated" "4" "$(find "$ARCH/bodies" -type f | wc -l)"

echo
echo "restoring — byte for byte, or it says so"
run restore sess-a > "$T/restored.jsonl"
is "the restored bytes are the original bytes" \
   "$(sha256sum < "$P/-one-project/sess-a.jsonl" | cut -d' ' -f1)" \
   "$(sha256sum < "$T/restored.jsonl" | cut -d' ' -f1)"
out="$(run verify)"; rc=$?
is  "verify is green over a sound archive" "0" "$rc"
has "and names each body it checked"       "$out" "-one-project/sess-a.jsonl"
# THE POSITIVE CONTROL FOR VERIFY, and the reason it re-hashes rather than reading the row:
# a body swapped for a valid compressed file of something else passes every structural check
# there is. One body is deleted as well, because missing and wrong fail differently.
body_a="$(find "$ARCH/bodies/-one-project" -name 'sess-a.jsonl.*')"
body_b="$(find "$ARCH/bodies/-one-project" -name 'sess-b.jsonl.*')"
cp "$body_b" "$body_a"
rm -f "$(find "$ARCH/bodies/-other-project" -name 'sess-c.jsonl.*')"
out="$(run verify)"; rc=$?
is  "verify is red when a body no longer matches its digest" "1" "$rc"
has "and names the swapped one"  "$out" "FAIL    -one-project/sess-a.jsonl"
has "and the missing one"        "$out" "MISSING -other-project/sess-c.jsonl"
run restore sess-a >/dev/null
has "a restore of a swapped body refuses too" "$(err)" "DO NOT MATCH"
# AN ORDINARY SWEEP REPAIRS THE MISSING BODY AND NOT THE SWAPPED ONE, and that is the honest
# behaviour rather than a gap: the fast path reads the SOURCE's size and mtime, which a body
# rotting underneath does not change. `--force` is the remedy, and it exists because "verify
# went red" with no way to act on it is a check that only produces alarm.
run sweep >/dev/null
out="$(run verify)"; rc=$?
is  "a plain sweep restores a body that had vanished" "0" "$(printf '%s\n' "$out" | grep -c MISSING)"
is  "and leaves a silently swapped one for --force"   "1" "$rc"
run sweep --force >/dev/null
is  "--force re-stores every body from source"        "0" "$(run verify >/dev/null; echo $?)"

echo
echo "lineage — the chain a session belongs to, oldest first"
out="$(run lineage sess-b)"
is  "both transcripts in the chain"   "2" "$(printf '%s\n' "$out" | grep -c 'sess-')"
is  "oldest first"                    "sess-a" "$(printf '%s\n' "$out" | head -1 | awk '{print $5}')"
hasnt "and nothing from the other lineage" "$out" "sess-c"
# A CHAIN OF ONE IS AN ANSWER, not an error — and it says which it is, so a caller cannot
# read "no lineage recorded" as "the chain is empty".
out="$(run lineage sess-d)"; e="$(err)"
has "a session with no lineage id is a chain of one" "$out" "sess-d"
has "and says so"                                    "$e"   "chain of one"
# AN UNKNOWN SESSION REFUSES. Printing nothing would be indistinguishable from a session
# whose whole chain was archived and empty, which is the failure this suite is built around.
run lineage no-such-session >/dev/null; rc=$?
is  "an unknown session is refused, not answered with silence" "2" "$rc"
has "and the refusal names it" "$(err)" "no-such-session"

echo
echo "query — a time window, a lineage, a project directory"
out="$(run query --since 2026-03-03 --until 2026-03-05)"
is  "only the transcripts overlapping the window" "1" "$(printf '%s\n' "$out" | grep -c sess-)"
has "and it is the right one"                     "$out" "sess-b"
# OVERLAP, NOT CONTAINMENT: sess-a starts before this window and ends inside it, and a
# containment test would drop exactly the long session most worth finding.
out="$(run query --since 2026-03-01T14:00:00Z --until 2026-03-01T16:00:00Z)"
has "a session spanning the window is found" "$out" "sess-a"
# A BARE DATE IS THE WHOLE DAY. `--until 2026-03-02` read as midnight would exclude the day.
out="$(run query --since 2026-03-02 --until 2026-03-02)"
has "a bare date covers its whole day" "$out" "sess-c"
is  "and only that day"           "1" "$(printf '%s\n' "$out" | grep -c sess-)"
out="$(run query --lineage cse_OTHER)"
has "a lineage filter keeps its own"        "$out" "sess-c"
hasnt "and drops the other chain"           "$out" "sess-a"
out="$(run query --slug '-one-*')"
is  "a project-directory glob narrows to it" "2" "$(printf '%s\n' "$out" | grep -c sess-)"
hasnt "and excludes the others"              "$out" "sess-c"
is  "--json emits the rows themselves" "sess-b" \
    "$(run query --lineage cse_CHAIN --json | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_id"])')"
run query --since not-a-date >/dev/null; is "an unparseable bound is refused" "2" "$?"

echo
echo "subagent transcripts — kept, and joined to the session that spawned them"
mkdir -p "$P/-one-project/sess-a/subagents"
{ printf '{"type":"fork-context-ref","agentId":"z1","parentSessionId":"sess-a"}\n'
  turn 2026-03-01T13:00:00 z1; } > "$P/-one-project/sess-a/subagents/agent-z1.jsonl"
run sweep >/dev/null
out="$(run lineage sess-b)"
# A subagent transcript records its parent session and no lineage id of its own. Without the
# join it is in the archive and in no answer about it, which is the same as not having it.
has "a subagent transcript inherits its session's lineage" "$out" "agent-z1.jsonl"
is  "the chain is now three"  "3" "$(printf '%s\n' "$out" | grep -c 'sess-\|agent-')"

echo
echo "the session-end hook — one transcript, not a sweep"
turn 2026-03-04T18:00:00 b2 >> "$P/-one-project/sess-b.jsonl"
turn 2026-03-02T18:00:00 c2 >> "$P/-other-project/sess-c.jsonl"
out="$(printf '{"session_id":"sess-b","transcript_path":"%s","hook_event_name":"SessionEnd"}' \
       "$P/-one-project/sess-b.jsonl" | run hook)"
has "the named transcript is archived"    "$out" "1 stored"
is  "its row is current"  "2026-03-04T18:00:00Z" "$(row sess-b last_ts)"
# THE POSITIVE CONTROL FOR "one, not a sweep": the other grown transcript is untouched, which
# is only visible because it too was grown.
is  "and the transcript it was not told about is left for the timer" \
    "2026-03-02T11:00:00Z" "$(row sess-c last_ts)"
printf 'not json at all' | run hook >/dev/null; is "a payload that is not JSON is refused" "2" "$?"
has "and says which" "$(err)" "not JSON"
printf '' | run hook >/dev/null; is "an empty payload is refused" "2" "$?"

echo
echo "refusing to answer from the wrong place"
# EVERY ONE OF THESE WOULD OTHERWISE READ AS GOOD NEWS. An empty archive answering a query
# with no rows, or a sweep reporting nothing to do because it was pointed at a directory that
# does not exist, is the shape that stops anybody looking.
env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$T/none.conf" SPIRA_ARCHIVE="$T/empty" \
    SPIRA_TOKEN_PROJECTS="$T/projects" bash "$ARCHIVE_SH" query >/dev/null 2>"$T/err"
is  "a query against an archive with no index is refused" "2" "$?"
has "and says how to fill it" "$(err)" "sweep"
env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$T/none.conf" SPIRA_ARCHIVE="$T/empty2" \
    SPIRA_TOKEN_PROJECTS="$T/no-such-dir" bash "$ARCHIVE_SH" sweep >/dev/null 2>"$T/err"
is  "a sweep of a missing transcript directory is an error, not '0 stored'" "1" "$?"
has "and names the directory" "$(err)" "no-such-dir"
env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$T/none.conf" SPIRA_ARCHIVE="$T/empty3" \
    SPIRA_TOKEN_PROJECTS="$T/projects" bash "$ARCHIVE_SH" verify >/dev/null 2>"$T/err"
is  "verify over an empty index refuses rather than reporting all sound" "2" "$?"
run restore no-such-session >/dev/null; is "restoring an unknown session is refused" "2" "$?"

echo
echo "the archive root is configuration, not a literal"
# The default must DERIVE from the runtime directory. Asserted this way rather than against a
# fixed path, so a default written back into the code as a literal fails here.
d="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$T/none.conf" SPIRA_RUN="$T/rt" \
     bash -c ". '$CONF_SH' >/dev/null 2>&1; printf '%s' \"\$SPIRA_ARCHIVE\"")"
is "the default sits under SPIRA_RUN" "$T/rt/archive" "$d"
# AND IT IS NOT EXPORTED. It is derived from where the harness sits, and a value that leaks
# into a child makes that child archive into whichever installation last sourced a conf.sh.
n="$(env -i HOME="$T/home" PATH="$PATH" SPIRA_CONF="$T/none.conf" \
     bash -c ". '$CONF_SH' >/dev/null 2>&1; env" | grep -c '^SPIRA_ARCHIVE=')"
is "and does not leak into a child's environment" "0" "$n"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
