#!/usr/bin/env bash
#
# test-slay.sh — an aeon can be stopped by hand and the bead, the branch and the ledger tell
# the truth afterwards, with no attempt charged.
#
#   ./test-slay.sh
#
# covers: spira/slay.sh spira/aeon.sh spira/chamber/*
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
testdb_require test-slay
TMP="$(mktemp -d)"; KIDS=()
cleanup_all() { for p in "${KIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; testdb_drop; rm -rf "$TMP"; }
trap cleanup_all EXIT INT TERM
testdb_up slay || { echo "test-slay: could not build a fixture database"; exit 1; }

ORIGIN="$TMP/origin.git"; git init -q --bare -b main "$ORIGIN"
REPO="$TMP/repo"; git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm seed; git -C "$REPO" push -q origin main 2>/dev/null
export SPIRA_HOME="$TMP/home"; mkdir -p "$SPIRA_HOME/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/aeon.sh" "$HERE/slay.sh" "$SPIRA_HOME/"
cp -r "$HERE/actors" "$SPIRA_HOME/" 2>/dev/null || true
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN/worktree"
export SPIRA_REPO_MAP="$TMP/repo-map"; printf 'fixture | %s | push | origin/main | |\n' "$REPO" > "$SPIRA_REPO_MAP"
cat > "$SPIRA_HOME/chamber/builder.fayth" <<FAYTH
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
FAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=600
FAYTH
printf 'work {{BEAD_ID}} in {{REPO}} on {{BRANCH}}\n{{PARK}}\n' > "$SPIRA_HOME/chamber/builder.md"
B() { bd -C "$SPIRA_DB" "$@"; }
field() { B show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get(sys.argv[1]) or "")' "$2" 2>/dev/null; }
labels() { B label list "$1" 2>/dev/null | tr -d ' ' | tr '\n' ' '; }
notes()  { B show "$1" 2>/dev/null | tr '\n' ' '; }
seed_bead() { testdb_reset; printf '{"id":"%s","title":"t","status":"open","issue_type":"task","labels":["spira","plan","repo:fixture"],"updated_at":"2026-09-04T00:00:00Z"}\n' "$1" | testdb_seed; }
# A claimed bead with a branch, a worktree holding a commit and a dirty file, and a fake
# aeon: a sleeping process registered exactly as aeon.sh registers itself.
held() {   # held <id>
    seed_bead "$1"
    BEADS_ACTOR=aeon-fake B update "$1" --claim >/dev/null 2>&1
    B label add "$1" "branch:spira/$1" >/dev/null 2>&1
    git -C "$REPO" worktree add -q -b "spira/$1" "$SPIRA_RUN/worktree/$1" origin/main 2>/dev/null
    printf 'work\n' >> "$SPIRA_RUN/worktree/$1/f"
    git -C "$SPIRA_RUN/worktree/$1" -c user.email=a@a -c user.name=aeon commit -qam "$1 — the work"
    printf 'unsaved\n' > "$SPIRA_RUN/worktree/$1/scratch.txt"
    sleep 600 & KIDS+=("$!"); echo "$!" > "$SPIRA_RUN/aeon-builder-$1.pid"; echo fake > "$SPIRA_RUN/aeon-builder-$1.name"
}
slay() { "$SPIRA_HOME/slay.sh" "$@" 2>&1; }

echo "stop, release, nuke:"
held sp-sl-1; p=$(cat "$SPIRA_RUN/aeon-builder-sp-sl-1.pid"); tip=$(git -C "$REPO" rev-parse --short spira/sp-sl-1)
out="$(slay sp-sl-1 --why "duplicate of work on main")"
[ -d "/proc/$p" ] && bad "the process is gone" "pid $p alive" || ok "the process is gone"
[ -e "$SPIRA_RUN/aeon-builder-sp-sl-1.pid" ] && bad "the pid file is gone" "still there" || ok "the pid file is gone"
is   "the bead is open"                    open "$(field sp-sl-1 status)"
is   "and unassigned"                      ""   "$(field sp-sl-1 assignee)"
nowant "and no longer names the branch"    "branch:spira/sp-sl-1" "$(labels sp-sl-1)"
want "the note says why and by whom"       "Slain by the operator: duplicate of work on main" "$(notes sp-sl-1)"
want "and carries the deleted tip's sha"   "deleted at $tip" "$(notes sp-sl-1)"
git -C "$REPO" show-ref --verify -q refs/heads/spira/sp-sl-1 && bad "the branch is deleted" "still exists" || ok "the branch is deleted"
[ -d "$SPIRA_RUN/worktree/sp-sl-1" ] && bad "the worktree is removed" "still there" || ok "the worktree is removed"
ls "$SPIRA_RUN"/reaped/sp-sl-1.*.patch >/dev/null 2>&1 && ok "the dirty file was salvaged first" || bad "the dirty file was salvaged first" "no patch in $SPIRA_RUN/reaped"
want "it reports success"                  "slain: sp-sl-1" "$out"

echo
echo "close instead of reopen:"
held sp-sl-2
out="$(slay sp-sl-2 --close "done on main as f5b53f5")"
is   "the bead is closed"                  closed "$(field sp-sl-2 status)"
want "with the operator's reason first"    "done on main as f5b53f5" "$(notes sp-sl-2)"
is   "and unassigned"                      ""     "$(field sp-sl-2 assignee)"

echo
echo "keep the work:"
held sp-sl-3
out="$(slay sp-sl-3 --keep-work)"
git -C "$REPO" show-ref --verify -q refs/heads/spira/sp-sl-3 && ok "the branch survives" || bad "the branch survives" "deleted"
[ -d "$SPIRA_RUN/worktree/sp-sl-3" ] && ok "so does the worktree" || bad "so does the worktree" "removed"
want "and the bead still names the branch" "branch:spira/sp-sl-3" "$(labels sp-sl-3)"
is   "but it is released"                  ""     "$(field sp-sl-3 assignee)"

echo
echo "no aeon running: the bead and the work are still set right:"
held sp-sl-4; kill "$(cat "$SPIRA_RUN/aeon-builder-sp-sl-4.pid")" 2>/dev/null; sleep 0.5
out="$(slay sp-sl-4)"
want "it says no aeon was running"         "none running" "$out"
is   "and still releases the bead"         "" "$(field sp-sl-4 assignee)"
want "and still reports success"           "slain: sp-sl-4" "$out"

echo
echo "aeon.sh honours the marker: slain is not failed:"
BIN="$TMP/bin"; mkdir -p "$BIN"; export SPIRA_CLAUDE="$BIN/claude"
grep -q 'SPIRA_CLAUDE' "$HERE/aeon.sh" || { echo "no SPIRA_CLAUDE injection point — refusing to run the real model" >&2; exit 1; }
cat > "$BIN/claude" <<SHIM
#!/usr/bin/env bash
cat /dev/stdin > /dev/null
id="\$(basename "\$PWD")"
printf '%s\tby the suite\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SPIRA_RUN/\$id.slain"
exit 143
SHIM
chmod +x "$BIN/claude"
seed_bead sp-sl-5; rm -rf "$SPIRA_RUN/worktree/sp-sl-5"
"$SPIRA_HOME/aeon.sh" builder > "$TMP/out" 2>&1
is   "the bead is released, open"          open "$(field sp-sl-5 status)"
is   "and unassigned"                      ""   "$(field sp-sl-5 assignee)"
nowant "no attempt was charged"            "sp-attempt-" "$(labels sp-sl-5)"
want "the log says slain, not failed"      "slain — released, no attempt charged" "$(cat "$TMP/out")"
want "and so does the ledger"              "status=slain" "$(cat "$SPIRA_RUN/aeon-ledger.log" 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
