#!/usr/bin/env bash
#
# test-aeon-verdict.sh — a bead closed with nothing committed is reopened, UNLESS it was
# superseded.
#
#   ./test-aeon-verdict.sh
#
# THE DEFECT THIS REPRODUCES. Two checks ask the same question — "this bead says closed; is
# there a commit that names it?" — one in aeon.sh at the end of a session, one in the
# sentinel's closed-but-not-landed sweep. Both must exempt a bead retired with `bd
# supersede`, because such a bead will NEVER have a commit naming it: its work was carried
# onto the successor's branch and landed under the successor's id. The exemption was added
# to the sentinel and not to aeon.sh, so a superseded bead was reopened the moment the
# session that retired it exited, re-summoned, re-cut its branch, and spent a whole Opus
# session rediscovering that it was a duplicate — seven times over on one bead before
# anybody read the second check.
#
# EVERY CASE IS A PAIR (law-absence-needs-a-positive-control). The exemption is only
# meaningful if the check it exempts is shown to fire: the superseded bead is asserted to
# survive beside an identical one that is NOT superseded and is reopened, and beside one
# that committed and is therefore left alone for the other reason. A suite that only
# asserted "still closed" would pass just as well against a check that never runs.
#
# Driven through the REAL aeon.sh against a real bd on a throwaway fixture, with a shim
# standing in for the model, because what is under test is a query's shape and a branch's
# commit graph and a model of either would be a second implementation of the thing in
# question (law-prefer-the-real-dependency).
#
# covers: spira/aeon.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-aeon-verdict
TMP="$(mktemp -d)"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up aeonverdict || { echo "test-aeon-verdict: could not build a fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A repository with a remote, because the base an aeon judges currency against is the
# remote-tracking ref.
ORIGIN="$TMP/origin.git"; git init -q --bare -b main "$ORIGIN"
REPO="$TMP/repo"; git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/f"
git -C "$REPO" add f; git -C "$REPO" commit -qm seed; git -C "$REPO" push -q origin main 2>/dev/null

export SPIRA_HOME="$TMP/home"; mkdir -p "$SPIRA_HOME/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/aeon.sh" "$SPIRA_HOME/"
cp -r "$HERE/actors" "$SPIRA_HOME/" 2>/dev/null || true
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_REPO_MAP="$TMP/repo-map"
printf 'fixture | %s | push | origin/main | |\n' "$REPO" > "$SPIRA_REPO_MAP"
cat > "$SPIRA_HOME/chamber/builder.fayth" <<FAYTH
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
FAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=600
FAYTH
printf 'work {{BEAD_ID}} in {{REPO}} on {{BRANCH}}\n{{PARK}}\n' > "$SPIRA_HOME/chamber/builder.md"

# THE SHIM IS THE SESSION, running where the model would and finishing the bead the way the
# case under test needs it finished. The guard below is not decoration: conf.sh replaces
# $PATH, so a suite that tried to shim `claude` by PATH alone would run the real model
# against a real account, silently and at full cost.
BIN="$TMP/bin"; mkdir -p "$BIN"; export SPIRA_CLAUDE="$BIN/claude" TMP
grep -q 'SPIRA_CLAUDE' "$HERE/aeon.sh" \
    || { echo "test-aeon-verdict: aeon.sh has no SPIRA_CLAUDE injection point — refusing to run the real model" >&2; exit 1; }
shim() {   # shim <commit:0|1> <finish: close | supersede:<successor-id>>
    printf '%s' "$1" > "$TMP/docommit"
    printf '%s' "$2" > "$TMP/finish"
    cat > "$BIN/claude" <<'SHIM'
#!/usr/bin/env bash
cat /dev/stdin > "$TMP/prompt"
id="$(sed -n 's/^work \(sp-[a-z0-9-]*\) .*/\1/p' "$TMP/prompt" | head -1)"
if [ "$(cat "$TMP/docommit")" = 1 ]; then
    printf 'my work\n' >> f
    git add -A && git -c user.email=a@a -c user.name=aeon commit -qm "$id — the work"
fi
finish="$(cat "$TMP/finish")"
case "$finish" in
    close)       bd -C "$SPIRA_DB" close "$id" --reason "done" >/dev/null 2>&1 ;;
    supersede:*) bd -C "$SPIRA_DB" supersede "$id" --with "${finish#supersede:}" >/dev/null 2>&1 ;;
esac
printf '{"type":"result","subtype":"success","is_error":false,"result":"done","num_turns":3}\n'
exit 0
SHIM
    chmod +x "$BIN/claude"
}
seed() {   # seed <id> [status]
    printf '{"id":"%s","title":"t","status":"%s","issue_type":"task","labels":["spira","plan","repo:fixture"],"updated_at":"2026-09-04T00:00:00Z"}\n' \
        "$1" "${2:-open}" | testdb_seed
}
run_aeon() { rm -rf "$SPIRA_RUN/worktree"; "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1; }
field() { bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get(sys.argv[1]) or "")' "$2" 2>/dev/null; }
notes() { bd -C "$SPIRA_DB" show "$1" 2>/dev/null | tr '\n' ' '; }

echo
echo "closed WITH a commit naming the bead — the check is satisfied and does nothing:"
testdb_reset; seed sp-vd-1; shim 1 close; run_aeon
is     "the bead stays closed"        closed "$(field sp-vd-1 status)"
want   "and the verdict says it committed" "committed=yes" "$(cat "$TMP/out")"
nowant "with no reopen"               "REOPENED"           "$(cat "$TMP/out")"

echo
echo "closed with NOTHING committed — reopened, because closed is not landed:"
testdb_reset; seed sp-vd-2; shim 0 close; run_aeon
is   "the bead is open again"          open "$(field sp-vd-2 status)"
is   "and its claim is released"       ""   "$(field sp-vd-2 assignee)"
want "the verdict names the omission"  "REOPENED — closed with nothing committed" "$(cat "$TMP/out")"
want "and the bead carries the reason" "closed without a commit naming sp-vd-2"   "$(notes sp-vd-2)"

echo
echo "SUPERSEDED with nothing committed — left closed, because its work landed under another id:"
testdb_reset; seed sp-vd-3; seed sp-vd-succ closed; shim 0 supersede:sp-vd-succ; run_aeon
is     "the successor relation was recorded" supersedes \
       "$(bd -C "$SPIRA_DB" show sp-vd-3 --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]
print(next((x.get("dependency_type") or x.get("type") for x in (d[0].get("dependencies") or [])), ""))' 2>/dev/null)"
is     "the bead stays closed"               closed "$(field sp-vd-3 status)"
want   "the verdict records the exemption"   "superseded=1" "$(cat "$TMP/out")"
want   "and says why it declined to act"     "NOT reopened — superseded" "$(cat "$TMP/out")"
nowant "so nothing is reopened"              "REOPENED"    "$(cat "$TMP/out")"
nowant "and no reopen note is written"       "Closed is not landed" "$(notes sp-vd-3)"

# ======================================================================================
echo
echo "a persona with a wall is told when it is killed, in the brief the model receives:"
# ======================================================================================
# THE DEFECT THIS REPRODUCES. A persona that declares FAYTH_TIMEOUT_SECONDS is killed on a
# clock from outside, and its brief asks it, if it cannot finish, to leave what it found in
# the graph rather than in a session that is about to end. It could not know when that was:
# four consecutive sessions on one incident were each killed within a second of the wall and
# left no commit and no bead between them. The wall is not the defect — it is what keeps a
# session from outliving the sweep that produces its work. Not being able to see it is.
#
# ASSERTED AGAINST THE PROMPT THE SHIM RECEIVES, which is the only place the claim is
# meaningful. A check on aeon.sh's source proves the token is mentioned; it cannot tell a
# deadline that renders as a time from one that renders as the empty string, and the empty
# string is what a brief with a `{{DEADLINE}}` in it silently becomes.
printf 'work {{BEAD_ID}} in {{REPO}} on {{BRANCH}}\n{{DEADLINE}}\n{{PARK}}\n' \
    > "$SPIRA_HOME/chamber/builder.md"
walled_fayth() {                # walled_fayth [seconds] — rewrite the fayth, with or without a wall
    { cat <<FAYTH
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
FAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=600
FAYTH
      [ -n "${1:-}" ] && printf 'FAYTH_TIMEOUT_SECONDS=%s\n' "$1"
    } > "$SPIRA_HOME/chamber/builder.fayth"
}

# A NON-DEFAULT WALL. 480 is what the shipped Ops persona declares, so a deadline computed
# from a literal written into aeon.sh would pass against it and fail against nothing.
walled_fayth 300
testdb_reset; seed sp-vd-4; shim 1 close; run_aeon
prompt="$(cat "$TMP/prompt" 2>/dev/null)"
now="$(date +%s)"
nowant "no placeholder reaches the model" "{{" "$prompt"
want   "the brief says the session is killed" "This session is killed at" "$prompt"

# THE EPOCH IS THE PART THAT MATTERS: a clock time tells the aeon when it dies, the epoch is
# what lets it ASK how long is left at any point in the session rather than estimate. It is
# read back out of the prompt and required to fall inside the window the wall implies: after
# now, because the session is still running, and no later than now plus the wall, which is
# where a deadline anchored at the aeon's start can be and a fixed or fabricated one cannot.
epoch="$(printf '%s' "$prompt" | grep -oE 'echo \$\(\( [0-9]+ ' | grep -oE '[0-9]+' | head -1)"
if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ] && [ "$epoch" -le $((now + 300)) ]; then
    ok "and carries a readable epoch inside the window the wall implies"
else
    bad "and carries a readable epoch inside the window the wall implies" \
        "got [$epoch], wanted between $now and $((now + 300))"
fi
left="$(printf '%s' "$prompt" | grep -oE '— [0-9]+ seconds from now' | grep -oE '[0-9]+' | head -1)"
if [ -n "$left" ] && [ "$left" -gt 0 ] && [ "$left" -le 300 ]; then
    ok "and a remaining count that spends what the claim already cost"
else
    bad "and a remaining count that spends what the claim already cost" \
        "got [$left], wanted 1..300"
fi

# THE OTHER HALF, and it is not decoration: a brief that renders `{{DEADLINE}}` as nothing at
# all would satisfy every assertion above if the persona simply had no wall. A persona
# without one must be told so, rather than told nothing.
walled_fayth
testdb_reset; seed sp-vd-5; shim 1 close; run_aeon
prompt="$(cat "$TMP/prompt" 2>/dev/null)"
nowant "a persona with no wall gets no placeholder either" "{{" "$prompt"
want   "and is told plainly that it has no clock" "no wall-clock deadline" "$prompt"
nowant "and is not given a deadline it does not have" "This session is killed at" "$prompt"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
