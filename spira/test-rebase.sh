#!/usr/bin/env bash
#
# test-rebase.sh — the base every branch is cut from and brought back to.
#
#   ./test-rebase.sh
#
# Two claims are under test and both are about git, not about bookkeeping, so this runs
# against real repositories with a real bare remote and real worktrees. A mocked git would
# assert only that the mock agrees with the author.
#
#   spira_landref   the harness measures against the remote-tracking ref of a repository's
#                   OWN default branch — never the local ref, which nothing here advances,
#                   and never a literal `main`, which three of the seven repositories this
#                   harness manages do not have.
#   rebase_branch   a stale branch is brought onto that ref before it is gated or merged —
#                   and when it cannot be, the branch is left EXACTLY as it was.
#
# The negatives carry the weight, as they do in test-sending.sh. A rebase that fails to run
# costs a conflict someone has to resolve; a rebase that half-runs, or that moves a ref it
# could not replay, destroys commits that exist in exactly one place. So the conflict case
# asserts the old tip is still the branch tip AND that no rebase was left in progress, and
# the scratch-worktree case asserts the branch is still deletable afterwards — a worktree
# that keeps hold of a branch is the exact defect sending.sh exists to fix.
#
# covers: spira/sending.sh spira/sentinel.sh spira/aeon.sh spira/cockpit.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()  {   # is <name> <want> <got>
    [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"
}
want() {  # want <name> <substring> <haystack>
    [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"
# `-b main` ON THE BARE REPOSITORY TOO. A bare repo created without it has HEAD pointing at
# `refs/heads/master`, which nothing here ever pushes — so the remote publishes a default
# branch that does not exist, and a fixture in that state is not a stand-in for a clone, it
# is a stand-in for a broken remote. It passed only because the old code never asked.
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
printf 'one\n' > "$REPO/shared.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree"

# NO MAP BY DEFAULT, for the same reason SPIRA_DB points at nothing: SPIRA_HOME is unset
# here, so it defaults to the SHARED checkout and this suite would read the installed
# repo-map — running whatever formatter the home repository happens to declare inside a
# fixture. Observed doing exactly that: the four-field map that predates the format column
# resolved `.claude/spira/gate-brain.sh` as brain's formatter and the fixture ran it.
export SPIRA_REPO="$REPO" SPIRA_RUN="$RUN" SPIRA_DB=/nonexistent-spira-db
export SPIRA_REPO_MAP=/nonexistent-spira-repo-map
# shellcheck disable=SC1091
. "$HERE/lib.sh"

sha() { git -C "$REPO" rev-parse --short "$1" 2>/dev/null; }

# advance_origin <line> — land something on origin/main WITHOUT touching local main, which
# is precisely the shape the real harness produces: the sentinel pushes landing:main from
# its own worktree and nothing ever pulls the shared checkout.
# It pushes from a DETACHED worktree, exactly as sentinel.sh's .landing tree does, because
# that is the mechanism that produces the staleness in the first place.
advance_origin() {
    local w="$TMP/pusher"
    [ -e "$w/.git" ] || git -C "$REPO" worktree add -q --detach "$w" origin/main
    git -C "$w" checkout -q --detach origin/main
    printf '%s\n' "$1" >> "$w/shared.txt"
    git -C "$w" commit -qam "origin: $1"
    git -C "$w" push -q origin HEAD:main
    git -C "$REPO" fetch -q origin
}

branch_at() {   # branch_at <name> <base> [file] [content]
    local br="$1" base="$2" f="${3:-}" c="${4:-}"
    git -C "$REPO" worktree add -q -b "$br" "$RUN/worktree/${br##*/}" "$base"
    if [ -n "$f" ]; then
        printf '%s\n' "$c" >> "$RUN/worktree/${br##*/}/$f"
        git -C "$RUN/worktree/${br##*/}" add -A
        git -C "$RUN/worktree/${br##*/}" commit -q -m "$br work"
    fi
}

echo "spira_landref"
# --------------------------------------------------------------------------------------
# THE DEFECT UNDER TEST HERE. This answered `origin/main` if that ref existed and the literal
# string `main` otherwise — it never asked a repository what its default branch was. Measured
# Measured across seven repositories: two had no ref named `main` anywhere, remote or local,
# and a third had a remote not named `origin`. In those three the answer named a
# branch that does not exist, so `git worktree add -b spira/<id> "$WORK" "$BASE"` failed and
# no aeon could get a workspace at all, CHECK 6's rebase failed and REOPENED finished work,
# and `gh pr create --base main` opened against nothing.
#
# So every rung of the ladder gets its own repository, built for real, and the master-named
# ones carry the weight: a suite whose fixtures are all called `main` cannot fail on this bug.

# rung 2 — the remote's own declared default, cached in refs/remotes/origin/HEAD.
is "reads the remote's declared default" "origin/main" "$(spira_landref "$REPO")"

# A repository whose default branch is MASTER. Nothing about it is named `main`.
mkrepo_master() {        # mkrepo_master <dir> — a master-default repo with a real bare origin
    local d="$1"
    git init -q --bare -b master "$d.git"
    git init -q -b master "$d"
    git -C "$d" commit -q --allow-empty -m base
    git -C "$d" remote add origin "$d.git"
    git -C "$d" push -q origin master
    git -C "$d" fetch -q origin
}
MASTER="$TMP/masterrepo"; mkrepo_master "$MASTER"
is "a master-default repository answers master" "origin/master" "$(spira_landref "$MASTER")"
git -C "$MASTER" rev-parse --verify -q main >/dev/null 2>&1 \
    && bad "the master fixture really has no main" "it has one" \
    || ok "the master fixture really has no main"

# rung 4 — no remote at all: the repository's own branch, whatever it is called.
NOREMOTE="$TMP/noremote"; git init -q -b main "$NOREMOTE"
git -C "$NOREMOTE" commit -q --allow-empty -m base
is "falls back with no remote"    "main"        "$(spira_landref "$NOREMOTE")"
NOREMOTE_M="$TMP/noremote-master"; git init -q -b trunk "$NOREMOTE_M"
git -C "$NOREMOTE_M" commit -q --allow-empty -m base
is "and does not assume main when it does" "trunk" "$(spira_landref "$NOREMOTE_M")"

# rung 1 — repo-map's `base` column, which beats both automatic sources. The two rungs below
# it are local caches; a checkout sitting on a topic branch or a detached HEAD is the normal
# state of most real repositories, so the declared answer has to win.
MAPHOME="$TMP/maphome"; mkdir -p "$MAPHOME"
MASTER2="$TMP/masterrepo2"; mkrepo_master "$MASTER2"
git -C "$MASTER2" branch -q side master
cat > "$MAPHOME/repo-map" <<MAP
m | $MASTER  | pr | origin/master | |
w | $MASTER2 | pr | side          | |
b | $MASTER  | pr | origin/nope   | |
e | $MASTER  | pr |               | |
MAP
declared() { SPIRA_REPO_MAP="$MAPHOME/repo-map" spira_landref "$1"; }
is "the map's base is used when it is given" "origin/master" "$(declared m)"
is "and it is used verbatim, not second-guessed" "side" "$(declared w)"
is "an empty base column falls through to resolution" "origin/master" "$(declared e)"

# A DECLARED BASE THAT DOES NOT EXIST FAILS CLOSED. Putting the guess in the map instead of
# in the code would be the same bug with a longer commit message.
out="$(declared b)"; rc=$?
[ "$rc" -ne 0 ] && ok "a base naming a missing ref fails closed" \
                || bad "a base naming a missing ref fails closed" "rc=$rc"
is "and answers nothing at all" "" "$out"

# A path resolves through the map too, because that is how every caller in the harness holds
# a repository: gate.sh, aeon.sh, sentinel.sh, sending.sh and cockpit.sh all pass a PATH.
is "a path finds its own row" "side" \
   "$(SPIRA_REPO_MAP="$MAPHOME/repo-map" spira_landref "$MASTER2")"

# THE ONE THAT MATTERS. A repository whose answer cannot be established is REFUSED. `main` is
# a guess, and a guess here rebases finished work onto a branch nobody chose — which is the
# reopen-with-a-false-reason that poisons a bead and escalates to the operator about work that was
# fine. The bare origin's HEAD names a branch that was never pushed, so set-head --auto has
# nothing to report and there is genuinely no answer to give.
UNRES="$TMP/unresolvable"
git init -q --bare "$UNRES.git"          # HEAD -> refs/heads/master, which is never pushed
git init -q -b main "$UNRES"
git -C "$UNRES" commit -q --allow-empty -m base
git -C "$UNRES" remote add origin "$UNRES.git"
git -C "$UNRES" push -q origin main
git -C "$UNRES" fetch -q origin
out="$(spira_landref "$UNRES")"; rc=$?
[ "$rc" -ne 0 ] && ok "an unresolvable repository fails closed" \
                || bad "an unresolvable repository fails closed" "rc=$rc"
is "and never guesses main" "" "$out"

echo
echo "ref_remote / ref_branch"
# --------------------------------------------------------------------------------------
# Every call site used to split a ref by hand as `${base#origin/}` and a literal `origin`.
# Both are assumptions about a remote's NAME, and a remote need not be called `origin`.
is "a remote-tracking ref splits"     "origin"  "$(ref_remote origin/master)"
is "and keeps its branch"             "master"  "$(ref_branch origin/master)"
is "a differently-named remote too"   "upstream"   "$(ref_remote upstream/master)"
is "and so does its branch"           "master"  "$(ref_branch upstream/master)"
ref_remote master >/dev/null 2>&1 \
    && bad "a local ref has no remote" "returned one" || ok "a local ref has no remote"
is "and is its own branch name"       "master"  "$(ref_branch master)"

echo
echo "spira_landrefs"
# --------------------------------------------------------------------------------------
# The commit graph is read across the remote ref AND its local counterpart. Two call sites
# appended a literal `main`, which in a master-default repository names nothing — and
# `git log <ref> main` fails outright on an unknown revision, so BOTH refs were dropped and
# every closed bead there counted as unlanded.
is "both refs when the local one exists" "origin/master master" "$(spira_landrefs "$MASTER")"
REMOTEONLY="$TMP/remoteonly"; mkrepo_master "$REMOTEONLY"
git -C "$REMOTEONLY" checkout -q --detach
git -C "$REMOTEONLY" branch -q -D master
is "just the remote ref when it does not" "origin/master" "$(spira_landrefs "$REMOTEONLY")"

echo
echo "rebase_branch"
# -- already current: cheap, and must not rewrite anything ------------------------------
branch_at spira/sp-fresh origin/main own.txt fresh
before="$(sha spira/sp-fresh)"
rebase_branch spira/sp-fresh origin/main "$REPO"; rc=$?
is "already-current returns 0"    "0"           "$rc"
is "already-current rewrites nothing" "$before" "$(sha spira/sp-fresh)"

# -- behind and disjoint: rebases, keeping its own commit -------------------------------
branch_at spira/sp-behind origin/main own2.txt behind
advance_origin two
rebase_branch spira/sp-behind origin/main "$REPO"; rc=$?
is "stale branch returns 0"       "0"           "$rc"
git -C "$REPO" merge-base --is-ancestor origin/main spira/sp-behind 2>/dev/null \
    && ok "stale branch now contains origin/main" \
    || bad "stale branch now contains origin/main" "still behind"
is "its own work survived"        "behind"      "$(git -C "$REPO" show spira/sp-behind:own2.txt 2>/dev/null)"
is "the worktree followed it"     "$(sha spira/sp-behind)" \
                                  "$(git -C "$RUN/worktree/sp-behind" rev-parse --short HEAD)"

# -- behind and CONFLICTING: refuse, and change nothing ---------------------------------
# This is the case the whole bead is about: every Spira bead edits the same few files, so a
# stale branch and main touch the same lines. A refusal here must be inert.
branch_at spira/sp-clash origin/main shared.txt "clash"
before="$(sha spira/sp-clash)"
advance_origin "three"
REBASE_CONFLICTS=""
rebase_branch spira/sp-clash origin/main "$REPO"; rc=$?
is "conflict returns 1"           "1"           "$rc"
is "the branch ref is untouched"  "$before"     "$(sha spira/sp-clash)"
want "the colliding path is named" "shared.txt" "$REBASE_CONFLICTS"
[ -e "$RUN/worktree/sp-clash/.git/rebase-merge" ] || [ -e "$RUN/worktree/sp-clash/.git/rebase-apply" ] \
    && bad "no rebase left in progress" "the worktree is mid-rebase" \
    || ok "no rebase left in progress"
is "the worktree is back on its branch" "$before" \
                                  "$(git -C "$RUN/worktree/sp-clash" rev-parse --short HEAD)"

# -- a dirty worktree does not block the rebase, but is salvaged first -------------------
# wiki/tasks.md is a GENERATED file tracked in git and rewritten by a timer, so a worktree
# is dirty within minutes of being created. If that blocked the rebase, nothing would ever
# rebase, for a reason having nothing to do with the work.
branch_at spira/sp-dirty origin/main own3.txt dirty
printf 'half-written\n' >> "$RUN/worktree/sp-dirty/own3.txt"
printf 'staged\n' > "$RUN/worktree/sp-dirty/staged.txt"
git -C "$RUN/worktree/sp-dirty" add staged.txt
advance_origin four
rebase_branch spira/sp-dirty origin/main "$REPO"; rc=$?
is "a dirty worktree still rebases" "0"         "$rc"
# The salvage filename carries a timestamp: it did not, and every salvage of a bead wrote
# one `<id>.patch`, so a bead reaped twenty times kept only the twentieth.
pp="$(ls "$RUN"/reaped/sp-dirty-prerebase.*.patch 2>/dev/null | head -1)"
[ -n "$pp" ] && ok "its uncommitted work was salvaged" \
             || bad "its uncommitted work was salvaged" "no patch in $RUN/reaped"
want "the salvaged patch has the content" "half-written" "$(cat "${pp:-/dev/null}" 2>/dev/null)"

# -- a branch with NO worktree: rebased in the scratch tree, and released afterwards -----
git -C "$REPO" worktree add -q -b spira/sp-bare "$TMP/bare-wt" origin/main
printf 'bare\n' > "$TMP/bare-wt/own4.txt"
git -C "$TMP/bare-wt" add -A && git -C "$TMP/bare-wt" commit -q -m "sp-bare work"
git -C "$REPO" worktree remove --force "$TMP/bare-wt"
advance_origin five
rebase_branch spira/sp-bare origin/main "$REPO"; rc=$?
is "a worktree-less branch rebases" "0"         "$rc"
git -C "$REPO" merge-base --is-ancestor origin/main spira/sp-bare 2>/dev/null \
    && ok "it now contains origin/main" || bad "it now contains origin/main" "still behind"
# THE ONE THAT MATTERS. If the scratch tree still held the branch, `git branch -D` would
# refuse exactly as it did before sending.sh existed, and the reaper would leak forever.
is "the scratch tree let go of it" "" "$(worktree_of spira/sp-bare "$REPO")"
git -C "$REPO" branch -D spira/sp-bare >/dev/null 2>&1
git -C "$REPO" show-ref --verify -q refs/heads/spira/sp-bare \
    && bad "the branch is still deletable" "branch -D refused" \
    || ok "the branch is still deletable"

# -- a branch that does not exist is a refusal, not a crash -----------------------------
rebase_branch spira/sp-nope origin/main "$REPO"; rc=$?
is "an unknown branch returns 1"  "1"           "$rc"

echo
echo "format_rebased — a rebased tree is put back through the repo's own formatter"
# --------------------------------------------------------------------------------------
# THE DEFECT. git replays hunks; it does not re-run anyone's formatter on what it produced.
# So a rebase that resolves perfectly still hands the required check a machine-produced tree
# that nothing formatted, and the branch fails `cargo fmt --all -- --check` — a check it
# passed before the harness touched it. The failure is then charged to the aeon that wrote
# correct code, and it recurs on exactly the shape a rebase is BEST at.
#
# The fixture's formatter is repository-wide, as `cargo fmt --all` is: it upper-cases every
# tracked `*.fmt` file. That is what makes the "only the branch's own files are committed"
# assertion meaningful — a repository-wide formatter on a repository whose main is already
# unformatted would otherwise sweep the whole tree into one bead's branch.
# --------------------------------------------------------------------------------------
FMT="$TMP/fmt.sh"
cat > "$FMT" <<'FMTSH'
#!/usr/bin/env bash
set -uo pipefail
for f in $(git ls-files '*.fmt'); do
    tr 'a-z' 'A-Z' < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
FMTSH
chmod +x "$FMT"

# A map the fixture owns. SPIRA_REPO already points the home repo's PATH at $REPO, so only
# the format column is being introduced here; repo_name_at resolves $REPO through that same
# override, which is the seam every other suite drives.
MAP="$TMP/repo-map"; export SPIRA_REPO_MAP="$MAP"
printf 'brain | %s | push | | %s | \n' "$REPO" "$FMT" > "$MAP"

subject() { git -C "$REPO" log -1 --format=%s "$1" 2>/dev/null; }
blob()    { git -C "$REPO" show "$1:$2" 2>/dev/null; }

# -- a real rebase is followed by a real format commit -----------------------------------
branch_at spira/sp-fmt origin/main own.fmt "needs-format"
advance_origin six
rebase_branch spira/sp-fmt origin/main "$REPO"; rc=$?
is "a formatted rebase returns 0"     "0"              "$rc"
is "the formatter ran and was committed" "NEEDS-FORMAT" "$(blob spira/sp-fmt own.fmt)"
want "the format commit names the bead" "re-format sp-fmt" "$(subject spira/sp-fmt)"

# -- ONLY the branch's own files. A repository-wide formatter must not commit main's ------
# main-only.fmt reaches the branch through the rebase and the formatter rewrites it in the
# tree, but the branch never touched it, so it must arrive on origin/main's terms.
w="$TMP/pusher2"
git -C "$REPO" worktree add -q --detach "$w" origin/main
printf 'main-content\n' > "$w/main-only.fmt"
git -C "$w" add -A; git -C "$w" commit -qm "origin: main-only.fmt"
git -C "$w" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
branch_at spira/sp-scope origin/main own6.fmt "scoped"
advance_origin seven
rebase_branch spira/sp-scope origin/main "$REPO"; rc=$?
is "the scoped rebase returns 0"      "0"              "$rc"
is "the branch's own file is formatted" "SCOPED"       "$(blob spira/sp-scope own6.fmt)"
is "a file only main touched is left alone" "main-content" "$(blob spira/sp-scope main-only.fmt)"

# -- ALREADY CURRENT: nothing was replayed, so there is nothing to re-format --------------
# A formatter run here would be a diff the harness invented on a tree no machine produced.
branch_at spira/sp-current origin/main own7.fmt "untouched"
before="$(sha spira/sp-current)"
rebase_branch spira/sp-current origin/main "$REPO"; rc=$?
is "an already-current branch returns 0" "0"           "$rc"
is "and is not re-formatted"          "untouched"      "$(blob spira/sp-current own7.fmt)"
is "and its ref did not move"         "$before"        "$(sha spira/sp-current)"

# -- NO FORMAT COMMAND: absence means do nothing, not "guess a formatter" ----------------
printf 'brain | %s | push | | | \n' "$REPO" > "$MAP"
branch_at spira/sp-nofmt origin/main own8.fmt "left-alone"
advance_origin eight
rebase_branch spira/sp-nofmt origin/main "$REPO"; rc=$?
is "an unformatted repo still rebases" "0"             "$rc"
is "and nothing reformatted it"       "left-alone"     "$(blob spira/sp-nofmt own8.fmt)"
want "and no format commit was made"  "spira/sp-nofmt work" "$(subject spira/sp-nofmt)"

# -- A FAILING FORMATTER CHANGES NOTHING -------------------------------------------------
# `cargo fmt` exits non-zero on a tree it cannot parse, and it may have rewritten half of it
# first. A convenience must never be able to turn a clean rebase into a branch of partial
# edits — the rebase stands, unformatted, and the gate renders the verdict.
BADFMT="$TMP/badfmt.sh"
cat > "$BADFMT" <<'BADSH'
#!/usr/bin/env bash
for f in $(git ls-files '*.fmt'); do printf 'half-written
' > "$f"; done
exit 1
BADSH
chmod +x "$BADFMT"
printf 'brain | %s | push | | %s | \n' "$REPO" "$BADFMT" > "$MAP"
branch_at spira/sp-badfmt origin/main own9.fmt "survives"
advance_origin nine
rebase_branch spira/sp-badfmt origin/main "$REPO"; rc=$?
is "a failing formatter still rebases" "0"             "$rc"
is "and its partial edits are discarded" "survives"    "$(blob spira/sp-badfmt own9.fmt)"
want "and no format commit was made"  "spira/sp-badfmt work" "$(subject spira/sp-badfmt)"
[ -z "$(git -C "$RUN/worktree/sp-badfmt" status --porcelain 2>/dev/null)" ] \
    && ok "and the worktree is left clean" \
    || bad "and the worktree is left clean" "$(git -C "$RUN/worktree/sp-badfmt" status --porcelain)"

export SPIRA_REPO_MAP=/nonexistent-spira-repo-map

echo
echo "regression — no harness program names a branch literally"
# --------------------------------------------------------------------------------------
# Both defects this suite exists for were one word. The first was
# `worktree add -b "$BRANCH" "$WORK" main` — a branch cut from the stale local ref. The
# second was every OTHER site that spelled a branch out: `origin/main` in the ref list,
# `landing:main` as a push target, `--base main` on a pull request, `rebase origin/main` in
# the retry. Each is a one-token edit to reintroduce, each fails silently for hours, and the
# second kind is invisible in the one repository where it happens to be right.
#
# So the fence is the whole class, not the one instance. Comments are stripped rather than
# excluded, because these files explain themselves at length and every explanation names the
# refs it is about. Fixture repos under test-*.sh are exempt: they are allowed to be concrete.
offenders=""
for f in "$HERE"/*.sh; do
    case "$(basename "$f")" in test-*) continue ;; esac
    hit="$(sed 's/#.*//' "$f" | grep -nE \
        'worktree add.*(^|[^/[:alnum:]_])(main|master)([^[:alnum:]_/]|$)|origin/(main|master)|landing:(main|master)|--base +(main|master)' \
        || true)"
    [ -n "$hit" ] && offenders="$offenders$(basename "$f"): $hit
"
done
is "no harness program spells a branch out" "" "$offenders"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
