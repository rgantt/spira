#!/usr/bin/env bash
#
# loom.sh — source the harness configuration, then start the Loom server.
#
# Systemd execs this so the binary reads its configuration from environment variables that
# conf.sh sets: SPIRA_DB, SPIRA_LOOM_ADDR, SPIRA_PATH and friends. A unit with a hardcoded
# SPIRA_DB works on exactly one box; a wrapper that sources conf.sh works on any.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"

if [ ! -x "${SPIRA_LOOM_BIN:-}" ]; then
    printf 'loom: binary not found at %s\n' "${SPIRA_LOOM_BIN:-<unset>}" >&2
    printf 'loom: build it: cd %s/loom && cargo build --release\n' "$SPIRA_REPO" >&2
    exit 2
fi

exec "$SPIRA_LOOM_BIN" "$@"
