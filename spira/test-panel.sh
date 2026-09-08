#!/usr/bin/env bash
#
# test-panel.sh — the panel's Rust unit tests, visible to the timed runner.
#
#   ./test-panel.sh
#
# THE FAILURE THIS SUITE EXISTS FOR. The panel has 97 Rust unit tests covering
# rendering geometry, age formatting, thread ordering, and input wrapping — but
# none of them were discoverable by suites.sh, because suites.sh globs for
# test-*.sh files and cargo test is not one. They ran only when a developer ran
# cargo test by hand; the timed runner never saw them and the suite list printed
# a gap where `cockpit/panel/src/render.rs` should have been covered.
#
# This suite is the shell shim that closes the gap. It is a single `cargo test`
# call; the assertions live in render.rs and main.rs where the code they test
# does. Adding it here puts those 97 checks onto the timed runner's schedule
# without duplicating them.
#
# covers: cockpit/panel/src/render.rs cockpit/panel/src/main.rs cockpit/panel/src/store.rs
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }

MANIFEST="$REPO/cockpit/panel/Cargo.toml"
if [ ! -f "$MANIFEST" ]; then
    bad "manifest exists" "no Cargo.toml at $MANIFEST"
    echo "FAIL $fail / $((pass+fail))"; exit 1
fi

# Run the full panel suite. Output goes to the terminal; a failure exits non-zero
# and the runner captures it as a red. There is no point in suppressing cargo's
# output here — the test names say what broke.
if cargo test --manifest-path "$MANIFEST" 2>&1; then
    ok "panel cargo test suite"
else
    bad "panel cargo test suite" "cargo test exited non-zero — see above"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
