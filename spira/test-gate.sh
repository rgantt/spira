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
# THE VERDICT CACHE IS THE SUITE'S OWN, and most blocks below clear it first. A cached PASS
# is a correct answer and an unhelpful one here: nearly every case in this file is about what
# happens while a verdict is being COMPUTED — the lock, the tree's identity, whose fault a red
# is — and none of that is reachable on a run that legitimately skipped the trial. It also
# keeps the suite off the box's real cache, which would otherwise make these results depend on
# what had been gated on this machine earlier (law-gates-run-in-a-clean-environment).
VDIR="$TMP/verdicts"
nocache() { rm -rf "$VDIR"; }

rungate() {              # rungate <branch> [VAR=VAL ...] -> the gate's own status, output on stdout
    local br="$1"; shift
    env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin" \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        SPIRA_CONF="$TMP/nonexistent.conf" SPIRA_REPO="$REPO" SPIRA_RUN="$RUN" \
        SPIRA_DB="$TMP/nonexistent-db" SPIRA_REPO_MAP="$MAP" SPIRA_GATE_LOG="$GATELOG" \
        SPIRA_VERDICTS="$VDIR" \
        "$@" bash "$HERE/gate.sh" "$br" repo 2>&1
}
meter() { cat "$GATELOG" 2>/dev/null; }

echo "the fixture discriminates — the positive control for everything below"
nocache
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

# ======================================================================================
# FOUR OUTCOMES — whose fault the gate says it is. Nothing lands on any of the three
# non-PASS outcomes; what is under test is WHO IS CHARGED, because that is what decides
# whether a bead is reopened and walked toward poison. Every one of these arrived at the
# landing pass as a bare "this branch failed" before conf.sh gave them separate statuses.
# ======================================================================================
echo "four outcomes, and only one of them blames the branch"
nocache
verdict_of() { sed -n 's/^gate: VERDICT=\([A-Z_]*\) .*$/\1/p' <<< "$1" | tail -1; }
reason_of()  { sed -n 's/^gate: VERDICT=[A-Z_]* reason=\([^ ]*\).*$/\1/p' <<< "$1" | tail -1; }

# CONTROL: the ordinary red. Its own gate fails, the same command passes on the base, so the
# branch is genuinely at fault and this is the one outcome that may cost it an attempt.
out="$(rungate spira/bad)"; rc=$?
is   "a branch that fails a gate its base passes is FAIL" 1 "$rc"
is   "and says so in one machine-readable line" "FAIL" "$(verdict_of "$out")"
is   "naming the reason"                        "branch-red" "$(reason_of "$out")"
want "and it still says whose gate failed"      "repo's own gate failed" "$out"

# BASE_FAIL: the same command fails on the base too. Five beads were reopened as "failed the
# gate" on 2026-09-06 in the same breath as the gate saying "this branch did not cause it"
# (sp-d21) — the sentence existed, the status did not, and only the status is read.
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "test ! -e marker" > "$MAP"
out="$(rungate spira/good)"; rc=$?
is   "a command that fails on the base too is BASE_FAIL" 76 "$rc"
is   "and says so"                             "BASE_FAIL" "$(verdict_of "$out")"
want "and names the base, not the branch"      "did not cause it" "$out"
[ "$rc" -ne 1 ] && ok "and it is NOT the branch's FAIL status" \
    || bad "and it is NOT the branch's FAIL status" "rc=1"

# NO_VERDICT on a deadline. gate-spira.sh prints nothing while suites pass, so a run killed
# at its budget produced an EMPTY tail -20 and a bead note with nothing in it (sp-p4rl). The
# budget is the harness's; no branch can fix it.
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "sleep 30" > "$MAP"
out="$(rungate spira/good SPIRA_GATE_TIMEOUT=1)"; rc=$?
is   "a gate killed at its deadline is NO_VERDICT" 75 "$rc"
is   "and says so"                                "NO_VERDICT" "$(verdict_of "$out")"
is   "naming the deadline as the reason"          "timeout" "$(reason_of "$out")"
want "and says it is the harness's budget"        "not a fault in the branch" "$out"

# A SILENT RED IS STILL THE BRANCH'S. `test -e fail` fails on spira/good and prints nothing,
# which is an ordinary shape for a gate command — and the first version of this rule
# downgraded every such red to NO_VERDICT, which would have let a genuinely broken branch
# retry forever and then escalate as a lock that does not exist. What it owes the reader is
# reproducibility, not silence.
# The command must PASS on the base and FAIL on the branch, or this is BASE_FAIL and the
# assertion is about the wrong outcome — which is exactly what the first version measured.
SILENT='test "$(cat marker)" = origin/main'
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$SILENT" > "$MAP"
out="$(rungate spira/good)"; rc=$?
is   "a red that printed nothing is still FAIL"  1 "$rc"
want "and the note says the command said nothing" "printed nothing" "$out"
want "and names the command, so it can be re-run" "cat marker" "$out"

# THE MACHINERY FAULTS IN THE PREFLIGHT. Each of these exited 1 before, indistinguishable
# from a branch that broke a suite; one of them (sp-io5j) exited without printing anything.
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$CMD" > "$MAP"
out="$(rungate spira/nosuchbranch)"; rc=$?
is   "a branch that does not resolve is NO_VERDICT" 75 "$rc"
want "and says which diff it could not take"       "cannot diff" "$out"

# Passed as a rungate ARGUMENT, not a shell prefix: rungate runs the gate under `env -i`,
# which wipes the caller's environment, so a prefix would be silently discarded and the
# assertion would be about the ordinary map.
out="$(rungate spira/good SPIRA_REPO_MAP="$TMP/nosuchmap")"; rc=$?
is   "an unreadable repository map is NO_VERDICT, not a PASS" 75 "$rc"
want "and says why a missing map cannot mean 'no gate'" "a trial that never ran" "$out"

# EVERY EXIT IS METERED EXACTLY ONCE. verdict() disarms the EXIT trap so a run cannot be
# recorded twice — the second time with the status of whatever ran last inside the trap.
: > "$GATELOG"
rungate spira/good >/dev/null 2>&1
is "one run writes exactly one meter line" 1 "$(wc -l < "$GATELOG")"
want "and the meter carries the reason"    "pass" "$(meter)"

printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$CMD" > "$MAP"

# ======================================================================================
# D1 — A VERDICT IS COMPUTED ONCE. Every bead paid this gate at least twice: once by the aeon
# before it closed, once by the landing pass on the same tree minutes later. 150 aeon runs
# across 51 sessions, 380-620s each (sp-0v8). The reuse is what makes the DONE-to-LANDED
# stretch cheap, and it is also most of what made the shared tree worth contending for.
# ======================================================================================
echo "a verdict is computed once and keyed by what it judged"
ranlines() { wc -l < "$RAN" | tr -d ' '; }

rm -rf "$VDIR"; : > "$RAN"; : > "$GATELOG"
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$CMD" > "$MAP"
out="$(rungate spira/good)"; rc=$?
is "the first run passes"            0 "$rc"
is "and the command really ran"      1 "$(ranlines)"
is "and it was not a cache hit"      "pass" "$(reason_of "$out")"

out="$(rungate spira/good)"; rc=$?
is   "the second run on the same tree passes"        0 "$rc"
is   "and says it reused the verdict"                "cached" "$(reason_of "$out")"
is   "and the gate command did NOT run again"        1 "$(ranlines)"
want "and names the key, so a wrong reuse is chaseable" "key " "$out"
# THE METER STILL WRITES. A reused verdict that left no row would be indistinguishable in the
# log from a gate that was never called — which is the shape every silent-skip bug takes.
is "a reused verdict is still metered"  2 "$(wc -l < "$GATELOG")"

# THE CACHE IS KEYED ON THE HARNESS TOO. gate.sh, exclude.sh and skew.sh are layer 1 of the
# trial, so a pass recorded before they changed is a verdict from a gate that no longer
# exists. Without this the cache would silently vouch for work the current gate never saw —
# the one way a pure cache can produce a wrong answer.
# Against a COPY of the harness, never by editing the one under test: a suite that mutates
# its own source leaves it corrupted if it dies between the edit and the restore, and this
# harness is the thing every other suite here is judged by.
rm -rf "$TMP/h2"; cp -r "$HERE" "$TMP/h2"
printf '\n# a change to layer 1 of the trial\n' >> "$TMP/h2/gate.sh"
: > "$RAN"
env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    SPIRA_CONF="$TMP/nonexistent.conf" SPIRA_REPO="$REPO" SPIRA_RUN="$RUN" \
    SPIRA_DB="$TMP/nonexistent-db" SPIRA_REPO_MAP="$MAP" SPIRA_GATE_LOG="$GATELOG" \
    SPIRA_VERDICTS="$VDIR" bash "$TMP/h2/gate.sh" spira/good repo >/dev/null 2>&1
is "a changed harness invalidates the cached pass" 1 "$(ranlines)"

# AND ON THE COMMAND. A repository that changes what its gate runs has changed what a pass
# means.
: > "$RAN"
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$CMD ; true" > "$MAP"
out="$(rungate spira/good)"
is "a changed gate command invalidates it too" 1 "$(ranlines)"
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$CMD" > "$MAP"

# A FAIL IS NEVER CACHED. A red is not a pure function of the tree — a flaky suite fails once
# and passes next run — so caching one would pin a flake to a branch permanently. The cache
# may only ever save work; it may never manufacture a verdict.
rm -rf "$VDIR"; : > "$RAN"
rungate spira/bad >/dev/null 2>&1; first="$(ranlines)"
rungate spira/bad >/dev/null 2>&1; second="$(ranlines)"
[ "$second" -gt "$first" ] && ok "a failing gate is re-run, never cached" \
    || bad "a failing gate is re-run, never cached" "ran $first then $second"

# NOR IS A WITHHELD VERDICT — retrying is its whole meaning.
rm -rf "$VDIR"; : > "$RAN"
( flock 9; sleep 3 ) 9>"$TREE.lock" & vholder=$!
sleep 0.3
rungate spira/good SPIRA_GATE_LOCK_WAIT=1 >/dev/null 2>&1
wait $vholder 2>/dev/null
is "a withheld verdict records nothing to reuse" 0 "$(ls "$VDIR" 2>/dev/null | wc -l | tr -d ' ')"
out="$(rungate spira/good)"
is "so the next run really judges the tree" "pass" "$(reason_of "$out")"

echo "concurrent gates on different branches"
nocache
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
nocache
: > "$RAN"
( flock 9; sleep 4 ) 9>"$TREE.lock" & holder=$!
sleep 0.3
out="$(rungate spira/good SPIRA_GATE_LOCK_WAIT=1)"; rc=$?
[ "$rc" -ne 0 ] && ok "it exits non-zero rather than reporting a pass" \
    || bad "it exits non-zero rather than reporting a pass" "$out"
want "and says there is no verdict" "no verdict" "$out"
want "and says it is a queue, not the branch's fault" "not a fault in the branch" "$out"
is "and the gate command never ran" "" "$(cat "$RAN")"
# "NO VERDICT" MUST BE TELLABLE FROM "FAILED" BY EXIT STATUS ALONE, because that is all its
# caller has: the landing pass reopens a bead on a red gate, and a queue read as red charges
# the wait to a branch that was never judged. Asserted against the branch that really does
# fail, so this pins the two apart rather than pinning one number.
is "the withheld verdict has its own exit status" 75 "$rc"
noverdict_rc=$rc
# THE REFUSAL IS THE READING THE METER EXISTS FOR — a run that waited its whole budget and
# judged nothing is what says the lock has stopped being enough, so a meter that drops it is
# blind exactly where it is needed.
want "and the refusal is metered as a lock-timeout" "rc=75 lock-timeout" "$(meter)"
want "with nothing recorded as having run" "ran=0s" "$(grep lock-timeout "$GATELOG")"
wait $holder 2>/dev/null
# PINNED APART FROM A REAL FAILURE, not merely pinned to a number — run once the holder has
# gone, so this run is judged rather than queued behind it.
rungate spira/bad >/dev/null 2>&1; redrc=$?
[ "$redrc" -ne "$noverdict_rc" ] && ok "and a branch that genuinely fails does not share it" \
    || bad "and a branch that genuinely fails does not share it" "both exited $noverdict_rc"

echo "the tree lock does not outlive the gate through a daemon it started"
nocache
# `exec 9>lock` HAS NO CLOSE-ON-EXEC, so every child of the gate inherits the descriptor, and
# flock is held for as long as ANY holder of it lives. A repository's gate builds fixtures and
# can leave a server running; that server would go on holding this repository's tree long after
# the gate that started it exited, and the lock would stop being a queue and become a deadlock
# — every later gate waiting out its whole budget and withholding its verdict, with nothing
# visibly holding anything. The fixture lock failed exactly this way within an hour of landing.
#
# THE CONTROL IS THE BLOCK IMMEDIATELY ABOVE: the same one-second wait, against a lock that IS
# held, returns 75 and runs nothing. So a pass here is evidence the descriptor was closed,
# rather than evidence that a one-second wait always succeeds.
: > "$RAN"
DAEMONS="$TMP/daemons.pid"; : > "$DAEMONS"
# Its output goes to /dev/null deliberately: a lingering child holding the gate's stdout would
# keep the `tail` at the end of that pipeline waiting for EOF, and the run would hang on the
# daemon rather than leak a lock to it. Only the descriptor under test is left alone.
DAEMON_CMD="sleep 20 >/dev/null 2>&1 </dev/null & echo \$! >> $DAEMONS; printf '%s %s\\n' \"\$SPIRA_GATE_BRANCH\" \"\$(cat marker)\" >> $RAN; true"
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$DAEMON_CMD" > "$MAP"
out="$(rungate spira/good)"; rc=$?
is "a gate whose command leaves a process running still passes" 0 "$rc"
is "and it judged its own tree" "spira/good spira/good" "$(cat "$RAN")"
[ -s "$DAEMONS" ] && ok "and the process really is still there" \
    || bad "and the process really is still there" "no pid was recorded"
# The cache is cleared so this run really TAKES the tree — the claim here is about the
# descriptor the daemon inherited, and a run that reused a verdict would touch no lock at all
# and pass this assertion while proving nothing.
: > "$RAN"; nocache
out="$(rungate spira/good SPIRA_GATE_LOCK_WAIT=1)"; rc=$?
is "the next gate takes the tree instead of queueing behind the daemon" 0 "$rc"
is "and judged the branch it was given" "spira/good spira/good" "$(cat "$RAN")"
while read -r d; do kill "$d" 2>/dev/null; done < "$DAEMONS"
printf 'repo | %s | push | origin/main |  | %s\n' "$REPO" "$CMD" > "$MAP"

echo "a tree that cannot be identified is refused, not judged"
nocache
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
# Cleared, because the control immediately above recorded a pass for this exact tree — and
# reusing it would skip the checkout whose failure is the entire subject of this case.
: > "$RAN"; nocache
out="$(rungate spira/good SPIRA_PATH="$TMP/bin")"; rc=$?
[ "$rc" -ne 0 ] && ok "a HEAD that is not the branch's commit is refused" \
    || bad "a HEAD that is not the branch's commit is refused" "$out"
want "and it says which tree it could not identify" "refusing to judge a tree it cannot identify" "$out"
is "and nothing was judged" "" "$(cat "$RAN")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
