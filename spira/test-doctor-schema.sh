#!/usr/bin/env bash
#
# test-doctor-schema.sh — doctor.sh fails when bd's migration count differs from the
# database cursor, and passes when they agree.
#
#   ./test-doctor-schema.sh
#
# WHAT THIS TESTS
# ---------------
# `bd migrate schema` without --ignore-schema-skew exits 0 on agreement and exits
# non-zero with the message "database is at vX, binary knows up to vY" on disagreement.
# doctor.sh's "bd schema" section uses that command to detect migration-count skew before
# the loop tries to run — the failure mode that stopped Spira for six minutes by showing
# 0 ready rather than a fault.
#
# Three properties are tested:
#
#   1. POSITIVE CONTROL. The fake bd that mimics a schema-mismatch error is itself
#      caught by the parser before the main assertions run. Without this a parser that
#      never fires would look identical to one that fires and passes.
#
#   2. MISMATCH CASE. When `bd migrate schema` exits non-zero with the standard
#      schema-mismatch message, doctor.sh exits non-zero AND names both version numbers
#      in its output. Naming both numbers is what makes the fault actionable — a failure
#      message that says "something is wrong" and no further is a second mystery.
#
#   3. MATCH CASE. When `bd migrate schema` exits 0 with "Schema already at vNN",
#      doctor.sh reports the schema section as passing.
#
# covers: spira/doctor.sh spira/bd-pin.sh spira/conf.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in output"; }
nowant(){ [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in output"; }

echo "test-doctor-schema.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# A minimal fake-bd factory. $1=exit-code, $2=output. Writes $TMP/bin/bd.
make_fake_bd() {
    local exit_code="$1" output="$2"
    mkdir -p "$TMP/bin"
    # The fake bd handles the three calls doctor.sh makes against the database:
    #   list --limit 1 --json   — the "bd can read it" check
    #   migrate schema          — the schema-version check (what we're testing)
    #   anything else           — exit 0 silently
    cat > "$TMP/bin/bd" <<FAKESCRIPT
#!/usr/bin/env bash
case "\$*" in
    *"migrate schema"*) printf '%s\n' "$output"; exit $exit_code ;;
    *"list"*"--limit"*) printf '[]\n'; exit 0 ;;
    *) exit 0 ;;
esac
FAKESCRIPT
    chmod +x "$TMP/bin/bd"
}

# Minimal harness layout expected by doctor.sh. SPIRA_REPO needs a git root for
# SPIRA_REPO_DERIVED; the fallback path ($SPIRA_HOME/..) is used when git fails, which
# is fine here. We set SPIRA_DB to a path that has a .beads dir so the db-present check
# passes. Everything else (repo-map, cockpit, status line) will warn — that is expected
# and the test only asserts on the schema lines.
setup_env() {
    mkdir -p "$TMP/db/.beads"
    mkdir -p "$TMP/run"
}

run_doctor() {
    local extra_env="${1:-}"
    # env -i strips the caller's environment. We restore HOME and a minimal PATH for
    # standard tools (git, python3, flock, timeout). conf.sh replaces PATH at the end
    # of its run using SPIRA_PATH, so fake bd placement is via SPIRA_PATH, not PATH.
    # SPIRA_CONF=/nonexistent forces conf.sh to use defaults rather than the live config.
    # SPIRA_REPO_MAP=/nonexistent makes the repo section warn but not abort.
    env -i \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        HOME="$TMP/home" \
        SPIRA_CONF=/nonexistent \
        SPIRA_PATH="$TMP/bin" \
        SPIRA_DB="$TMP/db" \
        SPIRA_RUN="$TMP/run" \
        SPIRA_BD_PIN="$TMP/run/bd-pin" \
        SPIRA_REPO_MAP=/nonexistent \
        SPIRA_NOTIFY=/nonexistent \
        ${extra_env} \
        bash "$HERE/doctor.sh" 2>/dev/null
}

setup_env

MISMATCH_MSG="schema version mismatch: database is at v61, binary knows up to v53 (8 migrations ahead)"

# ==========================================================================
echo
echo "positive control — fake bd that mimics mismatch output is detectable:"
# ==========================================================================
make_fake_bd 1 "$MISMATCH_MSG"
ctrl_out="$(run_doctor || true)"

# The parser must extract both numbers from the mismatch message.
want "positive control: 'v53' appears in doctor output" "v53" "$ctrl_out"
want "positive control: 'v61' appears in doctor output" "v61" "$ctrl_out"
want "positive control: FAIL line appears" "FAIL" "$ctrl_out"

# ==========================================================================
echo
echo "mismatch case — doctor.sh names both version numbers and exits non-zero:"
# ==========================================================================
# doctor.sh accumulates fatal counts and exits at the end. A schema-mismatch FAIL
# increments the fatal counter, so the run exits 1. We verify the exit code separately
# from the output by writing the output to a temp file and capturing exit code directly.
make_fake_bd 1 "$MISMATCH_MSG"
run_doctor > "$TMP/mismatch.out" 2>/dev/null && mismatch_rc=0 || mismatch_rc=$?
mismatch_out="$(cat "$TMP/mismatch.out")"

want "mismatch: FAIL line names bd count 'v53'"       "v53" "$mismatch_out"
want "mismatch: FAIL line names db cursor 'v61'"      "v61" "$mismatch_out"
want "mismatch: FAIL line mentions migration count"   "migration count" "$mismatch_out"
if [ "${mismatch_rc:-0}" -ne 0 ]; then
    ok "mismatch: doctor.sh exits non-zero (rc=$mismatch_rc)"
else
    bad "mismatch: doctor.sh exits non-zero" "exited 0"
fi

# ==========================================================================
echo
echo "match case — doctor.sh reports schema OK when bd and db agree:"
# ==========================================================================
make_fake_bd 0 "✓ Schema already at v61"
match_out="$(run_doctor || true)"

want  "match: ok line names the version" "v61" "$match_out"
want  "match: ok line mentions migration count" "migration count" "$match_out"
nowant "match: no FAIL for schema" "migration count" "$(printf '%s\n' "$match_out" | grep 'FAIL' || true)"

# ==========================================================================
echo
echo "pin file — doctor.sh reports pin presence and absence:"
# ==========================================================================
make_fake_bd 0 "✓ Schema already at v61"

# Absence: no pin file → warn line.
rm -f "$TMP/run/bd-pin"
no_pin_out="$(run_doctor || true)"
want "no pin: warn line appears" "no bd pin file" "$no_pin_out"

# Presence: pin file → ok line with pinned version.
printf 'BD_PIN_VERSION=1.1.0\nBD_PIN_MIGRATIONS=61\nBD_PIN_SHA256=abc\nBD_PIN_BUILD=CGO_ENABLED=0\nBD_PIN_MODE=server\n' \
    > "$TMP/run/bd-pin"
pin_out="$(run_doctor || true)"
want "pin: ok line names pinned version" "pinned v61" "$pin_out"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
