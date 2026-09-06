#!/usr/bin/env bash
#
# test-inventory.sh — the inventory fence's own suite, run by the landing gate.
#
# The assertion that matters is not "the tree is clean" — a matcher pointed at nothing says
# that too. It is that the fence CAN GO RED, on each shape it claims to catch, and that it
# refuses to report clean when it could not have found anything
# (law-absence-needs-a-positive-control).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
INV="$HERE/inventory.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1${2:+: $2}"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- the matcher, one file at a time -----------------------------------------------------
caught() {            # caught <name> <line>
    local f="$T/probe"; printf '%s\n' "$2" > "$f"
    local hits; hits="$(bash "$INV" --scan "$f")"
    [ -n "$hits" ] && ok "$1" || bad "$1" "not matched: $2"
}
ignored() {           # ignored <name> <line>
    local f="$T/probe"; printf '%s\n' "$2" > "$f"
    local hits; hits="$(bash "$INV" --scan "$f")"
    [ -z "$hits" ] && ok "$1" || bad "$1" "false positive: $hits"
}

echo
echo "the shapes it claims to catch"
caught "a home directory"            '# it lived at /home/someone/notes'
caught "a macOS home directory"      '# and at /Users/Someone/notes'
caught "a workspaces path"           'REPO=/workspaces/thing'
caught "a real e-mail address"       'author: person@somecompany.co'
caught "a named provenance mark"     '# (per Dana, 2026-01-02: "do it this way")'
# THE ONE THAT MATTERS MOST. Every occurrence this fence was written for was in a comment,
# and the guard it replaced stripped comments before looking.
caught "an offender inside a comment" '# we did this because /home/someone/repo broke'

echo
echo "what it must not flag"
ignored "an example address"     'contact: dev@example.invalid'
ignored "the git@host SSH form"  'url = git@github.com:owner/repo.git'
ignored "a home referred to as \$HOME" 'DB="$HOME/.local/share/spira/db"'
ignored "an ordinary sentence"   '# The base is not always `main`; ask the repository map.'

echo
echo "the operator's own deny-list"
printf 'my-service\nbuild-box-[0-9]+\n' > "$T/deny"
printf 'the my-service deploy runs on build-box-07\n' > "$T/probe"
hits="$(SPIRA_INVENTORY_DENY="$T/deny" bash "$INV" --scan "$T/probe")"
case "$hits" in *my-service*) ok "a deny-list entry is matched" ;;
                *) bad "a deny-list entry is matched" "got [$hits]" ;; esac
case "$hits" in *build-box-07*) ok "and a deny-list regex, not just a literal" ;;
                *) bad "and a deny-list regex, not just a literal" "got [$hits]" ;; esac
# Without the list the same line is clean, which is what proves the list did the work.
hits="$(SPIRA_INVENTORY_DENY="$T/none" bash "$INV" --scan "$T/probe")"
[ -z "$hits" ] && ok "and the same line is clean without it" \
                || bad "and the same line is clean without it" "got [$hits]"

echo
echo "the whole-tree run"
# THIS FILE IS EXEMPT FROM THE WHOLE-TREE SCAN, and it has to be: every probe above plants an
# offender, so a fence that judged its own suite would refuse the tree that proves it works.
# The exemption is asserted rather than assumed, because it is also the one place a real
# offender could hide.
case "$(bash "$INV" 2>&1)" in
    *test-inventory.sh*) bad "the suite is exempt from the whole-tree scan" ;;
    *) ok "the suite is exempt from the whole-tree scan" ;;
esac
# It must refuse rather than report clean when it has nothing to scan — an empty file list
# and a clean tree are indistinguishable in the output that anyone reads.
git init -q "$T/empty" && ( cd "$T/empty" && mkdir -p spira && cp "$INV" spira/ )
out="$(cd "$T/empty" && bash spira/inventory.sh 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "it refuses to report clean on a tree with nothing tracked" \
              || bad "it refuses to report clean on a tree with nothing tracked" "rc=$rc: $out"

# And it goes red on a tracked offender, which is the whole-tree half of the first section.
( cd "$T/empty" && printf '# built in /home/someone/src\n' > a.sh \
  && git add -A && git -c user.email=dev@example.invalid -c user.name=t commit -qm x )
out="$(cd "$T/empty" && bash spira/inventory.sh 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "it goes red on a tracked offender" \
              || bad "it goes red on a tracked offender" "rc=$rc"
case "$out" in *a.sh*) ok "and names the file" ;; *) bad "and names the file" "$out" ;; esac

# It does not flag itself. The patterns are string literals inside it, and a fence that
# reports itself is a fence somebody deletes.
( cd "$T/empty" && rm -f a.sh && git add -A \
  && git -c user.email=dev@example.invalid -c user.name=t commit -qm y )
out="$(cd "$T/empty" && bash spira/inventory.sh 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "it does not flag its own pattern list" \
              || bad "it does not flag its own pattern list" "$out"

# THE REAL TREE, last: everything above proves the fence works, so this one means something.
out="$(bash "$INV" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "this repository names no operator infrastructure" \
              || { bad "this repository names no operator infrastructure"; printf '%s\n' "$out" | head -20; }

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo "PASS: inventory"; exit 0; fi
echo "FAIL: inventory"; exit 1
