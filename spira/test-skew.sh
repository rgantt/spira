#!/usr/bin/env bash
#
# test-skew.sh — landed is not in effect, and this is the suite that proves the check saying
# so can go red.
#
#   ./test-skew.sh
#
# THE DEFECT UNDER TEST is a silent one, and that shapes every assertion here. When the
# harness exists in two trees, work aimed at it lands in one and the other goes on running.
# Nothing reports a fault, because the tree that was edited is self-consistent: its suites
# pass, its gate is satisfied, its bead closes naming a real commit on a real branch. So the
# assertions that carry the weight are the ones that prove a REFUSAL and a FINDING, not the
# ones that prove a pass — a skew.sh that always exits 0 satisfies every "this box is fine"
# assertion in this file and every real invocation, silently, until the day it matters
# (law-absence-needs-a-positive-control).
#
# Against real git repositories in a temp directory. Repository identity here is a claim
# about what git does with worktrees and common directories, and a hand-written model of
# that reproduces the surface I remember rather than the one that decides the verdict.
#
# In an explicit, minimal environment: SPIRA_CONF is pointed at a file that does not exist,
# so the operator's real configuration cannot decide an assertion, and every fixture value
# is pinned to a NON-DEFAULT where one exists — asserting against the shipped default passes
# just as well if the code has the literal written into it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

SH="$TMP/spira"; RUN="$TMP/run"; WS="$TMP/ws"
mkdir -p "$SH" "$RUN" "$WS"
cp "$HERE/conf.sh" "$HERE/lib.sh" "$HERE/exclude.sh" "$HERE/skew.sh" "$SH/"

# The harness signature is three files in one directory. It is exclude.sh's definition and
# this suite deliberately does not restate it as a list — it plants the files and lets the
# real matcher find them, so a change to the signature fails here rather than passing here
# and failing in production.
sig() { local d="$1"; mkdir -p "$d"; : > "$d/boundary"; : > "$d/gate.sh"; : > "$d/lib.sh"; }

commit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -q -m "${2:-c}" >/dev/null 2>&1; }

# home — the harness's OWN repository: the signature at the root, which is the shape a
# repository that exists to hold the harness has.
git init -q -b main "$WS/home"
sig "$WS/home"; printf 'x\n' > "$WS/home/aeon.sh"
commit "$WS/home" base

# guest — an ordinary repository that has quietly grown a SECOND copy of the harness, in a
# subdirectory, alongside a thousand files of its own. This is the fixture the whole bead is
# about.
git init -q -b main "$WS/guest"
sig "$WS/guest/.tools/spira"; printf 'x\n' > "$WS/guest/.tools/spira/aeon.sh"
mkdir -p "$WS/guest/src"; printf 'fn main() {}\n' > "$WS/guest/src/main.rs"
commit "$WS/guest" base

# plain — an ordinary repository carrying no harness at all. Most repositories are this, and
# a fence that touched them would be overridden by reflex within a day.
git init -q -b main "$WS/plain"
printf 'hello\n' > "$WS/plain/README.md"
commit "$WS/plain" base

# `base` is a LOCAL branch on purpose. These fixtures have no remote, so a declared base is
# the only ref that can be resolved — and it also pins the column to a non-default, which is
# what stops an assertion passing against a `main` written into the code.
cat > "$SH/repo-map" <<MAP
home  | $WS/home  | push | main |  |
guest | $WS/guest | pr   | main |  |
plain | $WS/plain | pr   | main |  |
MAP

export SPIRA_CONF=/nonexistent-spira-conf
export SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB=/nonexistent-spira-db
export SPIRA_REPO="$WS/home" SPIRA_HOME_REPO=home
export SPIRA_NOTIFY="$TMP/notify.sh"

# The escalation seam, stubbed to a log. What is being asserted is that an ask is RAISED and
# that it carries its evidence, not what the cockpit does with it afterwards.
cat > "$TMP/notify.sh" <<'N'
#!/usr/bin/env bash
{ printf '=== ask\n'; printf '%s\n' "$@"; } >> "$NOTIFY_LOG"
N
chmod +x "$TMP/notify.sh"
export NOTIFY_LOG="$TMP/asks.log"; : > "$NOTIFY_LOG"

# shellcheck disable=SC1091
. "$SH/lib.sh"
SKEW="$SH/skew.sh"

echo "test-skew.sh"

# =======================================================================================
# Repository identity. Everything else rests on this: a worktree and its checkout are ONE
# repository, and a fence that thought otherwise would refuse every aeon's branch, since
# every aeon works in a worktree.
# =======================================================================================
git -C "$WS/home" worktree add -q --detach "$TMP/home-wt" main 2>/dev/null
spira_same_repo "$WS/home" "$TMP/home-wt" \
    && ok "a worktree is the same repository as its checkout" \
    || bad "a worktree is the same repository as its checkout" "spira_same_repo said no"
spira_same_repo "$WS/home" "$WS/guest" \
    && bad "two checkouts are different repositories" "spira_same_repo said they are the same" \
    || ok "two checkouts are different repositories"
spira_same_repo "$WS/home" "$TMP/not-a-repo" \
    && bad "a non-repository is not the same as anything" "said yes" \
    || ok "a path that is not a repository answers no rather than yes"

# =======================================================================================
# foreign — the landing gate's fence, proved in BOTH directions.
# =======================================================================================
br() {                   # br <repo> <branch> <path> — a branch touching exactly that path
    git -C "$WS/$1" checkout -q -b "$2" main 2>/dev/null
    mkdir -p "$(dirname "$WS/$1/$3")"; printf 'changed\n' >> "$WS/$1/$3"
    commit "$WS/$1" "$2"
    git -C "$WS/$1" checkout -q main
}

br guest touches-harness .tools/spira/aeon.sh
out="$("$SKEW" foreign "$WS/guest" main touches-harness 2>&1)"; rc=$?
is   "a branch changing a vendored harness is refused" 1 "$rc"
want "the refusal names the offending path" ".tools/spira/aeon.sh" "$out"
want "the refusal says where the work belongs" "repo:home" "$out"
want "the refusal names its own override" "SPIRA_ALLOW_FOREIGN_HARNESS" "$out"

br guest touches-src src/main.rs
"$SKEW" foreign "$WS/guest" main touches-src >/dev/null 2>&1
is "ordinary work in a repository that HOLDS a copy is allowed" 0 "$?"

br guest touches-both src/lib.rs
git -C "$WS/guest" checkout -q touches-both
printf 'changed\n' >> "$WS/guest/.tools/spira/aeon.sh"; commit "$WS/guest" both
git -C "$WS/guest" checkout -q main
out="$("$SKEW" foreign "$WS/guest" main touches-both 2>/dev/null)"; rc=$?
is     "a mixed branch is refused" 1 "$rc"
want   "it names the harness path" ".tools/spira/aeon.sh" "$out"
nowant "it does not name the repository's own file" "src/lib.rs" "$out"

br plain touches-readme README.md
"$SKEW" foreign "$WS/plain" main touches-readme >/dev/null 2>&1
is "a repository with no harness in it is not this fence's business" 0 "$?"

# THE EXEMPTION, AND THE PROOF THAT IT IS AN EXEMPTION. The harness's own repository must be
# let through — that is what the fence exists to redirect work TO. But "exit 0" proves
# nothing on its own: an always-0 fence gives the same answer. So the SAME branch is run
# twice, differing only in which repository the harness is installed in.
br home touches-own gate.sh
"$SKEW" foreign "$WS/home" main touches-own >/dev/null 2>&1
is "the harness's own repository is exempt" 0 "$?"
SPIRA_REPO="$WS/plain" "$SKEW" foreign "$WS/home" main touches-own >/dev/null 2>&1
is "and it is an exemption, not an always-pass — the same branch elsewhere is refused" 1 "$?"

SPIRA_ALLOW_FOREIGN_HARNESS=1 "$SKEW" foreign "$WS/guest" main touches-harness >/dev/null 2>&1
is "the override the refusal names actually works" 0 "$?"

# The fence must see the copy in the REF, not in the checkout: a branch may be the thing that
# adds the second harness, and by then nothing is on disk to find.
git -C "$WS/plain" checkout -q -b adds-harness main
sig "$WS/plain/vendor/spira"; commit "$WS/plain" "vendor a harness"
git -C "$WS/plain" checkout -q main
out="$("$SKEW" foreign "$WS/plain" main adds-harness 2>&1)"; rc=$?
is   "a branch that ADDS a second harness is refused" 1 "$rc"
want "and names what it added" "vendor/spira" "$out"

# =======================================================================================
# copies — the map's answer, and its refusal to answer about nothing.
# =======================================================================================
out="$("$SKEW" copies 2>/dev/null)"; rc=$?
is   "copies exits 0 when it found a harness" 0 "$rc"
want "the home repository is reported as self" "home $WS/home . self" "$out"
want "the guest's vendored copy is reported as second" "guest $WS/guest .tools/spira second" "$out"
nowant "a repository with no harness is not listed" "plain" "$out"

cat > "$TMP/empty-map" <<MAP
plain | $WS/plain | pr | main |  |
MAP
SPIRA_REPO_MAP="$TMP/empty-map" SPIRA_REPO="$WS/plain" SPIRA_HOME_REPO=plain \
    "$SKEW" copies >/dev/null 2>&1
is "a map in which nothing carries a harness exits 3, never 0" 3 "$?"

# =======================================================================================
# check — the standing audit. One finding at a time, each proved to fire and then cleared.
# =======================================================================================
# The clean baseline uses a map naming ONLY the home repository, because the guest's second
# copy is a real finding and would mask every other assertion.
cat > "$TMP/solo-map" <<MAP
home | $WS/home | push | main |  |
MAP
solo() { SPIRA_REPO_MAP="$TMP/solo-map" "$@"; }

git -C "$WS/home" checkout -q main
out="$(solo "$SKEW" check 2>&1)"; rc=$?
is   "a current, clean, single-copy box reports in effect" 0 "$rc"
want "and says so rather than saying nothing" "in effect" "$out"
[ ! -s "$NOTIFY_LOG" ] && ok "nothing was escalated on a clean box" \
                       || bad "nothing was escalated on a clean box" "$(cat "$NOTIFY_LOG")"

# --- BEHIND. The declared base moves and the checkout does not follow.
git -C "$WS/home" checkout -q -b parked main
git -C "$WS/home" checkout -q main
printf 'landed\n' >> "$WS/home/aeon.sh"; commit "$WS/home" "a fix that landed"
git -C "$WS/home" checkout -q parked
cat > "$TMP/behind-map" <<MAP
home | $WS/home | push | main |  |
MAP
out="$(SPIRA_REPO_MAP="$TMP/behind-map" "$SKEW" check 2>&1)"; rc=$?
is   "a checkout behind its base is a finding" 1 "$rc"
want "the finding is named" "BEHIND" "$out"
want "and it carries the commit that is not in effect" "a fix that landed" "$out"
want "an ask was raised" "copy in force" "$(cat "$NOTIFY_LOG")"
want "and the ask carries the evidence, not a path to it" "BEHIND" "$(cat "$NOTIFY_LOG")"

# ONCE PER STATE, NOT ONCE PER PASS. The condition persists until somebody acts on it, and an
# hourly repeat of a decision already in front of the operator is the noise that teaches them
# to scroll past the one that matters (law-alerts-must-be-actionable).
before="$(wc -l < "$NOTIFY_LOG")"
SPIRA_REPO_MAP="$TMP/behind-map" "$SKEW" check >/dev/null 2>&1
is "the same finding does not escalate twice" "$before" "$(wc -l < "$NOTIFY_LOG")"

# --- DIRTY. A change in force that is on no branch at all.
printf 'unreviewed\n' >> "$WS/home/aeon.sh"
out="$(SPIRA_REPO_MAP="$TMP/behind-map" "$SKEW" check 2>&1)"
want "an uncommitted change to the copy in force is a finding" "DIRTY" "$out"
want "and a CHANGED finding does escalate again" "DIRTY" "$(cat "$NOTIFY_LOG")"
git -C "$WS/home" checkout -q -- aeon.sh

# Untracked files are not a finding: an operator's notes beside the code are their own
# business, and a fence that flagged them would be silenced.
printf 'scratch\n' > "$WS/home/notes.txt"
out="$(SPIRA_REPO_MAP="$TMP/behind-map" "$SKEW" check 2>&1)"
nowant "an untracked file is not a finding" "DIRTY" "$out"
rm -f "$WS/home/notes.txt"
git -C "$WS/home" checkout -q main

# --- COPY. The structural one: a second harness in another mapped repository.
out="$("$SKEW" check 2>&1)"; rc=$?
is   "a second harness in another mapped repository is a finding" 1 "$rc"
want "the finding names the repository" "repo:guest" "$out"
want "and where the copy sits" ".tools/spira" "$out"

# =======================================================================================
# THE POSITIVE CONTROL ON THE CHECK ITSELF. Every finding above is an absence claim resting
# on one matcher. Pointed at a tree with no harness in it, the matcher finds nothing — which
# is indistinguishable from a clean box unless the check refuses to call it one.
# =======================================================================================
out="$(SPIRA_REPO_MAP="$TMP/empty-map" SPIRA_REPO="$WS/plain" SPIRA_HOME_REPO=plain \
       "$SKEW" check 2>&1)"; rc=$?
is     "a check that cannot find its own harness exits 3" 3 "$rc"
nowant "and does not report a clean box" "in effect" "$out"
want   "it says why it refused" "Refusing to report a clean box" "$out"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || { echo "FAIL: skew"; exit 1; }
echo "PASS: skew"
