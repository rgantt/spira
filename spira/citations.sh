#!/usr/bin/env bash
#
# citations.sh — list uncited suites and resolve citations to their defects.
#
#   citations.sh list             every spira/test-*.sh with its citation and resolve status
#   citations.sh resolve <suite>  show the defect a suite's citation names
#
# WHY THIS EXISTS. A test that has never gone red since it was written is either protecting
# something expensive or is dead weight, and nothing about the test says which. The citation
# is what makes retirement decidable. Without it, a suite only ever grows — which is how the
# old landing gate reached 13,098 lines and had to be deleted wholesale because there was no
# mechanism to delete it piecewise.
#
# THE CONVENTION. A suite declares the defect it exists for on a line of the form:
#
#   # defect: <bead-id>
#
# placed near its `# covers:` line, before `set -uo pipefail`. The bead must be findable
# in the Spira database; a closed bead is the expected state. Omitting the line is honest
# and this report surfaces it; inventing one is worse than none because it makes an
# undecidable retirement look decidable.
#
# THREE STATES, DISTINGUISHED:
#
#   uncited      no `# defect:` line — retirement is undecidable without more research
#   resolved     the bead is found in the database; its status is shown
#   unresolved   the declaration is present but the bead is not found — a mistype, wrong
#                database, or a defect that predates Spira; worth investigating, and not the
#                same as uncited (the response to each is different)
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib.sh"

SUITES_DIR="${CITATIONS_DIR:-$HERE}"

defect_of() { sed -n 's/^# *defect: *//p' "$SUITES_DIR/$1" 2>/dev/null | head -1 | tr -d '[:space:]'; }

cmd_list() {
    local s defect ids id_map st label
    ids=""
    id_map=""

    # First pass: collect all unique cited ids for a single batch lookup. A unique set avoids
    # querying the same bead multiple times when two suites cite it.
    for s in "$SUITES_DIR"/test-*.sh; do
        [ -f "$s" ] || continue
        defect="$(sed -n 's/^# *defect: *//p' "$s" 2>/dev/null | head -1 | tr -d '[:space:]')"
        [ -n "$defect" ] && ids="$ids $defect"
    done
    # Deduplicate: sort -u on whitespace-delimited words. Unquoted is intentional — we want
    # word splitting on the ids string, which contains no special characters.
    # shellcheck disable=SC2086
    ids="$(printf '%s\n' $ids | sort -u | tr '\n' ' ')"

    # Batch-query bd for all cited ids at once. bdjson show accepts multiple ids and returns a
    # JSON array; missing ids are silently absent from the result rather than an error.
    # Empty ids means nothing is cited, and we skip the query entirely.
    if [ -n "${ids// /}" ]; then
        # shellcheck disable=SC2086
        id_map="$(bdjson show $ids 2>/dev/null | python3 -c '
import sys, json
try:
    rows = json.load(sys.stdin)
    if isinstance(rows, dict): rows = [rows]
    for r in rows:
        bid = r.get("id", ""); st = r.get("status", "?")
        if bid: print(bid + "=" + st)
except Exception:
    pass
' 2>/dev/null || true)"
    fi

    printf '%-30s %-22s %s\n' SUITE DEFECT STATUS
    for s in "$SUITES_DIR"/test-*.sh; do
        [ -f "$s" ] || continue
        defect="$(sed -n 's/^# *defect: *//p' "$s" 2>/dev/null | head -1 | tr -d '[:space:]')"
        s="$(basename "$s")"
        if [ -z "$defect" ]; then
            label="uncited"
        else
            st="$(printf '%s\n' "$id_map" | grep "^${defect}=" | cut -d= -f2- | head -1)"
            if [ -n "$st" ]; then
                label="resolved ($st)"
            else
                label="unresolved"
            fi
        fi
        printf '%-30s %-22s %s\n' "$s" "${defect:--}" "$label"
    done
}

cmd_resolve() {
    local suite="$1" defect info st
    [ -f "$SUITES_DIR/$suite" ] || { printf 'citations: %s: no such suite\n' "$suite" >&2; return 2; }
    defect="$(defect_of "$suite")"
    if [ -z "$defect" ]; then
        printf '%s: uncited\n' "$suite"
        return 1
    fi
    printf '%s: citation %s\n' "$suite" "$defect"
    info="$(bdjson show "$defect" 2>/dev/null | python3 -c '
import sys, json
try:
    rows = json.load(sys.stdin)
    if isinstance(rows, dict): rows = [rows]
    r = rows[0] if rows else {}
    bid = r.get("id", "")
    if not bid:
        sys.exit(1)
    print("  id:     " + bid)
    print("  title:  " + r.get("title", "?"))
    print("  status: " + r.get("status", "?"))
    print("  type:   " + r.get("issue_type", "?"))
except Exception:
    sys.exit(1)
' 2>/dev/null)"
    if [ -z "$info" ]; then
        printf 'citation %s does not resolve\n' "$defect" >&2
        return 2
    fi
    printf '%s\n' "$info"
}

case "${1:-list}" in
    list)    cmd_list ;;
    resolve) shift
             [ $# -ge 1 ] || { printf 'usage: citations.sh resolve <suite>\n' >&2; exit 2; }
             cmd_resolve "$1" ;;
    *) printf 'usage: citations.sh [list|resolve <suite>]\n' >&2; exit 2 ;;
esac
