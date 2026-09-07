#!/usr/bin/env bash
#
# test-loom.sh — the read endpoint over the live graph, run by the landing gate.
#
#   ./test-loom.sh
#
# The endpoint is one route with three properties that are easy to break and invisible when
# broken: it is bounded to work in flight, it holds a snapshot so concurrent readers cost one
# query rather than one each, and it REFUSES a query that overruns its budget instead of
# serving it late. The third is the meter that says when the first two have stopped being
# enough, and a meter nobody has watched fire is a comment.
#
# THE ASSERTIONS LIVE IN RUST, and this builds what they need: a real `bd` on a throwaway
# database seeded with a graph whose shape the tests know — three live beads, one closed one
# that must never be served, a blocking edge and a parent-child edge, and a title containing
# an arrow, because the edge parser reads a format in which a title is quoted beside them.
#
# IT SKIPS WHEN CARGO IS ABSENT rather than failing. A gate that rejects good work because a
# toolchain is missing from an unattended environment teaches everyone to ignore it, which is
# worse than not gating. The skip is loud, and the gate names it.
#
# covers: loom/*
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOOM="$(cd "$HERE/../loom" 2>/dev/null && pwd)" || {
    echo "SKIP: no loom directory beside $HERE"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }

CARGO="$(command -v cargo || true)"
[ -n "$CARGO" ] || [ ! -x "$HOME/.cargo/bin/cargo" ] || CARGO="$HOME/.cargo/bin/cargo"
[ -n "$CARGO" ] || { echo "SKIP: cargo is not on PATH and not in \$HOME/.cargo/bin"; exit 0; }

# A target directory OUTSIDE the extracted tree, and --offline. The gate runs this against a
# checkout of the branch, so a fresh target/ would rebuild every dependency on every pass;
# sharing one cache makes it seconds. Offline because a gate must not need the network.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/spira-loom-target}"

echo "test-loom.sh"
echo

# ---------------------------------------------------------------------------------------
# The defaults the code carries must be the defaults the configuration file carries. This is
# the only thing standing between a key and a constant that has quietly stopped agreeing with
# it — the failure where an operator sets a value, the program keeps its own, and nothing
# anywhere reports a disagreement.
# ---------------------------------------------------------------------------------------
echo "the code's defaults and the configuration file's are the same defaults"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build_out="$("$CARGO" build --offline --manifest-path "$LOOM/Cargo.toml" 2>&1)"; build_rc=$?
if [ "$build_rc" -ne 0 ]; then
    if grep -q 'no matching package\|failed to download\|registry.*not.*available\|--offline' <<< "$build_out"; then
        echo "SKIP: cargo cannot resolve dependencies offline"; exit 0
    fi
    printf '%s\n' "$build_out" | tail -30
    echo "FAIL: loom does not build"
    exit 1
fi
BIN="$CARGO_TARGET_DIR/debug/loom"
[ -x "$BIN" ] || { echo "FAIL: no binary at $BIN after a successful build"; exit 1; }

# Both sides read in an explicit, minimal environment with no configuration file, so what is
# compared is the DEFAULT each carries rather than whatever this box happens to be set to.
NONE="$TMP/no-such.conf"
conf_default() {         # conf_default <key> -> the value conf.sh derives with no file
    env -i HOME="$TMP" PATH="$PATH" SPIRA_CONF="$NONE" \
        bash -c ". '$HERE/conf.sh' >/dev/null 2>&1; printf '%s' \"\${$1}\""
}
code_defaults="$(env -i HOME="$TMP" PATH="$PATH" "$BIN" --print-config 2>/dev/null)"
code_default() {         # code_default <key> -> the value the binary carries
    printf '%s\n' "$code_defaults" | sed -n "s/^$1=//p"
}
for k in SPIRA_LOOM_ADDR SPIRA_LOOM_BUDGET_MS SPIRA_LOOM_CACHE_S; do
    c="$(conf_default "$k")"
    # The positive control for this whole comparison: an empty expectation would be matched by
    # a binary that printed nothing at all.
    if [ -z "$c" ]; then bad "$k has a default in conf.sh" "conf.sh resolved it to empty"; continue; fi
    is "$k agrees between conf.sh and the binary" "$c" "$(code_default "$k")"
done

# A server that guessed a database would not fail — `bd` discovers one from its working
# directory — so it would come up healthy and serve a different harness's graph.
out="$(env -i HOME="$TMP" PATH="$PATH" SPIRA_DB= "$BIN" 2>&1)"; rc=$?
is   "it refuses to start with no database" "2" "$rc"
want "and says why"                         "SPIRA_DB" "$out"

# ---------------------------------------------------------------------------------------
# The endpoint itself, against a real bd on a throwaway database.
# ---------------------------------------------------------------------------------------
echo
echo "the endpoint, against a real bd"
. "$HERE/testdb.sh"
testdb_require test-loom.sh
testdb_up loom || { echo "FAIL: could not build a fixture database"; exit 1; }
trap 'testdb_drop >/dev/null 2>&1; rm -rf "$TMP"' EXIT INT TERM

# ONE TITLE CARRIES A QUOTE AND A BACKSLASH on purpose. The response body is assembled by
# splicing the already-serialised rows into a short header rather than re-serialising most of
# a megabyte per request, and a title that needs escaping is what would find a splice that had
# stopped producing valid JSON.
#
# THREE LIVE BEADS AND ONE CLOSED ONE. The closed one is the positive control for the bound
# that makes a per-request read affordable: without a closed bead in the database, "no closed
# beads were served" is satisfied by a query that does not work at all.
printf '%s\n' \
 '{"id":"sp-aaa","title":"alpha","status":"open","issue_type":"task","priority":1,"labels":["repo:one"],"updated_at":"2026-09-04T00:00:00Z"}' \
 '{"id":"sp-bbb","title":"beta \"quoted\" and a \\ backslash","status":"open","issue_type":"epic","priority":2,"labels":[],"updated_at":"2026-09-04T00:00:00Z"}' \
 '{"id":"sp-ccc","title":"gamma","status":"in_progress","issue_type":"task","priority":1,"labels":[],"updated_at":"2026-09-04T00:00:00Z"}' \
 '{"id":"sp-zzz","title":"omega, finished","status":"closed","issue_type":"task","priority":3,"labels":[],"updated_at":"2026-09-04T00:00:00Z"}' \
 | testdb_seed || { echo "FAIL: could not seed the fixture"; exit 1; }

# Two edge TYPES, because the type is what separates a real blocking chain from an epic's
# children — different graphs drawn from the same rows. And a third edge INTO the closed bead,
# which is the positive control for the dropped-edge counter: an edge to a bead that is not
# being served cannot be drawn, and a graph quietly missing edges still looks like a graph.
printf '%s\n' \
 '{"from":"sp-aaa","to":"sp-ccc","type":"blocks"}' \
 '{"from":"sp-aaa","to":"sp-bbb","type":"parent-child"}' \
 '{"from":"sp-ccc","to":"sp-zzz","type":"blocks"}' \
 | bd -C "$SPIRA_DB" dep add --file - >/dev/null 2>&1 \
 || { echo "FAIL: could not wire the fixture's dependency edges"; exit 1; }

REAL_BD="$(command -v bd)"
[ -n "$REAL_BD" ] || { echo "FAIL: bd is on PATH for the fixture but not for the tests"; exit 1; }

# An explicit, minimal environment: a suite that inherits a real spira.conf is asserting
# against one box, and one that inherits SPIRA_LOOM_BUDGET_MS is asserting against a setting
# made an hour ago. Everything the tests need is named here and nothing else is.
out="$(env -i HOME="$HOME" PATH="$PATH" TERM=dumb \
        CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
        LOOM_TEST_DB="$SPIRA_DB" LOOM_TEST_BD="$REAL_BD" \
        "$CARGO" test --offline --manifest-path "$LOOM/Cargo.toml" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tail -40
    bad "the endpoint's own tests" "cargo test exited $rc"
else
    # A cargo run that compiled nothing and ran nothing also exits 0, and so does one whose
    # integration binary was skipped. So the tests this bead exists for are required to be
    # SEEN passing by name, rather than inferred from the absence of a failure.
    printf '%s\n' "$out" | grep -E '^test result:' | sed 's/^/  /'
    for t in the_payload_is_bounded_to_live_work_and_carries_typed_edges \
             two_requests_inside_the_window_cost_one_refresh \
             a_query_over_budget_is_refused_rather_than_served_late \
             a_closed_row_is_dropped_and_counted \
             an_edge_whose_other_end_is_not_served_is_dropped_and_counted; do
        if grep -qE "^test .*$t \.\.\. ok$" <<< "$out"; then ok "$t"
        else bad "$t" "cargo did not report it as run"; fi
    done
fi

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: loom"
exit 0
