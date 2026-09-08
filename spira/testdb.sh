# testdb.sh — a REAL `bd` on an embedded (no-server) Dolt database. Sourced by a suite,
# never executed.
#
#   . "$HERE/testdb.sh"
#   testdb_require fayth          # skips the suite, loudly, if bd lacks embedded support
#   testdb_up fayth               # creates the database, exports SPIRA_DB
#   trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
#   testdb_seed <<'JSONL' ... JSONL
#   testdb_reset                  # back to empty, in ~6ms
#
# WHY NOT A STUB. `.claude/spira/testbin/bd` modelled 16 of bd's 118 subcommands, and its
# fidelity was wrong twice in one day in ways that made CALLERS look broken: `list` ignored
# --label entirely, so the CI sweep ran against every fixture bead and the suite failed on
# code that was correct; and a dead duplicate `ready` handler meant two implementations of
# one query disagreed. A partial model of a dependency drifts silently, and every hour spent
# restoring its fidelity reimplements something that already exists and is correct by
# definition (law-prefer-the-real-dependency).
#
# WHY EMBEDDED, NOT A SHARED SERVER. testdb_up against a shared Dolt server cost 84s solo
# and 610s for six concurrent builds (5 of 6 failing), because schema migrations hold a global
# lock and leaked fixtures from SIGKILL'd suites compounded through an age-based sweep that
# ran concurrently against the same server. With the embedded engine each fixture is a
# directory, cleanup is rm -rf, and six concurrent builds complete in ~25s with 0 failures.
# The route through --proxied-server was tested and rejected: 'bd import' fails in that mode,
# and import is how all 15 fixture-using suites seed their data.
#
# REQUIRES A CGO-ENABLED bd BUILD. The standard binary is built CGO_ENABLED=0 and refuses
# embedded mode. Install: npm install -g @beads/bd (or the project's install.sh). The old
# binary is at ~/.local/bin/bd.cgo0-backup for rollback.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"

TESTDB_BD="${TESTDB_BD:-bd}"
# Preserved if already set, so a caller that built a shared fixture and exported it is not
# erased by the act of sourcing this file.
TESTDB_NAME="${TESTDB_NAME:-}"
TESTDB_DIR="${TESTDB_DIR:-}"
TESTDB_BASELINE="${TESTDB_BASELINE:-}"

testdb_available() {     # 0 if the embedded engine is usable on this box
    command -v "$TESTDB_BD" >/dev/null 2>&1 || return 1
    # Fast path: if a shared fixture was already built this session, embedded is confirmed.
    [ "${TESTDB_SHARED:-0}" = 1 ] && [ -d "${TESTDB_DIR:-}" ] && return 0
    # Cold check: attempt an init. Detects CGO_ENABLED=0 builds, which refuse embedded.
    local tmp; tmp="$(mktemp -d)"
    ( cd "$tmp" && env -i PATH="$PATH" HOME="$HOME" TERM=dumb BD_NON_INTERACTIVE=1 \
        "$TESTDB_BD" init --non-interactive --prefix sp --skip-agents --skip-hooks -q 2>/dev/null )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

# A SUITE THAT CANNOT RUN MUST NOT READ AS A SUITE THAT PASSED. 77 is the automake skip
# convention; gate-brain.sh knows it and names the skipped suite in the gate's own output,
# because the gate discards suite stdout and a silent skip there is indistinguishable from
# a pass (law-alerts-must-be-actionable).
testdb_require() {       # testdb_require <suite-name>
    testdb_available && return 0
    printf 'SKIP %s: no embedded-capable bd — these suites need a CGO-enabled build.\n' \
        "$1" >&2
    printf '  install: npm install -g @beads/bd\n' >&2
    printf '  rollback: cp ~/.local/bin/bd.cgo0-backup ~/.local/bin/bd\n' >&2
    exit 77
}

# testdb_up <tag> — a fixture workspace with an embedded Dolt database. Exports SPIRA_DB,
# which is the only thing lib.sh's `bdq` needs, and leaves SPIRA_BD unset so the REAL binary
# is what runs.
#
# `--prefix sp` with no --server: the issue prefix is production's, so ids read `sp-a3f`
# exactly as they do live, while the database is a private directory with no server traffic.
#
# A FIXTURE MAY BE INHERITED. `bd init` costs ~6s (schema DDL applied to the embedded store)
# and the gate ran suites that each built the same thing. When a caller has already built one
# and exported TESTDB_SHARED=1, reset to its baseline instead: ~6ms, and the isolation is
# identical, because the reset is a directory swap.
testdb_up() {            # testdb_up <tag>
    local tag="$1"
    if [ "${TESTDB_SHARED:-0}" = 1 ] && [ -n "${TESTDB_NAME:-}" ] && [ -n "${TESTDB_BASELINE:-}" ]; then
        testdb_reset || { printf 'testdb: could not reset shared fixture %s\n' "$TESTDB_NAME" >&2; return 1; }
        export SPIRA_DB="$TESTDB_DIR"; unset SPIRA_BD
        return 0
    fi

    TESTDB_NAME="sptest_${tag}_$(date +%s)_$$"
    TESTDB_DIR="$(mktemp -d)"
    # env -i is deliberate. A gate, a check or a test invoked by automation runs in an
    # explicit minimal environment, never the caller's: BEADS_ACTOR and friends leak into
    # `created_by` and `owner`, and ambient configuration silently deciding a verdict is
    # exactly law-gates-run-in-a-clean-environment.
    # THE FAILURE MUST CARRY ITS REASON. Errors go to stderr, where a gate capturing output
    # can still see them.
    local init_out init_rc
    init_out="$( cd "$TESTDB_DIR" && env -i PATH="$PATH" HOME="$HOME" TERM=dumb BD_NON_INTERACTIVE=1 \
        "$TESTDB_BD" init --non-interactive --prefix sp --skip-agents --skip-hooks -q 2>&1 )"
    init_rc=$?
    [ $init_rc -eq 0 ] || {
        printf 'testdb: bd init failed (rc=%s) for %s in %s\n' \
            "$init_rc" "$TESTDB_NAME" "$TESTDB_DIR" >&2
        printf '%s\n' "$init_out" | sed 's/^/testdb:   /' >&2
        rm -rf "$TESTDB_DIR"; TESTDB_DIR=""; TESTDB_NAME=""; return 1; }

    # THE BASELINE IS A SNAPSHOT OF .beads AT INIT TIME. Reset replaces .beads with this
    # copy, so every reset is identical to a fresh init without paying the 6s cost again.
    # A separate directory keeps it safe from rm -rf on TESTDB_DIR during reset.
    TESTDB_BASELINE="$(mktemp -d)"
    cp -rp "$TESTDB_DIR/.beads" "$TESTDB_BASELINE/.beads"
    [ -d "$TESTDB_BASELINE/.beads" ] || {
        printf 'testdb: baseline snapshot failed for %s\n' "$TESTDB_NAME" >&2
        rm -rf "$TESTDB_DIR" "$TESTDB_BASELINE"; TESTDB_DIR=""; TESTDB_BASELINE=""; TESTDB_NAME=""; return 1; }

    export SPIRA_DB="$TESTDB_DIR"
    unset SPIRA_BD
    return 0
}

# Back to an empty database. A directory swap rather than a table wipe: bd writes across
# multiple tables (issues, labels, dependencies, leases, events, views) and a wipe that
# misses one leaves state no test asked for. The swap is 6ms and is guaranteed complete.
testdb_reset() {
    [ -n "$TESTDB_NAME" ] || return 1
    [ -d "$TESTDB_BASELINE/.beads" ] || return 1
    rm -rf "$TESTDB_DIR/.beads"
    cp -rp "$TESTDB_BASELINE/.beads" "$TESTDB_DIR/.beads"
}

testdb_seed() {          # testdb_seed  < JSONL on stdin
    local f; f="$(mktemp)"
    cat > "$f"
    "$TESTDB_BD" -C "$SPIRA_DB" import "$f" >/dev/null 2>&1
    local rc=$?
    rm -f "$f"
    return $rc
}

# THE BORROWER DOES NOT DROP. Suites trap testdb_drop on EXIT; with a shared fixture the
# first suite to finish would delete the directories the rest are still using. Only the
# process that created it owns it, and it drops by clearing TESTDB_SHARED first (as
# aeon.sh's fixture_drop does: TESTDB_SHARED=0 before sourcing and calling testdb_drop).
testdb_drop() {
    [ "${TESTDB_SHARED:-0}" = 1 ] && return 0
    [ -n "${TESTDB_NAME:-}" ] || return 0
    rm -rf "${TESTDB_DIR:-}" "${TESTDB_BASELINE:-}"
    TESTDB_NAME=""; TESTDB_DIR=""; TESTDB_BASELINE=""
    return 0
}
