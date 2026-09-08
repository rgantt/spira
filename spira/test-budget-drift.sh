#!/usr/bin/env bash
#
# test-budget-drift.sh — a unit's injected MAXSEC matches its TimeoutStartSec, and the
# conf.sh default budget does not exceed it.
#
#   ./test-budget-drift.sh
#
# WHAT THIS CATCHES. A service may use an internal budget key (e.g. SPIRA_SUITES_BUDGET) to
# stop accepting new work before its systemd timeout fires. When the two are set independently
# — one in spira.conf, one in the unit — they can drift apart: the pass budgets itself for
# 1800 s, systemd kills at 900 s, every run ends in SIGTERM (sp-o060, sp-cbjh).
#
# THE FIX IN CODE: the unit injects its TimeoutStartSec as SPIRA_*_MAXSEC, and the script
# caps its budget at MAXSEC - reserve. A configured override then cannot outrun the kill.
#
# THIS TEST IS THE RUNG-4 MECHANISM. Changing TimeoutStartSec without updating the
# Environment= line, or changing the Environment= line without updating TimeoutStartSec,
# fails here rather than failing every service pass silently for weeks.
#
# ADDING A NEW PAIR. When you add a unit with an internal budget that the unit should cap,
# add a line to PAIRS. Format: "unit_file|budget_key|maxsec_key|timeout_directive".
#   unit_file        — basename under systemd/, e.g. spira-foo.service
#   budget_key       — conf.sh key for the budget, e.g. SPIRA_FOO_BUDGET
#   maxsec_key       — the env var the unit injects, e.g. SPIRA_FOO_MAXSEC
#   timeout_directive — TimeoutStartSec or RuntimeMaxSec, as it appears in the unit file
#
# THE POSITIVE CONTROL IS FIRST (law-absence-needs-a-positive-control). A parser that always
# returns "" would pass every mismatch check; the first assertion proves it actually found
# something before any absence check is trusted.
#
# defect: sp-o060
# covers: systemd/spira-suites.service spira/suites.sh spira/conf.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
UNIT_DIR="$HERE/../systemd"
CONF="$HERE/conf.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "${2:-}"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }

echo "test-budget-drift.sh"

# Each entry: "unit_file|budget_key|maxsec_key|timeout_directive"
PAIRS=(
    "spira-suites.service|SPIRA_SUITES_BUDGET|SPIRA_SUITES_MAXSEC|TimeoutStartSec"
)

# parse_unit_directive <file> <directive> -> the value after "<directive>=", or ""
parse_unit_directive() {
    local f="$1" key="$2"
    grep -m1 "^${key}=" "$f" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]'
}

# parse_unit_env <file> <env_key> -> the value in Environment=KEY=VALUE, or ""
parse_unit_env() {
    local f="$1" key="$2"
    grep -m1 "^Environment=${key}=" "$f" 2>/dev/null | sed "s/^Environment=${key}=//" | tr -d '[:space:]'
}

# parse_conf_default <key> -> the default value from `: "${KEY:=<value>}"`, or ""
parse_conf_default() {
    local key="$1"
    # Matches: : "${KEY:=VALUE}" — strips quotes, braces, and the key prefix.
    grep -m1 ": \"\${${key}:=" "$CONF" 2>/dev/null \
        | sed "s/.*\${${key}:=//; s/}\".*//; s/[[:space:]]*$//"
}

for pair in "${PAIRS[@]}"; do
    IFS='|' read -r unit budget_key maxsec_key timeout_dir <<< "$pair"
    unit_file="$UNIT_DIR/$unit"

    echo
    echo "  $unit"

    if [ ! -r "$unit_file" ]; then
        bad "$unit is readable" "file not found: $unit_file"
        continue
    fi

    # -----------------------------------------------------------------------
    # POSITIVE CONTROL: the timeout directive is present and parseable.
    # Without this, every absence check below would pass on a broken parser.
    # -----------------------------------------------------------------------
    timeout_val="$(parse_unit_directive "$unit_file" "$timeout_dir")"
    if [ -z "$timeout_val" ]; then
        bad "$unit has $timeout_dir" "directive not found in $unit_file"
        continue
    fi
    ok "$unit has $timeout_dir=$timeout_val"

    # -----------------------------------------------------------------------
    # The injected env var must equal the timeout directive.
    # -----------------------------------------------------------------------
    maxsec_val="$(parse_unit_env "$unit_file" "$maxsec_key")"
    is "$maxsec_key is injected and matches $timeout_dir" "$timeout_val" "$maxsec_val"

    # -----------------------------------------------------------------------
    # The conf.sh default budget must not exceed the timeout.
    # (The code caps at runtime, but an out-of-range default is still wrong.)
    # -----------------------------------------------------------------------
    budget_default="$(parse_conf_default "$budget_key")"
    if [ -z "$budget_default" ]; then
        bad "$budget_key default is readable from conf.sh" "not found"
    elif ! [[ "$budget_default" =~ ^[0-9]+$ ]]; then
        bad "$budget_key default is numeric" "got [$budget_default]"
    elif [ "$budget_default" -ge "$timeout_val" ]; then
        bad "$budget_key default ($budget_default) is under $timeout_dir ($timeout_val)" \
            "default exceeds or equals the kill timeout — lower the default or raise the timeout"
    else
        ok "$budget_key default ($budget_default) is under $timeout_dir ($timeout_val)"
    fi
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
