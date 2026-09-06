#!/usr/bin/env bash
#
# test-panel.sh — the attention pane's own suite, run by the landing gate.
#
#   ./test-panel.sh
#
# The pane is where every escalation is read, and its invariants are asserted in Rust —
# that the frame is exactly the terminal's height, that no row overflows its width, that
# the body of a bead is never rendered dim, that chrome is two bands and not three. Those
# checks existed and nothing ran them: `gate.sh` runs `.claude/spira/test-*.sh`, and the
# panel's tests live behind `cargo test` in `.claude/cockpit/panel`. A guard nobody invokes
# is a comment.
#
# It SKIPS when cargo is absent rather than failing. The gate must be deterministic, and a
# gate that rejects good work because a toolchain is missing from an unattended environment
# teaches everyone to ignore it — which is worse than not gating at all. The skip is loud.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$(cd "$HERE/../cockpit/panel" 2>/dev/null && pwd)" || {
    echo "SKIP: no panel directory beside $HERE"; exit 0; }

CARGO="$(command -v cargo || true)"
[ -n "$CARGO" ] || [ ! -x "$HOME/.cargo/bin/cargo" ] || CARGO="$HOME/.cargo/bin/cargo"
[ -n "$CARGO" ] || { echo "SKIP: cargo is not on PATH and not in \$HOME/.cargo/bin"; exit 0; }

# --offline, and a target directory OUTSIDE the extracted tree. The gate runs this against a
# `git archive` of the branch, so a fresh target/ would recompile every dependency on every
# gate run; sharing one cache makes it seconds instead of a minute. --offline because a gate
# must not depend on the network being up.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/spira-panel-target}"
out="$("$CARGO" test --offline --manifest-path "$PANEL/Cargo.toml" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    # A dependency missing from the local registry is an environment fault, not the branch's.
    if grep -q 'no matching package\|failed to download\|registry.*not.*available\|--offline' <<< "$out"; then
        echo "SKIP: cargo cannot resolve dependencies offline"
        exit 0
    fi
    printf '%s\n' "$out" | tail -30
    echo "FAIL: panel tests"
    exit 1
fi
printf '%s\n' "$out" | grep -E '^test result:' || true
echo "PASS: panel tests"
exit 0
