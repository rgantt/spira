#!/usr/bin/env bash
#
# test-repo.sh — the repository comes from the BEAD, and every path in the harness follows
# it there.
#
#   ./test-repo.sh
#
# THE DEFECT UNDER TEST. FAYTH_REPO was a constant per persona and every fayth in the
# chamber named the home checkout, so Spira could work exactly one of the seven repositories
# whose beads it had just collapsed into one database. The fix moves the choice onto the
# bead — a `repo:<name>` label resolved through repo-map — which means the failure mode
# changes shape: instead of "cannot work that repository at all", the risk becomes "worked
# it in the WRONG one", and that failure is silent. The aeon commits, the commit names the
# bead, the gate runs, the branch lands. Nothing downstream can tell.
#
# So the assertions that carry the weight are the negative ones: an unknown repo name
# resolves to NOTHING rather than to the home repo, a gate refuses a name it cannot resolve,
# and two repositories rebasing at once do not share one scratch worktree. Everything real
# here runs against real git repositories, because these are claims about what git does.
#
# covers: spira/repo-map.example spira/doctor.sh spira/sending.sh spira/skew.sh spira/exclude.sh spira/chamber/*
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
mkdir -p "$SH" "$RUN/worktree" "$WS"
cp "$HERE/conf.sh" "$HERE/lib.sh" "$HERE/gate.sh" "$HERE/sending.sh" "$HERE/exclude.sh" \
   "$HERE/skew.sh" "$SH/"

mkrepo() {               # mkrepo <name> — a repo with a real bare origin
    local n="$1"
    # `-b main` on the bare too: without it HEAD names `refs/heads/master`, which nothing
    # pushes, so the remote publishes a default branch that does not exist.
    git init -q --bare -b main "$WS/$n.git"
    git init -q -b main "$WS/$n"
    printf 'base\n' > "$WS/$n/file.txt"
    git -C "$WS/$n" add -A
    git -C "$WS/$n" commit -q -m base
    git -C "$WS/$n" remote add origin "$WS/$n.git"
    git -C "$WS/$n" push -q origin main
    git -C "$WS/$n" fetch -q origin
}
mkrepo alpha
mkrepo beta

cat > "$SH/repo-map" <<MAP
# a comment, and a blank line, both of which must be ignored

alpha | $WS/alpha | push | origin/main | true | echo "alpha gate ran" && test -f branch-only.txt
beta  | $WS/beta  | pr   | origin/main |      |
gamma | $WS/gamma | hold | origin/main |      |
nomode| $WS/alpha |      |             |      |
MAP

export SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB=/nonexistent-spira-db
export SPIRA_HOME_REPO=alpha
# shellcheck disable=SC1091
. "$SH/lib.sh"

echo "test-repo.sh"

# --------------------------------------------------------------------------------------
# The map itself.
# --------------------------------------------------------------------------------------
is "a name resolves to its path"          "$WS/alpha" "$(repo_root alpha)"
is "and so does the second one"           "$WS/beta"  "$(repo_root beta)"
is "the land mode is read"                "pr"        "$(repo_land beta)"
is "an empty land column defaults to push" "push"     "$(repo_land nomode)"
is "the base ref is read"                 "origin/main" "$(repo_field alpha base)"
is "an empty base column is empty"        ""          "$(repo_field nomode base)"
is "the gate command keeps its whole tail" 'echo "alpha gate ran" && test -f branch-only.txt' "$(repo_gate alpha)"
is "an empty gate column is empty"        ""          "$(repo_gate beta)"
is "the format command is read"           "true"      "$(repo_format alpha)"
is "an empty format column is empty"      ""          "$(repo_format beta)"

# THE OFF-BY-ONE THAT MATTERS. `base` was inserted before `format`, and `format` before the
# gate, because of the two command columns only one can be last and the gate is the one that
# may contain a pipe. A line written in any narrower shape therefore reads a LATER column as
# an earlier one — and a formatter is not merely read, it is RUN in the branch's tree and its
# output committed. For alpha a four-field row would execute
# `echo ... && test -f branch-only.txt` as a formatting pass.
# So the real map is checked for the shape, not just for the values.
short="$(awk 'BEGIN { FS = "|" } /^[ \t]*#/ { next }
              { n = $1; gsub(/^[ \t]+|[ \t]+$/, "", n); if (n != "" && NF > 1 && NF < 6) print n }' \
         "$HERE/repo-map" 2>/dev/null | tr '\n' ' ')"
is "every line of the real repo-map carries all six columns" "" "$short"

# The path column must still be a path after the insertion — the cheapest possible check
# that the whole file did not shift by one, and it fails loudly rather than by running a
# directory name as a formatter.
badpath="$(awk 'BEGIN { FS = "|" } /^[ \t]*#/ { next }
                { n = $1; p = $2; gsub(/^[ \t]+|[ \t]+$/, "", n); gsub(/^[ \t]+|[ \t]+$/, "", p)
                  if (n != "" && NF > 1 && p !~ /^\//) print n }' \
           "$HERE/repo-map" 2>/dev/null | tr '\n' ' ')"
is "and its path column is still a path" "" "$badpath"

# COLUMNS ARE ADDRESSED BY NAME. `base` was inserted between `land` and `gate`, and with
# numeric indices every existing call site would have kept working while meaning a different
# column — the gate command read as a branch name, the branch name run as a gate. A name
# cannot shift, and an unknown one answers nothing rather than the wrong field.
is "an unknown column name answers nothing" "" "$(repo_field alpha nosuchcolumn)"

# A ROW STILL WRITTEN IN THE FOUR-COLUMN FORM HAS NO BASE, and position 4 there holds the
# GATE COMMAND. Reading that as a branch name is worse than reading nothing, because
# `.claude/spira/gate-brain.sh` is a single token that looks exactly like a ref until git is
# asked — so no heuristic over the field's CONTENT can tell them apart, only the row's shape.
#
# This state is reachable in deployment, not hypothetical: .claude/spira is installed at
# a checkout and read by systemd timers, so lib.sh and repo-map can be read out of
# step. When they were, every one of the seven repositories failed to resolve at once.
OLDMAP="$TMP/old-format-map"
cat > "$OLDMAP" <<MAP
legacy   | $WS/alpha | push | .claude/spira/gate-brain.sh
bare     | $WS/alpha | push |
MAP
is "a four-column row declares no base" "" "$(SPIRA_REPO_MAP="$OLDMAP" repo_field legacy base)"
is "and its gate is still its gate" ".claude/spira/gate-brain.sh" \
   "$(SPIRA_REPO_MAP="$OLDMAP" repo_field legacy gate)"
is "so it resolves automatically instead" "origin/main" \
   "$(SPIRA_REPO_MAP="$OLDMAP" SPIRA_REPO= spira_landref legacy)"
is "a four-column row with an empty tail too" "" "$(SPIRA_REPO_MAP="$OLDMAP" repo_field bare base)"

# A FIVE-COLUMN ROW IS THE SHAPE BEFORE `base` EXISTED, so field 4 is its FORMATTER and the
# gate starts at 5. This is the half that fails OPEN and is therefore the worse one: reading
# the gate from a fixed field 6 of such a row returns EMPTY, which repo-map defines as
# "syntax was the whole trial" — gate-brain.sh would quietly stop running and every branch
# would land ungated, with nothing anywhere reporting a fault.
MIDMAP="$TMP/format-era-map"
cat > "$MIDMAP" <<MAP
midfmt   | $WS/alpha | push | cargo fmt --all | .claude/spira/gate-brain.sh
MAP
is "a five-column row declares no base" "" "$(SPIRA_REPO_MAP="$MIDMAP" repo_field midfmt base)"
is "its field 4 is the formatter"  "cargo fmt --all" "$(SPIRA_REPO_MAP="$MIDMAP" repo_field midfmt format)"
is "and its gate still runs"  ".claude/spira/gate-brain.sh" \
   "$(SPIRA_REPO_MAP="$MIDMAP" repo_field midfmt gate)"

# THE ONE THAT MATTERS. An unknown name must resolve to nothing and say so in its status; a
# fallback to the home repo would put another repository's fix on a branch in this one and
# every check downstream would pass it.
out="$(repo_root nosuchrepo)"; rc=$?
is "an unknown name resolves to nothing"  ""  "$out"
[ "$rc" -ne 0 ] && ok "and fails closed" || bad "and fails closed" "rc=$rc"
nowant "and never falls back to the home repo" "$WS/alpha" "$out"

names="$(repo_names | tr '\n' ' ')"
is "every mapped name is listed" "alpha beta gamma nomode " "$names"

# The home repo is present whether or not a map is. A fixture that copies lib.sh next to
# nothing else has no repo-map, and a harness that then swept zero repositories would land
# nothing while reporting a clean pass.
is "spira_repos leads with the home repo" "alpha" "$(spira_repos | head -1)"
is "and does not repeat it" "1" "$(spira_repos | grep -cx alpha)"
is "with no map at all, the home repo stands alone" "alpha" \
   "$(SPIRA_REPO_MAP=/nonexistent spira_repos | tr '\n' ' ' | sed 's/ $//')"

# SPIRA_REPO still points the home repo at a fixture, which is the seam every other suite
# drives — widening it into a map must not close it.
is "SPIRA_REPO overrides the home repo's path" "$WS/beta" "$(SPIRA_REPO="$WS/beta" repo_root alpha)"
is "and does not leak onto other names"        "$WS/beta" "$(SPIRA_REPO="$WS/alpha" repo_root beta)"

# --------------------------------------------------------------------------------------
# The label a bead carries.
# --------------------------------------------------------------------------------------
is "a repo: label is found among others" "repo-a" "$(repo_of_labels spira plan repo:repo-a)"
repo_of_labels spira plan >/dev/null 2>&1 \
    && bad "no repo: label fails" "returned 0" || ok "no repo: label fails"

# --------------------------------------------------------------------------------------
# Two repositories rebase at once. The scratch worktree used when nothing holds a branch was
# a single `.rebase`, registered against whichever repository created it first — the second
# repository's `git worktree add` then fails on a directory that is already somebody else's
# worktree, and the rebase silently never happens.
# --------------------------------------------------------------------------------------
advance() {              # advance <repo> — move origin/main without touching local main
    local n="$1" w="$TMP/push-$n"
    rm -rf "$w"
    git -C "$WS/$n" worktree add -q --detach "$w" origin/main
    printf 'moved\n' >> "$w/other.txt"
    git -C "$w" add -A; git -C "$w" commit -q -m "advance $n"
    git -C "$w" push -q origin HEAD:main
    git -C "$WS/$n" fetch -q origin
    git -C "$WS/$n" worktree remove --force "$w"
}
for n in alpha beta; do
    git -C "$WS/$n" branch "spira/sp-$n" main
    advance "$n"
done
rebase_branch "spira/sp-alpha" origin/main "$WS/alpha" && r1=0 || r1=1
rebase_branch "spira/sp-beta"  origin/main "$WS/beta"  && r2=0 || r2=1
is "the first repository rebases"  "0" "$r1"
is "and so does the second"        "0" "$r2"
git -C "$WS/beta" merge-base --is-ancestor origin/main "refs/heads/spira/sp-beta" \
    && ok "the second branch really contains origin/main" \
    || bad "the second branch really contains origin/main" "it does not"
[ -d "$RUN/worktree/.rebase.alpha" ] && [ -d "$RUN/worktree/.rebase.beta" ] \
    && ok "each repository got its own scratch tree" \
    || bad "each repository got its own scratch tree" "$(ls -d "$RUN"/worktree/.rebase* 2>/dev/null | tr '\n' ' ')"
git -C "$WS/beta" branch -D "spira/sp-beta" >/dev/null 2>&1 \
    && ok "and let go of the branch afterwards" \
    || bad "and let go of the branch afterwards" "the scratch tree still holds it"

# --------------------------------------------------------------------------------------
# The gate. Layer 1 is universal; layer 2 is the repository's own command, run against the
# BRANCH's tree in a minimal environment.
# --------------------------------------------------------------------------------------
gate() { SPIRA_HOME="$SH" SPIRA_RUN="$RUN" bash "$SH/gate.sh" "$@" 2>&1; }

out="$(gate spira/sp-alpha nosuchrepo)"; rc=$?
[ "$rc" -ne 0 ] && ok "the gate refuses an unmapped repository" \
                || bad "the gate refuses an unmapped repository" "rc=$rc"
want "and says why" "repo-map has no entry" "$out"

# alpha's gate command asserts a file that exists ONLY on the branch. If the gate ran in the
# shared checkout it would fail, and if it ran against main it would fail — so passing is
# evidence the tree is the branch's.
w="$TMP/wt-alpha"
git -C "$WS/alpha" worktree add -q "$w" "spira/sp-alpha"
printf 'x\n' > "$w/branch-only.txt"
git -C "$w" add -A; git -C "$w" commit -q -m "sp-alpha: add the file the gate looks for"
out="$(gate spira/sp-alpha alpha)"; rc=$?
is "the repository's own gate runs and passes" "0" "$rc"

# And it fails CLOSED. The file is removed on the branch; the same command must now refuse.
git -C "$w" rm -q branch-only.txt
git -C "$w" commit -q -m "sp-alpha: remove it again"
out="$(gate spira/sp-alpha alpha)"; rc=$?
[ "$rc" -ne 0 ] && ok "and fails when the repository's gate fails" \
                || bad "and fails when the repository's gate fails" "rc=0"
want "and names the command that failed" "alpha's own gate failed" "$out"

# WHOSE FAULT IT IS, SAID OUT LOUD. This command fails against the base too — the file has
# never existed on main — so no branch could ever pass it. Left undistinguished, that
# rejects every branch three times and poisons a bead whose work was fine, and the
# escalation the operator reads names a gate rather than the reason. Measured on a repository whose
# `cargo fmt --check` exits 1 against its own main.
want "a gate that also fails on the base says so" "fails against origin/main too" "$out"
want "and names the fix"                          "clear that command" "$out"

# ...and does NOT say so when the branch really is at fault. The distinction is the whole
# value: a message that appeared on every failure would be noise on the one that matters.
cat > "$SH/repo-map" <<MAP
alpha | $WS/alpha | push | origin/main | | test ! -f the-branch-broke-it.txt
MAP
out="$(gate spira/sp-alpha alpha)"; rc=$?
is "the branch passes before it breaks anything" "0" "$rc"
printf 'x\n' > "$w/the-branch-broke-it.txt"
git -C "$w" add -A; git -C "$w" commit -q -m "sp-alpha: break it"
out="$(gate spira/sp-alpha alpha)"; rc=$?
[ "$rc" -ne 0 ] && ok "a branch that breaks the gate fails it" \
                || bad "a branch that breaks the gate fails it" "rc=0"
nowant "and is not excused as the base's fault" "fails against origin/main too" "$out"
git -C "$w" rm -q the-branch-broke-it.txt; git -C "$w" commit -q -m "sp-alpha: unbreak it"

# Restore the branch-only fixture for the checks below.
cat > "$SH/repo-map" <<MAP
alpha | $WS/alpha | push | origin/main | | echo "alpha gate ran" && test -f branch-only.txt
beta  | $WS/beta  | pr   | origin/main | |
nomode| $WS/alpha |      |             | |
MAP

# A repository with no gate command is syntax-only, and syntax still bites.
printf 'if then fi\n' > "$w/broken.sh"
git -C "$w" add -A; git -C "$w" commit -q -m "sp-alpha: a script that does not parse"
out="$(gate spira/sp-alpha nomode)"; rc=$?
[ "$rc" -ne 0 ] && ok "an unparseable shell script fails any repository's gate" \
                || bad "an unparseable shell script fails any repository's gate" "rc=0"
want "and names the file" "broken.sh fails bash -n" "$out"

# THE GATE MUST NOT INHERIT THE HARNESS'S OWN CONFIGURATION. A deployment setting reaching a
# test suite through systemd once rejected correct work on every retry until the bead
# poisoned, so the environment a gate command sees is named at one site and nowhere else.
cat > "$SH/repo-map" <<MAP
alpha | $WS/alpha | push | origin/main | | test -z "\${SPIRA_FAYTHS:-}"
MAP
git -C "$w" rm -q broken.sh; git -C "$w" commit -q -m "sp-alpha: drop it"
out="$(SPIRA_FAYTHS='builder ops' gate spira/sp-alpha alpha)"; rc=$?
is "the gate command sees a clean environment" "0" "$rc"

# NO BEADS DATA MAY LAND IN THE HARNESS TREE — layer 1, universal, and the fence that
# survives `git commit --no-verify`. A database published in a shared repository holds
# internal working notes, agent memories and the overseer's own judgement, and cannot be
# un-published by deleting the commit.
#
# The branch is given the harness's own signature at its root, which is the state after
# sp-repo-move and the one where the scope is the whole repository. Without it the branch
# carries no harness and the check is correctly silent — proved first, so that the refusal
# below is known to come from the database and not from the fixture.
cat > "$SH/repo-map" <<MAP
alpha | $WS/alpha | push | origin/main | |
MAP
mkdir -p "$w/.beads"; printf 'db\n' > "$w/.beads/config.yaml"
git -C "$w" add -Af; git -C "$w" commit -q -m "sp-alpha: a database, but no harness here"
out="$(gate spira/sp-alpha alpha)"; rc=$?
is "a database in a repository with no harness is not the gate's business" "0" "$rc"

: > "$w/boundary"; : > "$w/lib.sh"; printf '#!/usr/bin/env bash\n' > "$w/gate.sh"
git -C "$w" add -Af; git -C "$w" commit -q -m "sp-alpha: now it is the harness"
out="$(gate spira/sp-alpha alpha)"; rc=$?
[ "$rc" -ne 0 ] && ok "the gate refuses a branch landing beads data in the harness" \
                || bad "the gate refuses a branch landing beads data in the harness" "rc=0"
want "and names the offending path" ".beads/config.yaml" "$out"

# It is the branch's WHOLE TREE that is judged, not its diff: the database arrived two
# commits ago and this commit does not touch it, which is exactly how a changed-files check
# would wave it through.
printf 'x\n' > "$w/unrelated.txt"
git -C "$w" add -A; git -C "$w" commit -q -m "sp-alpha: an unrelated change"
out="$(gate spira/sp-alpha alpha)"; rc=$?
[ "$rc" -ne 0 ] && ok "and judges the whole tree, not the diff" \
                || bad "and judges the whole tree, not the diff" "rc=0"

git -C "$w" rm -qr .beads; git -C "$w" commit -q -m "sp-alpha: remove the database"

# ALPHA IS NOW THE HARNESS, and the gate has a second universal fence that says so: a branch
# may not change a COPY of the harness in a repository that is not the harness's own. Three
# commits ago this fixture gave alpha's branch the signature, so from here the gate must be
# told which repository the harness is installed in — otherwise it is judging a copy.
#
# That is asserted in both directions rather than merely worked around. Left to derive,
# SPIRA_REPO is the fixture's parent directory and alpha is somebody else's tree, so the same
# branch must be refused; declared, it is the harness's own and passes.
out="$(gate spira/sp-alpha alpha)"; rc=$?
[ "$rc" -ne 0 ] && ok "a branch changing a harness in another repository is refused" \
                || bad "a branch changing a harness in another repository is refused" "rc=0"
want "and says where the work belongs" "belongs in the harness" "$out"

out="$(SPIRA_REPO="$WS/alpha" gate spira/sp-alpha alpha)"; rc=$?
is "and passes once the database is gone, in the harness's own repository" "0" "$rc"

# THE CURE IS NOT THE OFFENCE. A branch that DELETES a vendored copy is exactly the work this
# fence exists to make unnecessary, and refusing it would leave the second copy standing
# forever. It is allowed by construction — the fence reads the branch's own tree, and a branch
# that removed the signature carries no harness for it to judge — and that is asserted here
# because "by construction" is how a regression gets in unnoticed.
git -C "$w" rm -q boundary lib.sh gate.sh
git -C "$w" commit -q -m "sp-alpha: delete the vendored harness"
out="$(gate spira/sp-alpha alpha)"; rc=$?
is "a branch that DELETES a vendored harness is allowed" "0" "$rc"

# The check FAILS CLOSED on its own absence. `bash <missing> | ...` yields an empty offender
# list, which reads exactly like a clean tree — a check that could not run reporting
# all-clear is the shape this harness keeps rediscovering.
mkdir -p "$w/.beads"; printf 'db\n' > "$w/.beads/config.yaml"
git -C "$w" add -Af; git -C "$w" commit -q -m "sp-alpha: the database returns"
mv "$SH/exclude.sh" "$SH/exclude.sh.away"
out="$(gate spira/sp-alpha alpha)"; rc=$?
[ "$rc" -ne 0 ] && ok "a missing exclude.sh refuses the landing rather than passing it" \
                || bad "a missing exclude.sh refuses the landing rather than passing it" "rc=0"
want "and says which file is missing" "exclude.sh is missing" "$out"
mv "$SH/exclude.sh.away" "$SH/exclude.sh"
git -C "$w" rm -qr .beads; git -C "$w" commit -q -m "sp-alpha: and goes again"

git -C "$WS/alpha" worktree remove --force "$w"

# --------------------------------------------------------------------------------------
# The Sending sweeps EVERY repository. A reaper that swept one would leave every other
# repository's landed branches and worktrees standing forever — and would report a clean
# pass while doing it, which is the false-clean this harness keeps rediscovering.
# --------------------------------------------------------------------------------------
cat > "$SH/repo-map" <<MAP
alpha | $WS/alpha | push | origin/main | |
beta  | $WS/beta  | push | origin/main | |
MAP
# One landed branch in each: merged into origin/main, so ancestry says they are reapable.
for n in alpha beta; do
    git -C "$WS/$n" branch -f "spira/sp-$n" main 2>/dev/null
    git -C "$WS/$n" push -q origin "spira/sp-$n:main" --force 2>/dev/null
    git -C "$WS/$n" fetch -q origin
done
printf 'sp-alpha\tclosed\nsp-beta\tclosed\n' > "$TMP/status"
out="$(SPIRA_HOME="$SH" SPIRA_RUN="$RUN" bash "$SH/sending.sh" --status-from "$TMP/status" 2>&1)"
want "the home repository is swept"   "REAPED sp-alpha" "$out"
want "and so is the second"           "REAPED sp-beta"  "$out"
git -C "$WS/beta" show-ref --verify -q "refs/heads/spira/sp-beta" \
    && bad "the second repository's branch is really gone" "it survived" \
    || ok "the second repository's branch is really gone"

# A repository in the map whose checkout is missing is SKIPPED and says so, rather than
# being silently swept as if it were empty.
cat >> "$SH/repo-map" <<MAP
ghost | $WS/nowhere | push | origin/main | |
MAP
out="$(SPIRA_HOME="$SH" SPIRA_RUN="$RUN" bash "$SH/sending.sh" --status-from "$TMP/status" 2>&1)"
want "a missing checkout is named, not skipped in silence" "SKIP   ghost" "$out"

# --------------------------------------------------------------------------------------
# The SHIPPED map. Not its paths — those are this box's — but its shape, because a typo in
# this file is a repository the harness silently cannot work.
# --------------------------------------------------------------------------------------
unset SPIRA_REPO_MAP
# THE MAP THAT IS ACTUALLY IN FORCE, resolved the way conf.sh resolves it: the operator's own
# `repo-map` when there is one, the shipped `repo-map.example` otherwise. Checking only
# `repo-map` meant this whole section silently skipped on a clean clone, which is precisely
# the installation whose map has never been read by anything.
SHIPPED="$HERE/repo-map"; [ -f "$SHIPPED" ] || SHIPPED="$HERE/repo-map.example"
EXAMPLE_MAP=0; case "$SHIPPED" in *.example) EXAMPLE_MAP=1 ;; esac
if [ -f "$SHIPPED" ]; then
    n_names="$(SPIRA_REPO_MAP="$SHIPPED" repo_names | wc -l)"
    n_uniq="$(SPIRA_REPO_MAP="$SHIPPED" repo_names | sort -u | wc -l)"
    is "no repository is named twice" "$n_names" "$n_uniq"
    badrow=""
    for n in $(SPIRA_REPO_MAP="$SHIPPED" repo_names); do
        p="$(SPIRA_REPO_MAP="$SHIPPED" SPIRA_REPO= repo_field "$n" path)"
        m="$(SPIRA_REPO_MAP="$SHIPPED" repo_land "$n")"
        b="$(SPIRA_REPO_MAP="$SHIPPED" repo_field "$n" base)"
        case "$p" in /*) ;; *) badrow="$badrow $n:path" ;; esac
        case "$m" in push|pr|hold) ;; *) badrow="$badrow $n:mode=$m" ;; esac
        # A BASE IS A REF NAME, AND A REF NAME HAS NO SPACES IN IT. This is the tripwire for
        # a row written in the old four-column form: `base` would then hold the gate command,
        # which is the failure that renumbering columns invites — every row still parses, and
        # a branch gets rebased onto `cargo fmt --all -- --check`.
        # A BASE IS A REF NAME, PRESENT, AND WITHOUT SPACES. Empty catches a row whose
        # trailing `|` was forgotten, which would silently lose the column and fall back to
        # resolution; spaces catch a row still in the four-column form whose gate command has
        # landed in this position.
        case "$b" in
            "")           badrow="$badrow $n:no-base" ;;
            *" "*|*"	"*) badrow="$badrow $n:base-is-not-a-ref" ;;
        esac
        # A path that exists must be a checkout. One that does not is another machine's
        # business — a map is shared across machines and only some of them have the checkouts.
        if [ -e "$p" ] && [ ! -e "$p/.git" ]; then badrow="$badrow $n:not-a-checkout"; fi
    done
    is "every shipped row has an absolute path and a known land mode" "" "$badrow"

    # AND THE DECLARED BASE MUST ACTUALLY RESOLVE IN THAT CHECKOUT. A `base` naming a ref the
    # repository does not have is the very defect this column exists to fix, moved from the
    # code into the map. Checked only where the checkout is present, because other machines
    # share this file and only some of them have the checkouts.
    badbase=""
    for n in $(SPIRA_REPO_MAP="$SHIPPED" repo_names); do
        p="$(SPIRA_REPO_MAP="$SHIPPED" SPIRA_REPO= repo_field "$n" path)"
        [ -e "$p/.git" ] || continue
        r="$(SPIRA_REPO_MAP="$SHIPPED" SPIRA_REPO= spira_landref "$n" 2>/dev/null)" \
            || { badbase="$badbase $n:unresolvable"; continue; }
        git -C "$p" rev-parse --verify -q "$r" >/dev/null 2>&1 \
            || badbase="$badbase $n:$r-does-not-exist"
    done
    is "every present checkout resolves to a real base ref" "" "$badbase"
    # THE HOME REPOSITORY MUST HAVE A ROW, because a bead that names no repository resolves
    # to it and an unmapped name is refused rather than guessed. Asked of the OPERATOR's map
    # only: the example's home row is called `home`, and a fresh clone's home repo is named
    # after whatever directory it was cloned into, so the two cannot be made to agree — the
    # example says to rename it and doctor.sh says so out loud.
    if [ "$EXAMPLE_MAP" = 0 ]; then
        # Asked of a CLEAN resolution, not of this process: the fixtures above export
        # SPIRA_HOME_REPO to drive their own scenarios, and reading it here would assert that
        # the shipped map carries a fixture's repository rather than the real installation's.
        home="$(env -u SPIRA_HOME_REPO -u SPIRA_HOME -u SPIRA_REPO -u SPIRA_REPO_MAP \
                bash -c ". '$HERE/conf.sh' 2>/dev/null; printf '%s' \"\$SPIRA_HOME_REPO\"")"
        SPIRA_REPO_MAP="$SHIPPED" SPIRA_REPO= repo_root "$home" >/dev/null 2>&1 \
            && ok "the home repository is in the shipped map" \
            || bad "the home repository is in the shipped map" "$home is missing"
    else
        SPIRA_REPO_MAP="$SHIPPED" SPIRA_REPO= repo_root home >/dev/null 2>&1 \
            && ok "the example map carries a home row to rename" \
            || bad "the example map carries a home row to rename" "no row named home"
    fi
    SPIRA_REPO_MAP="$SHIPPED" repo_root town >/dev/null 2>&1 \
        && bad "Gas Town's own beads have no repository here" "town resolves" \
        || ok "Gas Town's own beads have no repository here"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
