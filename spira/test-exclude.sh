#!/usr/bin/env bash
#
# test-exclude.sh — exclude.sh's own suite, discovered and run by the landing gate.
#
#   ./test-exclude.sh
#
# WHAT IS BEING PROTECTED IS NOT THE PATTERN LIST, IT IS THE CLAIM THAT THE FENCE FIRES.
# The whole value of this guard is a refusal, and a refusal is the one behaviour that a
# broken guard never demonstrates: an exclude.sh that always exits 0 passes every "the
# harness is clean" assertion in this file and every real invocation, silently, until the
# day it matters. So every fence here is proved in BOTH directions — refused when it must
# refuse, and allowed when it must allow (law-absence-needs-a-positive-control).
#
# Against a real git repository in a temp directory, with a real `git commit` driving the
# real hook, never a hand-written model of either. A stub reproduces the surface you
# remember and drifts in silence; git's own behaviour around core.hooksPath, staging and
# --no-verify is precisely what is being relied on here.
#
# covers: spira/exclude.sh spira/hooks/*
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EX="$HERE/exclude.sh"

fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A repository shaped like the harness AFTER sp-repo-move: the signature at the root, so
# the scope is everything. That is the state this guard exists to protect.
mk() {                                   # mk <dir>  -> a harness repo at that path
    local r="$1"
    mkdir -p "$r/hooks"
    : > "$r/boundary"; : > "$r/gate.sh"; : > "$r/lib.sh"
    cp "$EX" "$r/exclude.sh"
    cp "$HERE/hooks/pre-commit" "$r/hooks/pre-commit"
    chmod +x "$r/exclude.sh" "$r/hooks/pre-commit"
    printf 'the harness\n' > "$r/README.md"
    git -C "$r" init -q 2>/dev/null || { git init -q "$r"; }
    git -C "$r" config user.email t@t; git -C "$r" config user.name t
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -qm init >/dev/null 2>&1
}

# ------------------------------------------------------------------ scope is derived
# The signature is three files together. One or two of them is not the harness, and a
# directory that scores two must not be mistaken for one, or the scope silently widens to
# some unrelated tree and every path in it becomes an offence.
scope_of() { printf '%s\n' "$1" | tr ' ' '\n' | awk '
    { n=split($0,c,"/"); d=(n==1?".":substr($0,1,length($0)-length(c[n])-1)); seen[d"/"c[n]]=1; dirs[d]=1 }
    END { for (d in dirs) if ((d"/boundary") in seen && (d"/gate.sh") in seen && (d"/lib.sh") in seen) { print d; exit } }'; }

[ "$(scope_of "boundary gate.sh lib.sh")" = "." ] \
    && ok "harness at the root scopes to the whole repository" \
    || bad "harness at the root did not scope to ."
[ "$(scope_of "a/b/boundary a/b/gate.sh a/b/lib.sh a/z")" = "a/b" ] \
    && ok "nested harness scopes to its own directory" \
    || bad "nested harness scoped wrongly"
[ -z "$(scope_of "boundary gate.sh")" ] \
    && ok "two of the three files is not a harness" \
    || bad "an incomplete signature was read as a harness"

# ------------------------------------------------------------------ filter, both ways
# The gate hands filter a branch's whole tree; it must find the offence and it must exit 3
# rather than 0 when there is no harness in the list, because "found nothing" and "could
# not look" are the same output otherwise and only one of them is all-clear.
tree=$'boundary\ngate.sh\nlib.sh\n.beads/config.yaml\nREADME.md'
out="$("$EX" filter <<< "$tree")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = ".beads/config.yaml" ] \
    && ok "filter finds a staged database in a root-scoped harness" \
    || bad "filter missed .beads/config.yaml (rc=$rc out='$out')"

out="$("$EX" filter <<< $'boundary\ngate.sh\nlib.sh\nREADME.md')"; rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] \
    && ok "filter passes a clean harness tree" \
    || bad "filter flagged a clean tree (rc=$rc out='$out')"

"$EX" filter <<< $'a.jsonl\nb/c.db' >/dev/null 2>&1
[ "$?" = 3 ] && ok "filter announces a path list with no harness in it (exit 3)" \
             || bad "filter reported a pass on a list it could not scope"

# The scoping is not cosmetic: brain tracks twelve .jsonl corpora on purpose, including the
# bead export itself, and a fence that flagged those would be overridden by reflex within a
# day. Nested harness, offending file outside it -> not an offence.
out="$("$EX" filter <<< $'.claude/spira/boundary\n.claude/spira/gate.sh\n.claude/spira/lib.sh\nraw/spira-beads/spira.jsonl')"
[ -z "$out" ] && ok "a .jsonl outside a nested harness is not an offence" \
              || bad "flagged a path outside the harness scope: $out"

out="$("$EX" filter <<< $'.claude/spira/boundary\n.claude/spira/gate.sh\n.claude/spira/lib.sh\n.claude/spira/x.jsonl')"
[ "$out" = ".claude/spira/x.jsonl" ] && ok "a .jsonl inside a nested harness is an offence" \
                                     || bad "missed a .jsonl inside the harness: '$out'"

# Every shape in the list, one at a time, so a pattern that stops matching is named.
for p in .beads/config.yaml .beads/metadata.json .dolt/noms/x issues.jsonl beads.db \
         beads.db-wal store.sqlite3 store.sqlite3-shm .beads-credential-key; do
    out="$("$EX" filter <<< "boundary"$'\n'"gate.sh"$'\n'"lib.sh"$'\n'"$p")"
    [ "$out" = "$p" ] || bad "pattern miss: $p"
done
ok "every forbidden shape is matched"

for p in README.md lib.sh notes.md src/main.rs config.yaml data.json; do
    out="$("$EX" filter <<< "boundary"$'\n'"gate.sh"$'\n'"lib.sh"$'\n'"$p")"
    [ -z "$out" ] || bad "false positive: $p"
done
ok "ordinary harness files are not flagged"

# ------------------------------------------------------------------ check, both assertions
mk "$T/clean"
if "$EX" check "$T/clean" >/dev/null 2>&1; then ok "check passes a clean harness checkout"
else bad "check failed a clean harness checkout"; fi

# B — a tracked export. This is the plain case and the one a hook would also have caught.
mk "$T/exported"
printf '{"id":"sp-1"}\n' > "$T/exported/spira.jsonl"
git -C "$T/exported" add -A >/dev/null 2>&1
if "$EX" check "$T/exported" >/dev/null 2>&1; then bad "check passed a tracked bead export"
else ok "check refuses a tracked bead export"; fi

# A — the checkout IS the beads project directory, and .gitignore hides it from git.
# THIS IS THE ASSERTION THAT MATTERS MOST and the one a single-assertion guard gets wrong:
# ignoring `.beads/` silences the exclusion check while leaving the identity intact, so the
# fence reports all-clear on exactly the state it was built to refuse. This is not
# hypothetical — an installation here is in that state today.
mk "$T/isalso"
printf '.beads/\n' > "$T/isalso/.gitignore"
mkdir -p "$T/isalso/.beads"; printf 'x\n' > "$T/isalso/.beads/config.yaml"
git -C "$T/isalso" add -A >/dev/null 2>&1
git -C "$T/isalso" commit -qm ignore >/dev/null 2>&1
if [ -z "$(git -C "$T/isalso" ls-files --cached --others --exclude-standard | grep '^\.beads/')" ]; then
    ok "the fixture's .beads/ really is invisible to git"
else
    bad "fixture is wrong — .beads/ is still visible to git, so the next assertion proves nothing"
fi
if "$EX" check "$T/isalso" >/dev/null 2>&1; then
    bad "check passed a checkout that IS a beads project directory"
else
    ok "check refuses a checkout that is also the beads project directory"
fi

# A repository with no harness in it is announced, not passed.
mkdir -p "$T/plain"; git init -q "$T/plain"
git -C "$T/plain" config user.email t@t; git -C "$T/plain" config user.name t
printf 'x\n' > "$T/plain/a.jsonl"
"$EX" check "$T/plain" >/dev/null 2>&1
[ "$?" = 3 ] && ok "check announces a repository with no harness (exit 3)" \
             || bad "check did not distinguish 'no harness here' from 'clean'"

# ------------------------------------------------------------------ the hook, for real
# Driven by `git commit`, through core.hooksPath, exactly as a colleague's clone would.
mk "$T/hooked"
"$EX" install "$T/hooked" >/dev/null 2>&1 || bad "install failed"
[ "$(git -C "$T/hooked" config core.hooksPath)" = "hooks" ] \
    && ok "install arms core.hooksPath" || bad "install did not set core.hooksPath"
grep -q '^\.beads/$' "$T/hooked/.gitignore" && ok "install writes the ignore stanza" \
                                            || bad "install did not write the ignore stanza"

before="$(wc -l < "$T/hooked/.gitignore")"
"$EX" install "$T/hooked" >/dev/null 2>&1
[ "$(wc -l < "$T/hooked/.gitignore")" = "$before" ] \
    && ok "install is idempotent" || bad "install appended the stanza twice"

# The stanza is anchored when the harness is NESTED, so the wiki repository can carry the
# fence over .claude/spira/ without ignoring raw/'s deliberate .jsonl corpora. Asserted
# through `git check-ignore` rather than by reading the patterns back, because what is
# being trusted here is git's `**` semantics and not my memory of them.
mkdir -p "$T/nested/.claude/spira/hooks" "$T/nested/raw"
: > "$T/nested/.claude/spira/boundary"; : > "$T/nested/.claude/spira/gate.sh"
: > "$T/nested/.claude/spira/lib.sh"
cp "$EX" "$T/nested/.claude/spira/exclude.sh"
cp "$HERE/hooks/pre-commit" "$T/nested/.claude/spira/hooks/pre-commit"
chmod +x "$T/nested/.claude/spira/exclude.sh" "$T/nested/.claude/spira/hooks/pre-commit"
git init -q "$T/nested"
git -C "$T/nested" config user.email t@t; git -C "$T/nested" config user.name t
"$EX" install "$T/nested" >/dev/null 2>&1 || bad "install failed on a nested harness"

ign() { git -C "$T/nested" check-ignore -q "$1"; }
ign .claude/spira/x.jsonl        && ok "a .jsonl in the harness is ignored" \
                                 || bad "a .jsonl in the harness is not ignored"
ign .claude/spira/.beads/config.yaml && ok "a database in the harness is ignored" \
                                 || bad "a database in the harness is not ignored"
ign raw/spira-beads/spira.jsonl  && bad "the wiki's own bead export got ignored" \
                                 || ok "the wiki's .jsonl corpora are untouched"
ign raw/notes.db                 && bad "a .db outside the harness got ignored" \
                                 || ok "the stanza does not reach outside the harness"

# An ordinary commit still goes through. A fence that blocks the work is not a fence.
printf 'more\n' >> "$T/hooked/README.md"
git -C "$T/hooked" add README.md >/dev/null 2>&1
if git -C "$T/hooked" commit -qm ordinary >/dev/null 2>&1; then ok "the hook allows an ordinary commit"
else bad "the hook blocked an ordinary commit"; fi

# And the database is refused — staged with -f, because fence 0 already stops the accident
# and what is under test here is fence 1, the deliberate override of fence 0.
mkdir -p "$T/hooked/.beads"; printf 'db\n' > "$T/hooked/.beads/config.yaml"
git -C "$T/hooked" add -f .beads/config.yaml >/dev/null 2>&1
if out="$(git -C "$T/hooked" commit -m nope 2>&1)"; then
    bad "the hook allowed a commit carrying .beads/config.yaml"
else
    ok "the hook refuses a commit carrying the database"
    grep -q 'never public' <<< "$out" && ok "the refusal says why" || bad "the refusal is bare"
fi

# The refusal must not have landed anything.
git -C "$T/hooked" log --oneline | grep -q nope && bad "the refused commit landed anyway" \
                                                || ok "nothing was committed"

# --no-verify is git's own override and the reason the landing gate is the second fence.
# Proving it bypasses the hook is what makes the gate's existence justified rather than
# belt-and-braces: this is the exact path by which a database would otherwise reach main.
if git -C "$T/hooked" commit -qm bypass --no-verify >/dev/null 2>&1; then
    ok "--no-verify bypasses the hook, as git guarantees"
    tree="$(git -C "$T/hooked" ls-tree -r --name-only HEAD)"
    if "$EX" filter <<< "$tree" | grep -q '^\.beads/config.yaml$'; then
        ok "the gate's check catches what --no-verify let through"
    else
        bad "the gate's check missed a database that bypassed the hook"
    fi
else
    bad "--no-verify did not bypass the hook — the fixture no longer proves the gate is needed"
fi

# ------------------------------------------------------------------ the live tree
# The shipping tree of THIS checkout, which is what the gate asserts on every branch.
if out="$("$EX" check "$(git -C "$HERE" rev-parse --show-toplevel)" 2>&1)"; then
    ok "this checkout's harness scope is clean"
else
    bad "this checkout carries beads data: $(tail -3 <<< "$out")"
fi

if [ "$fail" = 0 ]; then echo "PASS: exclude"; exit 0; fi
echo "FAIL: exclude"; exit 1
