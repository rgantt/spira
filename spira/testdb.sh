# testdb.sh — a REAL `bd` on a throwaway Dolt database. Sourced by a suite, never executed.
#
#   . "$HERE/testdb.sh"
#   testdb_require fayth          # skips the suite, loudly, if the server is down
#   testdb_up fayth               # creates the database, exports SPIRA_DB
#   trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
#   testdb_seed <<'JSONL' ... JSONL
#   testdb_reset                  # back to empty, in ~0.3s
#
# WHY NOT A STUB. `.claude/spira/testbin/bd` modelled 16 of bd's 118 subcommands, and its
# fidelity was wrong twice in one day in ways that made CALLERS look broken: `list` ignored
# --label entirely, so the CI sweep ran against every fixture bead and the suite failed on
# code that was correct; and a dead duplicate `ready` handler meant two implementations of
# one query disagreed. A partial model of a dependency drifts silently, and every hour spent
# restoring its fidelity reimplements something that already exists and is correct by
# definition (law-prefer-the-real-dependency).
#
# THE COST IS AFFORDABLE AND WAS MEASURED. `bd init` against the running server is ~18s once
# per suite, because it applies 61 schema migrations and commits each; `bd import` of a
# handful of rows is ~0.5s; the wipe between cases is a single `dolt_reset --hard` to a
# baseline commit at ~0.3s. The four suites that use this cost 19s, 24s, 25s and 52s, well
# inside the gate's 300s per-suite timeout — and cheaper than one wrong verdict from a
# drifting stub.
#
# THE DATABASE NAME IS THE SAFETY BOUNDARY. The seven live Gas Town databases and Spira's
# own share this server, so every fixture is `sptest_<tag>_<epoch>_<pid>` and `testdb_drop`
# refuses any name that does not match. The name also carries its own age, which is how a
# run killed with SIGKILL — where no trap fires — still gets collected: `testdb_up` sweeps
# fixtures older than two hours before it makes its own.

# `bd` and `dolt` live wherever the operator put them, and a suite is run from the landing
# gate and from cron as often as from a terminal. conf.sh exports the configured PATH for
# the same reason lib.sh sources it — the difference between a fixture that builds and a
# suite that skips itself with "no Dolt server" on a box where the server is running.
#
# Only conf.sh, not lib.sh: a fixture library must not drag in the whole harness, and the
# suites that use it set SPIRA_DB to a throwaway database of their own.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"

# The server is Spira's own. Reading its coordinates rather than hardcoding them means a
# port change moves the fixtures with it.
# `.beads/dolt-server.port` first, because that is the file `bd` itself honours — it wins
# over metadata.json, so reading metadata alone would connect the fixtures somewhere bd would
# not.
TESTDB_HOST="${TESTDB_HOST:-127.0.0.1}"
TESTDB_PORT="${TESTDB_PORT:-$(python3 -c '
import json, sys
db = sys.argv[1]
for f, get in ((db + "/.beads/dolt-server.port", lambda h: int(h.read().strip())),
               (db + "/.beads/metadata.json", lambda h: json.load(h)["dolt_server_port"])):
    try:
        print(get(open(f))); break
    except Exception:
        continue
else:
    print(3307)' "$SPIRA_DB" 2>/dev/null)}"
[ -n "$TESTDB_PORT" ] || TESTDB_PORT=3307
TESTDB_BD="${TESTDB_BD:-bd}"
TESTDB_NAME=""
TESTDB_DIR=""

# A wire query against the server, as the CLI. `--password ''` is not optional: without it
# dolt prompts, and a prompt with no tty fails as "inappropriate ioctl for device" — which
# reads like a broken server rather than a missing flag.
testdb_sql() {           # testdb_sql <db> <query> -> csv on stdout
    dolt --host "$TESTDB_HOST" --port "$TESTDB_PORT" --user root --password '' --no-tls \
         ${1:+--use-db "$1"} sql -r csv -q "$2" 2>/dev/null
}

testdb_available() {     # 0 if the fixture server can be reached at all
    command -v dolt >/dev/null 2>&1 || return 1
    command -v "$TESTDB_BD" >/dev/null 2>&1 || return 1
    testdb_sql "" "select 1" >/dev/null 2>&1
}

# A SUITE THAT CANNOT RUN MUST NOT READ AS A SUITE THAT PASSED. 77 is the automake skip
# convention; gate-brain.sh knows it and names the skipped suite in the gate's own output,
# because the gate discards suite stdout and a silent skip there is indistinguishable from
# a pass (law-alerts-must-be-actionable).
testdb_require() {       # testdb_require <suite-name>
    testdb_available && return 0
    printf 'SKIP %s: no Dolt server at %s:%s — these suites run against a real bd.\n' \
        "$1" "$TESTDB_HOST" "$TESTDB_PORT" >&2
    printf '  start it with: bd -C %s dolt start\n' "$SPIRA_DB" >&2
    exit 77
}

# Fixtures whose own name says they are older than two hours. A trap cannot fire on
# SIGKILL, so without this a hard-killed suite leaves a database behind on the server that
# also holds Spira's live data — and litter there is never noticed until it is a problem.
testdb_sweep() {
    local now db epoch
    now="$(date +%s)"
    while IFS= read -r db; do
        case "$db" in sptest_*) ;; *) continue ;; esac
        epoch="$(printf '%s' "$db" | awk -F_ '{print $(NF-1)}')"
        case "$epoch" in ''|*[!0-9]*) continue ;; esac
        [ $(( now - epoch )) -gt 7200 ] || continue
        testdb_sql "" "drop database \`$db\`" >/dev/null 2>&1
    done < <(testdb_sql "" "show databases" | tail -n +2)
    return 0
}

# testdb_up <tag> — a fixture database and a bd workspace pointing at it. Exports SPIRA_DB,
# which is the only thing lib.sh's `bdq` needs, and leaves SPIRA_BD unset so the REAL binary
# is what runs.
#
# `--prefix sp` with an explicit `--database`: the issue prefix is production's, so ids read
# `sp-a3f` exactly as they do live, while the database name stays unique per run. Passing
# only a prefix would name the database after it and collide between concurrent runs.
testdb_up() {            # testdb_up <tag>
    local tag="$1"
    testdb_sweep
    TESTDB_NAME="sptest_${tag}_$(date +%s)_$$"
    TESTDB_DIR="$(mktemp -d)"
    testdb_sql "" "create database \`$TESTDB_NAME\`" >/dev/null 2>&1
    # env -i is deliberate. A gate, a check or a test invoked by automation runs in an
    # explicit minimal environment, never the caller's: BEADS_ACTOR and friends leak into
    # `created_by` and `owner`, and ambient configuration silently deciding a verdict is
    # exactly law-gates-run-in-a-clean-environment.
    ( cd "$TESTDB_DIR" && env -i PATH="$PATH" HOME="$HOME" TERM=dumb BD_NON_INTERACTIVE=1 \
        "$TESTDB_BD" init --server --server-host "$TESTDB_HOST" --server-port "$TESTDB_PORT" \
            --external --database "$TESTDB_NAME" --prefix sp \
            --non-interactive --skip-agents --skip-hooks -q ) >/dev/null 2>&1 || {
        printf 'testdb: bd init failed for %s\n' "$TESTDB_NAME" >&2
        testdb_drop; return 1; }
    git -C "$TESTDB_DIR" config beads.role maintainer 2>/dev/null

    # THE BASELINE IS COMMITTED HERE, not inherited. `bd init` leaves the `config` table
    # modified and UNCOMMITTED, so resetting to bd's own "bd init" commit throws away
    # issue_prefix and every later command fails with "database not initialized" — a wipe
    # that breaks the database it was meant to clean.
    testdb_sql "$TESTDB_NAME" "call dolt_commit('-A','-m','testdb baseline','--skip-empty')" >/dev/null 2>&1
    TESTDB_BASELINE="$(testdb_sql "$TESTDB_NAME" "select hashof('HEAD')" | tail -1)"
    [ -n "$TESTDB_BASELINE" ] || { printf 'testdb: no baseline commit for %s\n' "$TESTDB_NAME" >&2
                                   testdb_drop; return 1; }
    export SPIRA_DB="$TESTDB_DIR"
    unset SPIRA_BD
    return 0
}

# Back to an empty database. A dolt reset rather than a DELETE sweep: bd writes across a
# dozen tables — issues, labels, dependencies, leases, events, the cached ready_issues and
# blocked_issues views — and a wipe that misses one leaves state no test asked for.
testdb_reset() {
    [ -n "$TESTDB_NAME" ] || return 1
    testdb_sql "$TESTDB_NAME" \
        "call dolt_reset('--hard','$TESTDB_BASELINE'); call dolt_clean();" >/dev/null 2>&1
}

testdb_seed() {          # testdb_seed  < JSONL on stdin
    local f; f="$(mktemp)"
    cat > "$f"
    "$TESTDB_BD" -C "$SPIRA_DB" import "$f" >/dev/null 2>&1
    local rc=$?
    rm -f "$f"
    return $rc
}

# A workspace whose server is genuinely not there — the one thing a real bd cannot be asked
# to do on demand, and the case the write-ahead spool exists for. `.beads/dolt-server.port`
# wins over metadata.json, so both are moved or bd cheerfully connects to the live server.
testdb_unreachable() {   # testdb_unreachable -> prints a workspace path
    local d; d="$(mktemp -d)"
    cp -r "$TESTDB_DIR/.beads" "$d/"
    python3 - "$d" <<'PY'
import json, sys, os
p = os.path.join(sys.argv[1], ".beads", "metadata.json")
d = json.load(open(p)); d["dolt_server_port"] = 3399
json.dump(d, open(p, "w"), indent=2)
PY
    echo 3399 > "$d/.beads/dolt-server.port"
    printf '%s' "$d"
}

# REFUSES ANY NAME THAT IS NOT A FIXTURE. This drops a database on the server that also
# holds Spira's live data and seven Gas Town rigs; a typo here is not recoverable, so the
# pattern is checked rather than trusted.
testdb_drop() {
    [ -n "${TESTDB_NAME:-}" ] || return 0
    case "$TESTDB_NAME" in
        sptest_*) testdb_sql "" "drop database \`$TESTDB_NAME\`" >/dev/null 2>&1 ;;
        *) printf 'testdb: refusing to drop %s — not a fixture database\n' "$TESTDB_NAME" >&2 ;;
    esac
    [ -n "${TESTDB_DIR:-}" ] && rm -rf "$TESTDB_DIR"
    TESTDB_NAME=""; TESTDB_DIR=""
    return 0
}
