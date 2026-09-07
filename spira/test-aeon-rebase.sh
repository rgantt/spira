#!/usr/bin/env bash
#
# test-aeon-rebase.sh — a bead closed behind its base is brought current, or handed back.
#
# The landing pass rebases a closed bead's branch and, on a conflict, reopens the bead for
# the NEXT aeon — which arrives without the context that wrote the commits. Twelve of the
# first 23 reopens were that. So the brief now asks the session to rebase as its last step,
# and the verdict step in aeon.sh checks it did. Three outcomes, driven through the REAL
# aeon.sh with a shim standing in for the model:
#
#   the session rebased               -> "closed current", nothing touched
#   it did not, replay is clean       -> the harness rebases and says so
#   it did not, replay conflicts      -> reopened, unassigned, the paths named
#
#   ./test-aeon-rebase.sh
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
testdb_require test-aeon-rebase
TMP="$(mktemp -d)"
cleanup_all() { testdb_drop; rm -rf "$TMP"; }
trap cleanup_all EXIT INT TERM
testdb_up aeonrebase || { echo "test-aeon-rebase: could not build a fixture database"; exit 1; }

# A repository WITH A REMOTE, because the base an aeon judges against is the remote-tracking
# ref, and "the base moved" means somebody pushed to it.
ORIGIN="$TMP/origin.git"; git init -q --bare -b main "$ORIGIN"
REPO="$TMP/repo"; git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/f"; printf 'other\n' > "$REPO/g"
git -C "$REPO" add f g; git -C "$REPO" commit -qm seed; git -C "$REPO" push -q origin main 2>/dev/null
# The "other aeon": a second clone that lands on main while the session runs.
OTHER="$TMP/other"; git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
git -C "$OTHER" config user.email o@o; git -C "$OTHER" config user.name other

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

# THE SHIM IS THE SESSION. It runs in the aeon's worktree with SPIRA_DB and BEADS_ACTOR in its
# environment, exactly as the model would. Each case writes its own: what lands on main
# meanwhile, what the session commits, and whether it rebases before closing.
BIN="$TMP/bin"; mkdir -p "$BIN"; export SPIRA_CLAUDE="$BIN/claude"
grep -q 'SPIRA_CLAUDE' "$HERE/aeon.sh" \
    || { echo "test-aeon-rebase: aeon.sh has no SPIRA_CLAUDE injection point — refusing to run the real model" >&2; exit 1; }
shim() {   # shim <main-touches-file> <session-rebases:0|1>
    cat > "$BIN/claude" <<SHIM
#!/usr/bin/env bash
cat /dev/stdin > "$TMP/prompt"
id="\$(sed -n 's/^work \\(sp-[a-z0-9-]*\\) .*/\\1/p' "$TMP/prompt" | head -1)"
# somebody else lands on main while this session works
printf 'landed meanwhile\\n' >> "$OTHER/$1"
git -C "$OTHER" add -A && git -C "$OTHER" commit -qm "somebody else" && git -C "$OTHER" push -q origin main 2>/dev/null
# this session's own work, on the branch, naming the bead
printf 'my work\\n' >> f
git add -A && git -c user.email=a@a -c user.name=aeon commit -qm "\$id — the work"
if [ "$2" = 1 ]; then git fetch -q origin && git rebase -q origin/main >/dev/null 2>&1; fi
bd -C "\$SPIRA_DB" close "\$id" --reason "done" >/dev/null 2>&1
printf '{"type":"result","subtype":"success","is_error":false,"result":"done","num_turns":3}\\n'
exit 0
SHIM
    chmod +x "$BIN/claude"
}
seed_bead() {   # seed_bead <id>
    testdb_reset
    printf '{"id":"%s","title":"t","status":"open","issue_type":"task","labels":["spira","plan","repo:fixture"],"updated_at":"2026-09-04T00:00:00Z"}\n' "$1" \
        | testdb_seed
}
run_aeon() { rm -rf "$SPIRA_RUN/worktree"; "$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1; }
field() { bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get(sys.argv[1]) or "")' "$2" 2>/dev/null; }
notes() { bd -C "$SPIRA_DB" show "$1" 2>/dev/null | tr '\n' ' '; }
current() { git -C "$REPO" fetch -q origin; git -C "$REPO" merge-base --is-ancestor origin/main "refs/heads/spira/$1" && echo yes || echo no; }

echo
echo "the brief names the rebase as the last step:"
seed_bead sp-rb-0; shim g 1; run_aeon
want "the session is told to rebase before closing" "Before you close: rebase onto" "$(cat "$TMP/prompt")"
want "onto the resolved base, by name"               "rebase origin/main"          "$(cat "$TMP/prompt")"

echo
echo "the session rebased:"
seed_bead sp-rb-1; shim g 1; run_aeon
is   "the bead stays closed"                 closed "$(field sp-rb-1 status)"
is   "and its branch is current with main"   yes    "$(current sp-rb-1)"
want "the verdict says current"              "closed current with origin/main" "$(cat "$TMP/out")"
nowant "and adds no note"                    "Rebased onto"  "$(notes sp-rb-1)"

echo
echo "the session did not, and the replay is clean:"
seed_bead sp-rb-2; shim g 0; run_aeon
is   "the bead stays closed"                 closed "$(field sp-rb-2 status)"
is   "the harness brought the branch current" yes   "$(current sp-rb-2)"
want "and says so, naming the session's omission" "rebased by the harness after close" "$(cat "$TMP/out")"
want "and the bead carries the note"         "Rebased onto origin/main by aeon.sh" "$(notes sp-rb-2)"
is   "the work survived the replay"          "seed
my work" "$(git -C "$REPO" show "spira/sp-rb-2:f")"

echo
echo "the session did not, and the replay conflicts:"
seed_bead sp-rb-3; shim f 0; run_aeon
is   "the bead is reopened"                  open   "$(field sp-rb-3 status)"
is   "and unassigned, so the next aeon can claim the rebase" "" "$(field sp-rb-3 assignee)"
want "the log names the conflict"            "REOPENED — closed behind origin/main, conflicts in f" "$(cat "$TMP/out")"
want "the note names the file and the ask"   "conflicts in f" "$(notes sp-rb-3)"
is   "the branch is left as the session made it" no "$(current sp-rb-3)"
is   "with its commit intact"                "seed
my work" "$(git -C "$REPO" show "spira/sp-rb-3:f")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
