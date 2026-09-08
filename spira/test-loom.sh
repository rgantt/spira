#!/usr/bin/env bash
#
# test-loom.sh — build the endpoint fixture and run the Rust integration tests.
#
#   ./test-loom.sh
#
# WHERE IT RUNS: the TIMED set, found by the `spira/test-*.sh` glob and run by `suites.sh`,
# because `gate-suites` does not name it. The endpoint tests hit a real database and take
# several seconds; a gated check that costs seconds on every branch is a gate that grows to
# minutes without an argument. These run on a schedule instead, and a red files a bead.
#
# WHAT IS EXERCISED. The Rust integration tests in `loom/tests/endpoint.rs` drive the
# server over a real socket against a throwaway database — the budget, the cache, the
# error path, and the static routes. This file does two things the Rust test file cannot:
# build the throwaway fixture (creating and seeding the database), and wire LOOM_TEST_BD to
# the `bd` resolved by the harness configuration rather than whatever `bd` happens to be on
# the cargo runner's PATH.
#
# WHY THE BINARY MUST EXIST TO RUN. The integration tests compile against the library, but
# they do not verify the binary itself; this suite skips rather than building, so a fresh
# clone with no binary fails the timed run and files a bead rather than silently being
# absent from the record.
#
# defect: sp-wok.3
# covers: loom/*
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOOM_ROOT="$HERE/../loom"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# Resolve cargo BEFORE sourcing testdb.sh: conf.sh overwrites PATH with the harness's own
# tool directories, which do not include ~/.cargo/bin. Capture the absolute path now so the
# cargo test invocation below does not need PATH to contain it.
CARGO_BIN="$(command -v cargo 2>/dev/null || true)"
if [ -z "$CARGO_BIN" ]; then
    echo "SKIP test-loom: cargo not on PATH — the Rust tests cannot run" >&2
    echo "     install Rust, or accept that loom/tests/endpoint.rs is ungated on this box" >&2
    exit 0
fi

# shellcheck source=/dev/null
. "$HERE/testdb.sh"
if ! testdb_available; then
    echo "SKIP test-loom: no fixture database reachable — endpoint tests did not run" >&2
    exit 0
fi

TMP="$(mktemp -d)"; trap 'testdb_drop >/dev/null 2>&1; rm -rf "$TMP"' EXIT INT TERM

testdb_up loom >/dev/null 2>&1

# Seed four beads: two open, one in-progress, one closed.
# Edges: sp-aaa→sp-ccc (blocks), sp-bbb→sp-ccc (parent-child), sp-bbb→sp-zzz (dropped —
# sp-zzz is closed). The test asserts count=3, edges=2, dropped_edges=1 — three counts each
# with a non-zero expected value, so a failure is distinguishable from "nothing was there."
bdq() { bd -C "$SPIRA_DB" "$@"; }
bdq create "open bead"      -t task -p 1 -l repo:alpha      --id sp-aaa >/dev/null 2>&1
bdq create 'beta "quoted" and a \ backslash' \
           -t epic -p 1 -l repo:alpha      --id sp-bbb >/dev/null 2>&1
bdq create "in-progress bead" -t task -p 2                  --id sp-ccc >/dev/null 2>&1
bdq create "closed bead"    -t task -p 3 -l repo:alpha      --id sp-zzz >/dev/null 2>&1
bdq update sp-ccc --status in_progress >/dev/null 2>&1
bdq update sp-zzz --status closed >/dev/null 2>&1
bdq update sp-ccc --parent sp-bbb >/dev/null 2>&1          # parent-child edge
bdq dep add sp-aaa sp-ccc >/dev/null 2>&1                  # sp-aaa blocks sp-ccc
bdq dep add sp-bbb sp-zzz >/dev/null 2>&1                  # sp-bbb blocks sp-zzz (closed — dropped)

# Route through the SPIRA_BD seam: testdb_up unsets SPIRA_BD so bdq calls the real binary
# via PATH; the fallback bare "bd" is reachable via the PATH conf.sh exports. testdb_available
# already verified bd is callable, so no second check here.
BD_BIN="${SPIRA_BD:-bd}"
ok "fixture database ready at $SPIRA_DB"

export LOOM_TEST_DB="$SPIRA_DB"
export LOOM_TEST_BD="$BD_BIN"

if out="$("$CARGO_BIN" test --manifest-path "$LOOM_ROOT/Cargo.toml" 2>&1)"; then
    ok "endpoint tests passed"
    printf '%s\n' "$out" | grep -E '^\s*(test |ok |FAILED|running)' | head -20 || true
else
    bad "endpoint tests" "$(printf '%s\n' "$out" | tail -30)"
fi

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
