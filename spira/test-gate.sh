#!/usr/bin/env bash
#
# test-gate.sh — the landing gate judges the branch it was given, and no other.
#
#   ./test-gate.sh
#
# THE DEFECT THIS SUITE EXISTS FOR. The gate extracts the branch under trial into ONE
# worktree per repository, reused across passes. Gates run concurrently by construction —
# every worker runs one before it closes, and the landing pass runs one per branch it is
# about to merge — so each `checkout --detach` pulled the previous run's branch out from
# under it mid-command. Measured: two consecutive runs both exited 0, one of them on a
# branch deliberately broken, because a concurrent gate had swapped the tree between them.
# A gate that passes work it never looked at is the worst failure a gate has, and the
# landing pass acts on the pass.
#
# So the claims here are about identity, not about verdicts:
#
#   • the tree a gate judged held the branch it was asked about — asserted from INSIDE the
#     gate command, which records the branch it was told about beside what the tree actually
#     contained. A pair that disagrees is the defect, in one line.
#   • concurrent gates on different branches each get their own verdict.
#   • the wait is metered — including the wait that runs out, which is the reading that
#     argues the lock has stopped being enough — so serialisation is seen before it is felt.
#   • a gate that cannot obtain the tree, or cannot prove what the tree holds, REFUSES.
#     Both are fails-closed: "could not check" is not a pass.
#
# Against real git, with real worktrees and a real bare remote, because every claim is about
# what git did (law-prefer-the-real-dependency). The one thing faked is the one thing real
# git will not do on demand: a `checkout` that reports success without moving HEAD. That is
# the state the HEAD assertion exists to catch, and a suite that cannot produce it is
# asserting that the assertion compiles.
#
# Each gate run is its own process in an explicit minimal environment
# (law-gates-run-in-a-clean-environment): SPIRA_CONF points at nothing and HOME is
# redirected, so no box's own configuration can decide a verdict here.
#
# covers: spira/gate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want(){ [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }

command -v flock >/dev/null 2>&1 || { echo "  SKIP  flock is not on PATH"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REALGIT="$(command -v git)"

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; MAP="$TMP/repo-map"
RAN="$TMP/ran.log"; HOMEDIR="$TMP/home"
mkdir -p "$RUN/worktree" "$HOMEDIR" "$TMP/bin"

git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
# EVERY BRANCH CARRIES A MARKER NAMING ITSELF, and the base's names the base — so the gate
# command can report which tree it was standing in without being told, and a swapped tree
# shows up as a pair that disagrees rather than as a verdict that happens to be wrong.
printf 'origin/main\n' > "$REPO/marker"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

mkbranch() {             # mkbranch <branch> <marker> [fail]
    local br="$1" mk="$2" bad="${3:-}" w="$TMP/mk"
    rm -rf "$w"
    git -C "$REPO" worktree add -q -b "$br" "$w" origin/main
    printf '%s\n' "$mk" > "$w/marker"
    [ -n "$bad" ] && printf 'no\n' > "$w/fail"
    git -C "$w" add -A
    git -C "$w" commit -q -m "$br"
    git -C "$REPO" worktree remove --force "$w"
}
mkbranch spira/good spira/good
mkbranch spira/bad  spira/bad  fail

# The repository's own gate, declared in the map's sixth column. It sleeps so that two runs
# started together really do overlap — an unlocked tree is only swapped when the runs
# overlap, so a fixture whose gate returns instantly cannot fail on this bug.
CMD="sleep 2; printf '%s %s\\n' \"\$SPIRA_GATE_BRANCH\" \"\$(cat marker)\" >> $RAN; test ! -e fail"
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$CMD" > "$MAP"

TREE="$RUN/worktree/.gate.repo"
GATELOG="$TMP/gate.log"

rungate() {              # rungate <branch> [VAR=VAL ...] -> the gate's own status, output on stdout
    local br="$1"; shift
    env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin" \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        SPIRA_CONF="$TMP/nonexistent.conf" SPIRA_REPO="$REPO" SPIRA_RUN="$RUN" \
        SPIRA_DB="$TMP/nonexistent-db" SPIRA_REPO_MAP="$MAP" SPIRA_GATE_LOG="$GATELOG" \
        "$@" bash "$HERE/gate.sh" "$br" repo 2>&1
}
meter() { cat "$GATELOG" 2>/dev/null; }

echo "the fixture discriminates — the positive control for everything below"
out="$(rungate spira/good)"; rc=$?
is  "a branch its own gate passes exits 0" 0 "$rc"
out="$(rungate spira/bad)";  rc=$?
[ "$rc" -ne 0 ] && ok "a branch its own gate fails does not" || bad "a branch its own gate fails does not" "exited 0: $out"
want "and says whose gate failed" "repo's own gate failed" "$out"
# The failing run re-runs the command against the base to establish whose fault it is, and
# the base passes here — so the branch is told it is the cause, which it is.
is "the tree is left holding the branch" \
   "$(git -C "$REPO" rev-parse spira/bad)" "$(git -C "$TREE" rev-parse HEAD)"

echo "every judgement was made in a tree holding the branch it was told about"
mismatch="$(awk '$1 != $2' "$RAN")"
is "no run judged another branch's tree" "" "$mismatch"
[ "$(wc -l < "$RAN")" -ge 3 ] && ok "and the gate command really ran" \
    || bad "and the gate command really ran" "$(cat "$RAN")"

echo "concurrent gates on different branches"
: > "$RAN"; : > "$GATELOG"
rungate spira/good > "$TMP/out.good" 2>&1 & p1=$!
rungate spira/bad  > "$TMP/out.bad"  2>&1 & p2=$!
wait $p1; rc1=$?
wait $p2; rc2=$?
is "the passing branch still passes" 0 "$rc1"
[ "$rc2" -ne 0 ] && ok "the failing branch still fails" || bad "the failing branch still fails" "exited 0"
mismatch="$(awk '$1 != $2' "$RAN")"
is "and neither judged the other's tree" "" "$mismatch"

# THE METER IS THE POSITIVE CONTROL FOR THE LOCK ITSELF. Two runs that never waited for each
# other are exactly what the unlocked version produced, so "both passed" is not evidence the
# serialisation happened — a recorded wait is.
waited="$(awk -F'waited=' 'NF>1 { split($2, a, "s"); if (a[1] + 0 > 0) n++ } END { print n + 0 }' "$GATELOG")"
[ "$waited" -ge 1 ] && ok "one of them waited for the tree, and the wait is recorded" \
    || bad "one of them waited for the tree, and the wait is recorded" "$(meter)"
want "the meter records the verdict too" "rc=0" "$(meter)"

echo "a gate that cannot obtain the tree refuses"
: > "$RAN"
( flock 9; sleep 4 ) 9>"$TREE.lock" & holder=$!
sleep 0.3
out="$(rungate spira/good SPIRA_GATE_LOCK_WAIT=1)"; rc=$?
[ "$rc" -ne 0 ] && ok "it exits non-zero rather than reporting a pass" \
    || bad "it exits non-zero rather than reporting a pass" "$out"
want "and says there is no verdict" "no verdict" "$out"
want "and says it is a queue, not the branch's fault" "not a fault in the branch" "$out"
is "and the gate command never ran" "" "$(cat "$RAN")"
# THE REFUSAL IS THE READING THE METER EXISTS FOR — a run that waited its whole budget and
# judged nothing is what says the lock has stopped being enough, so a meter that drops it is
# blind exactly where it is needed.
want "and the refusal is metered as a lock-timeout" "rc=1 lock-timeout" "$(meter)"
want "with nothing recorded as having run" "ran=0s" "$(grep lock-timeout "$GATELOG")"
wait $holder 2>/dev/null

echo "a tree that cannot be identified is refused, not judged"
# CONTROL FIRST: the same pre-positioned tree, with real git, is checked out and judged.
git -C "$TREE" checkout -q --force --detach origin/main
: > "$RAN"
out="$(rungate spira/good)"; rc=$?
is "with real git the tree is moved onto the branch and judged" 0 "$rc"
is "and it judged the branch's own tree" "spira/good spira/good" "$(cat "$RAN")"

# A checkout that reports success without moving HEAD. Real git will not do this on demand,
# and it is the exact state the assertion exists to catch: before the lock, a concurrent gate
# produced it for real.
cat > "$TMP/bin/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = checkout ] && exit 0; done
exec "$REALGIT" "\$@"
SHIM
chmod +x "$TMP/bin/git"
git -C "$TREE" checkout -q --force --detach origin/main
: > "$RAN"
out="$(rungate spira/good SPIRA_PATH="$TMP/bin")"; rc=$?
[ "$rc" -ne 0 ] && ok "a HEAD that is not the branch's commit is refused" \
    || bad "a HEAD that is not the branch's commit is refused" "$out"
want "and it says which tree it could not identify" "refusing to judge a tree it cannot identify" "$out"
is "and nothing was judged" "" "$(cat "$RAN")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
