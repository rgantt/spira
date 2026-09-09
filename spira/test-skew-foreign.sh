#!/usr/bin/env bash
#
# test-skew-foreign.sh — the landing gate's foreign-harness fence, proved in both directions.
#
#   ./test-skew-foreign.sh
#
# WHAT THIS TESTS
# ---------------
# gate.sh calls `skew.sh foreign <repo> <base> <ref>` to refuse any branch that changes a
# COPY of the harness in a repository that is not the harness's own. Correct work landing
# there would pass its gate, close its bead naming a real commit, and never run — because
# the tree that was edited is self-consistent and nothing compares the two.
#
# This is the positive control for that fence: a gate check that always exits 0 is a check
# that passes things it has never examined (law-absence-needs-a-positive-control). So the
# weight of this suite is on the REFUSAL assertions, not the pass assertions.
#
# The key property proved is that the exemption IS an exemption rather than an always-pass:
# the SAME branch is run twice, differing only in which repository is called the harness. If
# one passes and the other is refused, the check is discriminating. If both pass, it is not.
#
# Against real git repositories. Repository identity is a claim about what git does with
# worktrees and common directories; a hand-written model reproduces the surface remembered
# rather than the one that decides the verdict.
#
# defect: sp-37q (test-skew.sh deleted in 7357fb3 when the full gate was removed; this
#   recovers the foreign-subcommand coverage that gate.sh still relies on)
# covers: spira/skew.sh spira/gate.sh spira/exclude.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

SH="$TMP/spira"; RUN="$TMP/run"; WS="$TMP/ws"
mkdir -p "$SH" "$RUN" "$WS"
cp "$HERE/conf.sh" "$HERE/lib.sh" "$HERE/exclude.sh" "$HERE/skew.sh" "$SH/"

# The harness signature is three files together. This suite plants them using the real
# exclude.sh matcher so a change to the signature fails here rather than passing here
# and failing in production.
sig() { local d="$1"; mkdir -p "$d"; : > "$d/boundary"; : > "$d/gate.sh"; : > "$d/lib.sh"; }
commit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -q -m "${2:-c}" >/dev/null 2>&1; } # hermetic-ok: $1 is always a path under $WS ($TMP); positional params can't be statically traced
br() {   # br <repo> <branch> <path> — a branch touching exactly one path
    git -C "$WS/$1" checkout -q -b "$2" main 2>/dev/null
    mkdir -p "$(dirname "$WS/$1/$3")"; printf 'changed\n' >> "$WS/$1/$3"
    commit "$WS/$1" "$2"
    git -C "$WS/$1" checkout -q main
}

# home — the harness's OWN repository, with the signature at the root.
git init -q -b main "$WS/home"
sig "$WS/home"; printf 'x\n' > "$WS/home/aeon.sh"
commit "$WS/home" base

# guest — an ordinary repository that has quietly grown a SECOND copy of the harness in a
# subdirectory, alongside other files. This is the case the fence exists to catch.
git init -q -b main "$WS/guest"
sig "$WS/guest/.tools/spira"; printf 'x\n' > "$WS/guest/.tools/spira/aeon.sh"
mkdir -p "$WS/guest/src"; printf 'fn main() {}\n' > "$WS/guest/src/main.rs"
commit "$WS/guest" base

# plain — an ordinary repository carrying no harness at all.
git init -q -b main "$WS/plain"
printf 'hello\n' > "$WS/plain/README.md"
commit "$WS/plain" base

cat > "$SH/repo-map" <<MAP
home  | $WS/home  | push | main |  |
guest | $WS/guest | pr   | main |  |
plain | $WS/plain | pr   | main |  |
MAP

export SPIRA_CONF=/nonexistent-spira-conf
export SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB=/nonexistent-spira-db
export SPIRA_REPO="$WS/home" SPIRA_HOME_REPO=home

SKEW="$SH/skew.sh"

echo "test-skew-foreign.sh"

# =======================================================================================
# Repository identity — everything in foreign() rests on spira_same_repo.
# A worktree and its checkout are ONE repository; two checkouts are different.
# If this fails, every assertion below means nothing.
# =======================================================================================
echo
echo "repository identity:"
git -C "$WS/home" worktree add -q --detach "$TMP/home-wt" main 2>/dev/null
. "$SH/lib.sh"
spira_same_repo "$WS/home" "$TMP/home-wt" \
    && ok "a worktree and its checkout share an object store" \
    || bad "a worktree and its checkout share an object store" "spira_same_repo returned 1"
spira_same_repo "$WS/home" "$WS/guest" \
    && bad "two unrelated checkouts are distinct" "spira_same_repo returned 0" \
    || ok "two unrelated checkouts are distinct"

# =======================================================================================
# foreign — refusal path. This is the assertion that cannot be an always-pass.
# =======================================================================================
echo
echo "foreign — refusal:"
br guest touches-harness .tools/spira/aeon.sh
out="$("$SKEW" foreign "$WS/guest" main touches-harness 2>&1)"; rc=$?
is   "a branch changing a vendored harness is refused"           1 "$rc"
want "the refusal names the offending path"                      ".tools/spira/aeon.sh" "$out"
want "the refusal says where the work belongs"                   "repo:home" "$out"
want "the refusal names its own override"                        "SPIRA_ALLOW_FOREIGN_HARNESS" "$out"

# A mixed branch (harness + non-harness files): only the harness path appears.
git -C "$WS/guest" checkout -q -b touches-both main 2>/dev/null
mkdir -p "$WS/guest/src"; printf 'changed\n' >> "$WS/guest/src/lib.rs"
printf 'changed\n' >> "$WS/guest/.tools/spira/aeon.sh"; commit "$WS/guest" both
git -C "$WS/guest" checkout -q main
out="$("$SKEW" foreign "$WS/guest" main touches-both 2>/dev/null)"; rc=$?
is     "a mixed branch is refused"                               1 "$rc"
want   "it names the harness path"                               ".tools/spira/aeon.sh" "$out"
nowant "it does not name the repository's own source file"       "src/lib.rs" "$out"

# =======================================================================================
# foreign — pass path. These must be passes for the fence to be usable.
# =======================================================================================
echo
echo "foreign — pass:"
br guest touches-src src/main.rs
"$SKEW" foreign "$WS/guest" main touches-src >/dev/null 2>&1
is "ordinary work in a repository that HOLDS a copy is allowed" 0 "$?"

br plain touches-readme README.md
"$SKEW" foreign "$WS/plain" main touches-readme >/dev/null 2>&1
is "a repository carrying no harness is not this fence's business" 0 "$?"

# =======================================================================================
# The exemption IS an exemption, not an always-pass. The same branch, run twice:
# once with SPIRA_REPO pointing at its repository, once with it pointing elsewhere.
# One must pass, the other be refused — that distinction is the only thing that proves
# the exemption is conditional.
# =======================================================================================
echo
echo "foreign — exemption proved as conditional:"
br home touches-own gate.sh
"$SKEW" foreign "$WS/home" main touches-own >/dev/null 2>&1
is "the harness's own repository is exempt"                                                  0 "$?"
SPIRA_REPO="$WS/plain" "$SKEW" foreign "$WS/home" main touches-own >/dev/null 2>&1
is "and it is an exemption, not an always-pass — the same branch elsewhere is refused"       1 "$?"

SPIRA_ALLOW_FOREIGN_HARNESS=1 "$SKEW" foreign "$WS/guest" main touches-harness >/dev/null 2>&1
is "the override the refusal names actually works" 0 "$?"

# =======================================================================================
# The fence reads the REF, not the checkout. A branch may be the thing that adds the
# second harness, so the check must read what the tree will contain after merge —
# not what is on disk before it.
# =======================================================================================
echo
echo "foreign — reads the ref, not the checkout:"
git -C "$WS/plain" checkout -q -b adds-harness main
sig "$WS/plain/vendor/spira"; commit "$WS/plain" "vendor a harness"
git -C "$WS/plain" checkout -q main
out="$("$SKEW" foreign "$WS/plain" main adds-harness 2>&1)"; rc=$?
is   "a branch that ADDS a second harness is refused"            1 "$rc"
want "and the refusal names the directory being added"           "vendor/spira" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
