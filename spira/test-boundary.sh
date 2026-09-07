#!/usr/bin/env bash
#
# test-boundary.sh — the boundary renderer's own suite, run by the landing gate.
#
#   ./test-boundary.sh
#
# What it is protecting is not the table, it is the CLAIM that both documents say the same
# thing. `boundary.sh check` is what makes that claim mechanical, so the tests that matter
# most are the ones proving `check` can still fail: a check that cannot go red is a check
# that reports every state as all-clear, which is the shape of guard this repository has
# been bitten by before.
#
# Everything runs against fixtures in a temporary directory. Nothing touches the real
# manifest or either real document.
#
# covers: spira/boundary.sh spira/boundary
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOUNDARY="$HERE/boundary.sh"
MANIFEST="$HERE/boundary"

# THE FIXTURES SOURCE conf.sh, SO THIS SUITE MUST NOT INHERIT THE OPERATOR'S CONFIG. With a
# real spira.conf in scope, SPIRA_WIKI resolves to a real wiki page and `write` against a
# fixture manifest would rewrite it. Point the loader at a file that does not exist, which is
# the documented way to ask for no config at all (law-gates-run-in-a-clean-environment).
export SPIRA_CONF=/nonexistent/spira.conf
unset SPIRA_WIKI

fail=0
ok()   { echo "  ok   — $1"; }
bad()  { echo "  FAIL — $1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------- the shipped manifest
# Every row has three fields and a known owner. The renderer exits non-zero on either, so
# a malformed row cannot reach a document as a half-rendered line.
if out="$("$BOUNDARY" render 2>&1)"; then ok "shipped manifest renders"
else bad "shipped manifest does not render: $(tail -2 <<< "$out")"; fi

for owner in spira brain neither; do
    grep -q "$owner" <<< "$out" || bad "rendered table has no $owner section"
done
ok "all three owners are represented"

# The two documents this repository publishes are in step with the manifest. This is the
# assertion the whole file exists for, and it is the one the gate will actually catch.
if "$BOUNDARY" check >/dev/null 2>&1; then ok "both documents are current"
else bad "boundary.sh check is red — run boundary.sh write"; fi

# ---------------------------------------------------------------- check can go red
# THE FIXTURE MIRRORS THE REAL LAYOUT — script in `<root>/spira/`, README at `<root>/`.
# A fixture that flattens the tree it is testing stops testing path resolution, which is
# most of what this script does.
fixture() {                 # fixture <root> — a harness tree with an empty README
    mkdir -p "$1/spira"
    cp "$BOUNDARY" "$HERE/conf.sh" "$1/spira/"
    printf '<!-- BOUNDARY:BEGIN -->\n<!-- BOUNDARY:END -->\n' > "$1/README.md"
}

fixture "$T/h"
printf 'spira | a/b | one\nbrain | wiki/ | two\n' > "$T/h/spira/boundary"

"$T/h/spira/boundary.sh" write >/dev/null 2>&1 || bad "fixture write failed"
if "$T/h/spira/boundary.sh" check >/dev/null 2>&1; then ok "check passes a freshly written file"
else bad "check is red immediately after write"; fi

# A hand-edited region is caught. This is the case the marker comment promises — 'editing
# this does nothing' is only true if something notices.
sed -i 's/| one |/| tampered |/' "$T/h/README.md"
if "$T/h/spira/boundary.sh" check >/dev/null 2>&1; then bad "check passed a hand-edited region"
else ok "check rejects a hand-edited region"; fi

"$T/h/spira/boundary.sh" write >/dev/null 2>&1
# A manifest change that nobody re-rendered is caught too — the other direction, and the one
# that happens when a row is corrected in a hurry.
printf 'neither | the database | three\n' >> "$T/h/spira/boundary"
if "$T/h/spira/boundary.sh" check >/dev/null 2>&1; then bad "check passed a stale document"
else ok "check rejects a document stale against the manifest"; fi

# ---------------------------------------------------------------- rule 2, mechanically
# The harness must run with no wiki anywhere. `write` skips the absent page and still
# succeeds; only a missing README is fatal, because that one is the harness's own.
"$T/h/spira/boundary.sh" write >/dev/null 2>&1
if out="$("$T/h/spira/boundary.sh" write 2>&1)" && grep -q 'SPIRA_WIKI is unset' <<< "$out"; then
    ok "write succeeds with no wiki configured at all"
else
    bad "write did not report an unconfigured wiki: $(tail -2 <<< "$out")"
fi

# Configured but absent is the other half, and it is the one that must not be mistaken for
# success at writing: a wiki checkout that moved should say so, not pass in silence.
if out="$(SPIRA_WIKI="$T/no-such-wiki" "$T/h/spira/boundary.sh" write 2>&1)" \
   && grep -q 'skipped' <<< "$out"; then
    ok "write skips a configured wiki page that is not there"
else
    bad "write did not skip an absent wiki page: $(tail -2 <<< "$out")"
fi

# And it does write one that IS there, which is what makes the two skips above meaningful
# rather than a renderer that never touches the wiki side at all
# (law-absence-needs-a-positive-control).
mkdir -p "$T/wiki/wiki/projects/spira"
printf '<!-- BOUNDARY:BEGIN -->\n<!-- BOUNDARY:END -->\n' > "$T/wiki/wiki/projects/spira/repo-boundary.md"
SPIRA_WIKI="$T/wiki" "$T/h/spira/boundary.sh" write >/dev/null 2>&1
if grep -q 'one' "$T/wiki/wiki/projects/spira/repo-boundary.md"; then
    ok "write publishes into a configured wiki page"
else
    bad "write did not publish into a wiki page that exists"
fi

rm -f "$T/h/README.md"
if "$T/h/spira/boundary.sh" write >/dev/null 2>&1; then bad "write passed with no README"
else ok "write fails when the harness's own README is missing"; fi

# ---------------------------------------------------------------- malformed input
fixture "$T/m"

printf 'spira | only-two-fields\n' > "$T/m/spira/boundary"
"$T/m/spira/boundary.sh" render >/dev/null 2>&1 \
    && bad "render accepted a two-field row" || ok "render refuses a two-field row"

printf 'sprira | a/b | typo in the owner\n' > "$T/m/spira/boundary"
"$T/m/spira/boundary.sh" render >/dev/null 2>&1 \
    && bad "render accepted an unknown owner" || ok "render refuses an unknown owner"

printf '# comments only\n' > "$T/m/spira/boundary"
"$T/m/spira/boundary.sh" render >/dev/null 2>&1 \
    && bad "render accepted an empty manifest" || ok "render refuses an empty manifest"

# A document with no marker pair is an error, not a silent no-op: a document that quietly
# stopped publishing the boundary is exactly the drift this is here to prevent.
printf 'spira | a/b | one\n' > "$T/m/spira/boundary"
printf '# no markers here\n' > "$T/m/README.md"
"$T/m/spira/boundary.sh" write >/dev/null 2>&1 \
    && bad "write accepted a README with no marker pair" || ok "write refuses a README with no markers"

if [ "$fail" = 0 ]; then echo "PASS: boundary"; exit 0; fi
echo "FAIL: boundary"; exit 1
