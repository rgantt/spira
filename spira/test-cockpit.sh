#!/usr/bin/env bash
#
# test-cockpit.sh — the snapshot has exactly one writer.
#
#   ./test-cockpit.sh
#
# THE FAILURE THIS SUITE EXISTS FOR. cockpit.sh writes the snapshot the health
# pane reads, and nothing else may: an aeon running the collector from its
# worktree, a retired brain collector calling a vendored copy, or a manual
# `cockpit.sh once` each overwrites the live snapshot with whatever keys its
# branch carries, and the pane reads `?` for every key the interloper lacked.
#
# The fence is INVOCATION_ID: systemd sets it for exactly one process tree per
# invocation, so the collector refuses to write unless its INVOCATION_ID matches
# spira-cockpit.service's — or SPIRA_COCKPIT_FORCE=1 names the override.
#
# covers: spira/cockpit.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RUN="$TMP/run"; mkdir -p "$RUN"
BASE_PATH="$PATH"

# A minimal environment: no INVOCATION_ID, no real config, no inherited state.
run_cockpit() {
    env -i PATH="$BASE_PATH" HOME="$TMP" LC_ALL=C.UTF-8 \
        SPIRA_CONF="$TMP/no.conf" SPIRA_HOME="$HERE" SPIRA_REPO="$TMP" \
        SPIRA_RUN="$RUN" SPIRA_DB="$TMP/nodb" \
        SPIRA_REPO_MAP="$TMP/no-map" SPIRA_GOAL=sp-test SPIRA_FAYTHS=t \
        "$@" \
        bash "$HERE/cockpit.sh" once 2>/dev/null
}

# ======================================================================================
echo "without INVOCATION_ID (unsupervised):"

out="$(run_cockpit)"
if [ ! -f "$RUN/cockpit.env" ]; then
    ok "snapshot is NOT written"
else
    bad "snapshot is NOT written" "file exists at $RUN/cockpit.env"
fi
want "keys are printed to stdout" "SP_AT=" "$out"
want "window key is present"      "SP_WINDOW_HOURS=" "$out"

# ======================================================================================
echo
echo "with SPIRA_COCKPIT_FORCE=1:"

rm -f "$RUN/cockpit.env"
run_cockpit env SPIRA_COCKPIT_FORCE=1 >/dev/null
if [ -f "$RUN/cockpit.env" ]; then
    ok "snapshot IS written"
else
    bad "snapshot IS written" "file does not exist"
fi
snap="$(cat "$RUN/cockpit.env" 2>/dev/null)"
want "SP_WRITER is set" "SP_WRITER=" "$snap"
want "SP_WRITER names 'force'" "force" "$snap"

# ======================================================================================
echo
echo "loop mode refuses without supervision:"

loop_out="$(env -i PATH="$BASE_PATH" HOME="$TMP" LC_ALL=C.UTF-8 \
    SPIRA_CONF="$TMP/no.conf" SPIRA_HOME="$HERE" SPIRA_REPO="$TMP" \
    SPIRA_RUN="$RUN" SPIRA_DB="$TMP/nodb" \
    SPIRA_REPO_MAP="$TMP/no-map" SPIRA_GOAL=sp-test SPIRA_FAYTHS=t \
    bash "$HERE/cockpit.sh" loop 2>&1)" || true
want "loop mode prints refusal" "not the supervised process" "$loop_out"

# ======================================================================================
echo
printf 'test-cockpit: %d ok, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
