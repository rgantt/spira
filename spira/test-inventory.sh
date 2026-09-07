#!/usr/bin/env bash
#
# test-inventory.sh — the inventory fence's own suite, run by the landing gate.
#
# The assertion that matters is not "the tree is clean" — a matcher pointed at nothing says
# that too. It is that the fence CAN GO RED, on each shape it claims to catch, and that it
# refuses to report clean when it could not have found anything
# (law-absence-needs-a-positive-control).
#
# covers: spira/inventory.sh spira/inventory-deny
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
# A systemd template instance has the shape of an address exactly, and this harness renders
# one unit per watcher that way — so without the exemption every file naming an instance is
# refused as though it carried somebody's mail.
ignored "a systemd instance unit"  'systemctl --user enable spira-watch@answers.service'
ignored "and a template unit"      'UNITS=(spira-watch@.service)'
# THE EXEMPTION IS ON THE UNIT SUFFIX AND NOTHING WIDER. A domain that merely looks unitish
# is still an address, or the exemption has quietly turned the mail check off.
caught "but not an address at a lookalike domain" 'author: person@service.co'

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
# EVERY CASE HERE RUNS AGAINST A THROWAWAY REPOSITORY, not the real checkout. The whole-tree
# entry point reads the git INDEX, so a case that needs it needs a checkout — and this suite
# is run by the landing gate against a tree taken from a branch, which is not guaranteed to
# have one. Where the tree is ours, the run is known to have happened, which is what makes a
# silent result mean anything (law-absence-needs-a-positive-control).
#
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

# AND THIS FILE IS EXEMPT TOO, which it has to be: every probe above plants an offender, so a
# fence that judged its own suite would refuse the tree that proves it works. Asserted in the
# fixture rather than against the real checkout, because the exemption only means anything if
# the scan RAN — and a run that refused for want of an index names no files either, so it
# reads exactly like a working exemption. Here the scan is known to have exited 0 over a known
# file list, and this file carries an offender of every shape above, so a broken exemption
# goes red instead of silent.
( cd "$T/empty" && cp "$HERE/test-inventory.sh" spira/ && git add -A \
  && git -c user.email=dev@example.invalid -c user.name=t commit -qm z )
out="$(cd "$T/empty" && bash spira/inventory.sh 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the suite is exempt from the whole-tree scan" \
              || bad "the suite is exempt from the whole-tree scan" "rc=$rc: $out"

# THE REAL TREE, last: everything above proves the fence works, so this one means something.
#
# It is the only case that needs a git checkout, and it must SKIP rather than fail when there
# is none. The landing gate runs this suite against a tree taken from the branch under trial;
# a suite that assumes an index there fails on every branch, for a reason that is about the
# gate's plumbing rather than the branch. Deleting the case is not the alternative — it is
# what distinguishes a sanitising pass from an intention to have done one.
#
# A SKIP IS ANNOUNCED, NEVER SWALLOWED. gate-spira.sh reports a suite whose output carries one,
# because a check that could not run must not read as all-clear (law-alerts-must-be-actionable).
# The branch itself is still scanned when this skips: the gate walks the tree's files through
# `inventory.sh --scan` directly, which is what the whole-tree entry point is a convenience over.
if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
    out="$(bash "$INV" 2>&1)"; rc=$?
    [ "$rc" = 0 ] && ok "this repository names no operator infrastructure" \
                  || { bad "this repository names no operator infrastructure"; printf '%s\n' "$out" | head -20; }
else
    echo "  SKIP  not a git checkout — the real tree was not scanned"
fi

# AND THE SKIP IS PROVED, not assumed: run this file where there is no `.git` and require it to
# come back green with the announcement the gate looks for. That is the defect itself as a
# check — the suite was believed to be gate-safe and was not — and it is one recursion deep, so
# it carries its own guard. GIT_CEILING_DIRECTORIES makes the tree treeless on any host, rather
# than trusting that the temporary directory sits outside every repository.
if [ -z "${SPIRA_TEST_INVENTORY_TREELESS:-}" ]; then
    mkdir -p "$T/treeless/spira"
    cp "$INV" "$HERE/test-inventory.sh" "$T/treeless/spira/"
    out="$(SPIRA_TEST_INVENTORY_TREELESS=1 GIT_CEILING_DIRECTORIES="$T" \
           bash "$T/treeless/spira/test-inventory.sh" 2>&1)"; rc=$?
    [ "$rc" = 0 ] && ok "the suite passes where there is no git checkout" \
                  || { bad "the suite passes where there is no git checkout" "rc=$rc"
                       printf '%s\n' "$out" | tail -8 | sed 's/^/      /'; }
    case "$out" in
        *SKIP*) ok "and announces the skip the gate reports" ;;
        *) bad "and announces the skip the gate reports" "no SKIP line in its output" ;;
    esac
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo "PASS: inventory"; exit 0; fi
echo "FAIL: inventory"; exit 1
