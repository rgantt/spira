#!/usr/bin/env bash
#
# test-loom-ops.sh — shell-level tests for the /api/ops parser and the ? rule.
#
#   ./test-loom-ops.sh
#
# WHERE IT RUNS: the TIMED set, found by the `spira/test-*.sh` glob and run by `suites.sh`.
# Not in gate-suites — it exercises the parser through a running server, which takes a few
# seconds longer than a pure-unit check; the gate already covers the Rust unit tests via
# `cargo test --lib`.
#
# WHAT IS EXERCISED:
#   1. The KEY='VALUE' parser round-trip: values with embedded apostrophes are encoded as
#      `'\''` by the Python writer in cockpit.sh; this suite writes the same encoding to a
#      temp file, starts the server, hits /api/ops, and verifies the value decoded correctly.
#   2. The ? rule: a key absent from cockpit.env must be absent from the JSON — the renderer
#      must receive null/undefined, not a default 0 or empty string.
#   3. POSITIVE CONTROLS everywhere: every absence assertion is paired with one showing the
#      check can detect a present value, so silence cannot pass for an untested check.
#
# WHAT IS NOT EXERCISED HERE: Rust unit tests in ops.rs already cover parse_shell_value()
# directly. This suite drives the live HTTP endpoint so the JSON serialisation path,
# the 5-second cache, and the full env-file read path are also covered.
#
# defect: sp-yv7j
# covers: loom/src/ops.rs loom/src/lib.rs
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOOM_ROOT="$HERE/../loom"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# Locate a cargo binary — same logic as test-loom.sh so the two stay in sync.
CARGO_BIN="$(command -v cargo 2>/dev/null || true)"
if [ -z "$CARGO_BIN" ] && [ -x "$HOME/.cargo/bin/cargo" ]; then
    CARGO_BIN="$HOME/.cargo/bin/cargo"
fi
if [ -z "$CARGO_BIN" ]; then
    echo "SKIP test-loom-ops: cargo not found" >&2
    exit 77
fi

# Locate the loom binary. Prefer the release build; fall back to the debug build; skip if
# neither exists. We do not build here — a failing binary means the timed run files a bead.
LOOM_BIN=""
for candidate in \
    "$LOOM_ROOT/target/release/loom" \
    "$LOOM_ROOT/target/debug/loom"; do
    if [ -x "$candidate" ]; then LOOM_BIN="$candidate"; break; fi
done
if [ -z "$LOOM_BIN" ]; then
    echo "SKIP test-loom-ops: no loom binary found — run 'cargo build' in loom/" >&2
    exit 77
fi

# curl is our HTTP client. If it is absent, skip.
if ! command -v curl >/dev/null 2>&1; then
    echo "SKIP test-loom-ops: curl not found" >&2
    exit 77
fi

TMP="$(mktemp -d)"
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

# Write a cockpit.env in the KEY='VALUE' shell-encoded format. Two interesting values:
#   SP_PLAIN  — a value with no apostrophes.
#   SP_APOS   — a value containing two apostrophes, encoded as ''\'''' (10 chars) each time.
#   SP_AT     — required by the header section; absent key would render as ?.
#
# The Python encoder in cockpit.sh writes:  '\'' + v.replace("'", "'\\''") + '\''
# For "it's": 'it'\''s' (7 encoded chars → 4 decoded chars).
# For "''"   : ''\''''\''' (10 encoded chars → 2 decoded chars).
COCKPIT_ENV="$TMP/cockpit.env"
cat >"$COCKPIT_ENV" <<'EOF'
SP_PLAIN='hello world'
SP_APOS=''\'''\'''
SP_AT='1000000000'
SP_MISSING_CONTROL='present'
EOF
# SP_MISSING is intentionally absent — the ? rule asserts it does not appear.

# Write a minimal budget.env — empty is fine; the parser must handle it.
BUDGET_ENV="$TMP/budget.env"
: >"$BUDGET_ENV"

# Start the loom server with our temp run directory.
# SPIRA_DB must be non-empty for loom to start; point at the budget.env's dir as a sentinel.
export SPIRA_DB="$TMP"
export SPIRA_RUN="$TMP"
export SPIRA_INSTANCE="test"
# Bind to an ephemeral port so concurrent test runs never collide.
export SPIRA_LOOM_ADDR="127.0.0.1:0"

# Start server and capture its address from stderr.
ADDR_FILE="$TMP/addr"
"$LOOM_BIN" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
# The server prints its bound address on startup. Poll up to 5 s.
ADDR=""
for _ in 1 2 3 4 5; do
    sleep 1
    ADDR="$(grep -o '127\.0\.0\.1:[0-9]*' "$TMP/server.log" 2>/dev/null | head -1)"
    [ -n "$ADDR" ] && break
done
if [ -z "$ADDR" ]; then
    bad "server did not start" "$(cat "$TMP/server.log" 2>/dev/null | tail -5)"
    printf '\n  %d ok, %d failed\n' "$pass" "$fail"; exit 1
fi
ok "server started at $ADDR"

# Fetch /api/ops. The 5-second cache means this is always a fresh read.
OPS_JSON="$(curl -sS --fail "http://$ADDR/api/ops" 2>"$TMP/curl.err")" || {
    bad "/api/ops request failed" "$(cat "$TMP/curl.err")"
    printf '\n  %d ok, %d failed\n' "$pass" "$fail"; exit 1
}
ok "/api/ops returned JSON"

# PARSER: SP_PLAIN must round-trip correctly.
PLAIN="$(printf '%s' "$OPS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("SP_PLAIN","ABSENT"))' 2>/dev/null)"
if [ "$PLAIN" = "hello world" ]; then
    ok "SP_PLAIN round-trips through parser"
else
    bad "SP_PLAIN round-trip" "got: $PLAIN"
fi

# PARSER: SP_APOS must decode two apostrophes. The Python value is "''".
APOS="$(printf '%s' "$OPS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(repr(d.get("SP_APOS","ABSENT")))' 2>/dev/null)"
if [ "$APOS" = "\"''\"" ]; then
    ok "SP_APOS (two apostrophes) round-trips through parser"
else
    bad "SP_APOS round-trip" "got repr: $APOS"
fi

# ? RULE: SP_MISSING must be absent from the JSON (not a default 0 or empty string).
# POSITIVE CONTROL: SP_MISSING_CONTROL IS present — verify the key lookup works at all.
CTRL="$(printf '%s' "$OPS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("SP_MISSING_CONTROL","ABSENT"))' 2>/dev/null)"
if [ "$CTRL" = "present" ]; then
    ok "positive control: SP_MISSING_CONTROL is present (parser ran)"
else
    bad "positive control: SP_MISSING_CONTROL not found" "got: $CTRL"
fi

MISSING="$(printf '%s' "$OPS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("absent" if "SP_MISSING" not in d else d["SP_MISSING"])' 2>/dev/null)"
if [ "$MISSING" = "absent" ]; then
    ok "? rule: SP_MISSING is absent from JSON (not defaulted to 0 or empty)"
else
    bad "? rule: SP_MISSING appears in JSON" "value: $MISSING"
fi

# FILE HEALTH: cockpit_env_age_s must be present and numeric.
AGE="$(printf '%s' "$OPS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("cockpit_env_age_s"); print(type(a).__name__,a)' 2>/dev/null)"
case "$AGE" in
    int*|float*) ok "cockpit_env_age_s is numeric: $AGE" ;;
    *)           bad "cockpit_env_age_s is not numeric" "got: $AGE" ;;
esac

# HALT/DRAIN: no stamp files in TMP, so halted must be false.
HALTED="$(printf '%s' "$OPS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("halted","ABSENT"))' 2>/dev/null)"
if [ "$HALTED" = "False" ] || [ "$HALTED" = "false" ]; then
    ok "halted is false when no world.halted stamp is present"
else
    bad "halted flag unexpected" "got: $HALTED"
fi

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
