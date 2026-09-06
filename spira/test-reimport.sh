#!/usr/bin/env bash
#
# test-reimport.sh — the re-import, against fixtures.
#
#   ./test-reimport.sh
#
# WHAT IS ACTUALLY BEING TESTED
# -----------------------------
# Not that `bd import` upserts — that is the tool's claim, verified live against the real
# database once (every row imported, then the same count `unchanged`, repeat run identical). What
# is tested here is every decision reimport.sh makes AROUND that call, because each of them
# is a way to convert a routine refresh into damage that reports success:
#
#   * a mirror row with an `sp-` id would upsert over the plan for replacing Gas Town
#   * an unmapped id prefix lands a bead in no repo partition, invisible to every query
#   * a `repo:` label taken from the FILE rather than the ID misfiles the 93 foreign-prefix
#     rows the town database holds
#   * a rig whose export failed keeps its previous file while the manifest is stamped fresh,
#     so the re-import converges perfectly onto yesterday
#   * a fayth whose predicate omits `spira` claims work a live Gas Town polecat is doing
#
# A REAL `bd` on a fixture database created for the run and dropped by a trap, because half
# of what reimport.sh does IS a bd call — export, `import --dry-run`, import, memories,
# recompute-blocked — and the convergence check is a claim about bd's upsert semantics
# rather than about this script. A model of that upsert is a second implementation of it,
# and the two disagreeing is a bug in neither and a failure in both
# (law-prefer-the-real-dependency). Running against the LIVE Spira database is what the
# fixture avoids: it would import real beads, and the case that matters most — a rig whose
# export FAILED — cannot be arranged there at all.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
rcis()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted rc=$2 got rc=$3"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-reimport
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up reimport || { echo "test-reimport: could not build a fixture database"; exit 1; }
BUILD="$HERE/reimport-payload.py"

row() {  # row <id> [label ...]
    local id="$1"; shift
    python3 -c '
import json, sys
print(json.dumps({"id": sys.argv[1], "title": "t " + sys.argv[1], "status": "open",
                  "updated_at": "2026-09-04T00:00:00Z", "labels": sys.argv[2:]},
                 sort_keys=True))' "$id" "$@"
}

mirror() {  # mirror <dir>: a miniature of the real thing, foreign prefixes and all
    local m="$1"; mkdir -p "$m"
    { row pd-1; row pd-2; } > "$m/repo-a.jsonl"
    { row po-1; }            > "$m/repo-b.jsonl"
    # The town holds its own hq- rows AND cross-rig trackers carrying other rigs' prefixes,
    # which is the whole reason the label is derived from the id and not the filename.
    { row hq-1; row hq-2; row hq-3; row pd-9; row ho-1; } > "$m/town.jsonl"
    printf 'ho=homemanager\n' > "$m/../map"
}

build() { python3 "$BUILD" "$@" 2>&1; }

# ======================================================================================
echo "reimport-payload.sh — the partition label:"
# ======================================================================================
M="$TMP/a/mirror"; mirror "$M"
out="$(build "$M" "$TMP/a/out" "$TMP/a/map")"; rc=$?
rcis "a well-formed mirror builds" 0 "$rc"
want "  the map is derived from the filenames" '"pd": "repo-a"' "$out"
want "  the override file supplies a retired prefix" '"ho": "homemanager"' "$out"
want "  every row is in the payload" '"rows": 8' "$out"

labels_of() { python3 -c '
import json, sys
for line in open(sys.argv[1]):
    o = json.loads(line)
    if o["id"] == sys.argv[2]:
        print(" ".join(o["labels"])); break' "$TMP/a/out/payload.jsonl" "$1"; }
want "  an hq- row is repo:town" "repo:town" "$(labels_of hq-1)"
# The one that catches the plausible implementation: labelling by source file would file
# this under repo:town, because that is the file it arrived in.
want "  a pd- row INSIDE town.jsonl is repo:repo-a" "repo:repo-a" "$(labels_of pd-9)"
nowant "  and is not also repo:town" "repo:town" "$(labels_of pd-9)"
nowant "  no imported row carries the ownership marker" "spira" "$(cat "$TMP/a/out/payload.jsonl")"

# ======================================================================================
echo "reimport-payload.sh — it refuses rather than lands a half-truth:"
# ======================================================================================
M="$TMP/b/mirror"; mirror "$M"
row sp-spira >> "$M/town.jsonl"
out="$(build "$M" "$TMP/b/out" "$TMP/b/map")"; rc=$?
rcis "an sp- id in the mirror is fatal" 1 "$rc"
want "  and says why" "would overwrite the plan" "$out"
[ ! -f "$TMP/b/out/payload.jsonl" ] && ok "  and writes no payload" || bad "  and writes no payload" "payload exists"

M="$TMP/c/mirror"; mirror "$M"; printf '' > "$TMP/c/map"
out="$(build "$M" "$TMP/c/out" "$TMP/c/map")"; rc=$?
rcis "an unmapped prefix is fatal" 1 "$rc"
want "  naming the prefix" "ho- (1 rows)" "$out"
want "  and the file to fix" "$TMP/c/map" "$out"

M="$TMP/d/mirror"; mirror "$M"
row pd-8 spira >> "$M/repo-a.jsonl"
out="$(build "$M" "$TMP/d/out" "$TMP/d/map")"; rc=$?
rcis "an imported row carrying 'spira' is fatal" 1 "$rc"
want "  because it would become claimable" "must never be claimable" "$out"

M="$TMP/e/mirror"; mirror "$M"
{ row zz-1; row yy-1; row xx-1; } > "$M/collecting.jsonl"
out="$(build "$M" "$TMP/e/out" "$TMP/e/map")"; rc=$?
rcis "a file with no dominant prefix is fatal" 1 "$rc"
want "  named as the duplicate-mirror failure" "resolving to one database" "$out"

M="$TMP/f/mirror"; mirror "$M"; : > "$M/household.jsonl"
out="$(build "$M" "$TMP/f/out" "$TMP/f/map")"; rc=$?
rcis "an empty mirror file is fatal" 1 "$rc"
want "  named as a failed export" "export failed" "$out"

M="$TMP/g/mirror"; mirror "$M"; printf 'not json\n' >> "$M/repo-b.jsonl"
out="$(build "$M" "$TMP/g/out" "$TMP/g/map")"; rc=$?
rcis "an unparseable row is fatal, never skipped" 1 "$rc"

# The override must not shadow a rig the mirror can still speak for; letting it would
# silently misfile a live rig on the strength of a stale line in a config file.
M="$TMP/h/mirror"; mirror "$M"; printf 'ho=homemanager\npd=wrongrepo\n' > "$TMP/h/map"
out="$(build "$M" "$TMP/h/out" "$TMP/h/map")"
want "the mirror outvotes a stale override" '"pd": "repo-a"' "$out"

# ======================================================================================
echo "reimport-payload.sh — memories are held back:"
# ======================================================================================
M="$TMP/i/mirror"; mirror "$M"
printf '{"_type":"memory","key":"law-x","value":"old text"}\n' >> "$M/town.jsonl"
out="$(build "$M" "$TMP/i/out" "$TMP/i/map")"
want "  counted" '"memories": 1' "$out"
nowant "  but not in the payload bd import is given" "law-x" "$(cat "$TMP/i/out/payload.jsonl")"
want "  written aside for comparison" "law-x" "$(cat "$TMP/i/out/memories.jsonl")"

# ======================================================================================
echo "reimport.sh run — a stale mirror is refused, not imported:"
# ======================================================================================
# A fake town whose rigs are directories with a .beads, exactly as live_rigs reads them,
# and a fake exporter that rewrites some files and not others.
setup_run() {   # setup_run <case> <exporter-body>
    local c="$1" body="$2"; local d="$TMP/$c"
    mkdir -p "$d/gt/.beads" "$d/gt/repo-b/.beads" "$d/gt/deacon/.beads" "$d/mirror" "$d/run"
    { row hq-1; } > "$d/mirror/town.jsonl"
    { row po-1; } > "$d/mirror/repo-b.jsonl"
    printf '%s\n' "#!/usr/bin/env bash" "$body" > "$d/export.sh"; chmod +x "$d/export.sh"
    touch -d '2020-01-01' "$d/mirror"/*.jsonl
    # Each run starts from an empty database. reimport.sh's convergence check re-imports the
    # identical payload and asserts nothing changed, so a case inheriting the previous
    # case's rows would converge for the wrong reason.
    testdb_reset
}
run_case() {    # run_case <case> [args...]
    local c="$1"; shift
    # env -i so the run cannot inherit this shell's beads configuration, and PATH carries
    # `bd` because the program under test is now the real one
    # (law-gates-run-in-a-clean-environment).
    env -i PATH="$PATH" HOME="$HOME" \
        SPIRA_HOME="$HERE" SPIRA_DB="$SPIRA_DB" SPIRA_RUN="$TMP/$c/run" \
        SPIRA_MIRROR="$TMP/$c/mirror" SPIRA_EXPORTER="$TMP/$c/export.sh" \
        SPIRA_TOWN="$TMP/$c/gt" SPIRA_PREFIX_MAP="$TMP/$c/map" \
        SPIRA_REIMPORT_LOG="$TMP/$c/run/reimport.log" \
        bash "$HERE/reimport.sh" "$@" 2>&1
}

setup_run stale 'touch "$0"'   # an exporter that rewrites nothing
out="$(run_case stale run)"; rc=$?
rcis "a mirror file the refresh did not rewrite stops the run" 1 "$rc"
want "  naming the rig" "town.jsonl was not rewritten" "$out"
want "  and the cause" "its export failed" "$out"
nowant "  and nothing is imported" "import returned" "$out"

setup_run fresh 'touch "$SPIRA_MIRROR"/*.jsonl'
out="$(run_case fresh run)"; rc=$?
rcis "a refresh that rewrote every rig proceeds" 0 "$rc"
want "  and says so" "every live rig's mirror file was rewritten" "$out"
want "  and imports" "import returned" "$out"
want "  and converges" "converged" "$out"

# A rig that exists live and has never been exported has no file at all — which asking the
# mirror what rigs exist could never notice.
setup_run norig 'touch "$SPIRA_MIRROR"/*.jsonl'
mkdir -p "$TMP/norig/gt/newrig/.beads"
out="$(run_case norig run)"; rc=$?
rcis "a live rig with no mirror file stops the run" 1 "$rc"
want "  naming it" "newrig has no mirror file" "$out"

# deacon/ resolves to the town database. Requiring a deacon.jsonl would fail every run.
nowant "deacon is not required to have a mirror file" "deacon has no mirror" "$(run_case fresh run)"

# ======================================================================================
echo "the fence — nothing may consume the replica before cutover:"
# ======================================================================================
fence_with() {  # fence_with <FAYTH_LABELS-line>
    local d="$TMP/fence"; rm -rf "$d"; mkdir -p "$d/chamber" "$d/run"
    cp "$HERE"/*.sh "$HERE"/*.py "$d/" 2>/dev/null
    printf 'FAYTH_NAME=t\n%s\nFAYTH_EXCLUDE_LABELS=x\n' "$1" > "$d/chamber/t.fayth"
    testdb_reset
    env -i PATH="$PATH" HOME="$HOME" \
        SPIRA_HOME="$d" SPIRA_DB="$SPIRA_DB" \
        SPIRA_RUN="$d/run" bash "$d/reimport.sh" fence 2>&1
}
out="$(fence_with 'FAYTH_LABELS="spira,plan"')"; rc=$?
rcis "a predicate requiring 'spira' is fenced" 0 "$rc"
out="$(fence_with 'FAYTH_LABELS="plan"')"; rc=$?
rcis "a predicate without 'spira' is refused" 1 "$rc"
want "  and says what it would see" "select imported Gas Town work" "$out"
out="$(fence_with 'FAYTH_LABELS=""')"; rc=$?
rcis "an empty predicate is refused" 1 "$rc"
want "  as selecting everything" "selects the whole database" "$out"
# `plan` is a substring of nothing here, but `spira-poison` contains `spira` — a fence
# written with a substring match would pass this and it must not.
out="$(fence_with 'FAYTH_LABELS="spira-poison,plan"')"; rc=$?
rcis "a label merely CONTAINING spira does not count" 1 "$rc"

# ======================================================================================
echo "the fence binds the aeon, not just the report:"
# ======================================================================================
d="$TMP/aeon"; mkdir -p "$d/chamber" "$d/run"
cp "$HERE"/*.sh "$HERE"/*.py "$d/" 2>/dev/null
printf 'FAYTH_NAME=u\nFAYTH_LABELS="plan"\nFAYTH_EXCLUDE_LABELS=x\nFAYTH_MAX_CONCURRENT=1\n' > "$d/chamber/u.fayth"
testdb_reset
testdb_seed <<'JSONL'
{"id":"pd-1","title":"live gastown work","status":"open","issue_type":"task","labels":["plan"],"updated_at":"2026-09-04T00:00:00Z"}
JSONL
out="$(env -i PATH="$PATH" HOME="$HOME" \
    SPIRA_HOME="$d" SPIRA_DB="$SPIRA_DB" SPIRA_RUN="$d/run" \
    bash "$d/aeon.sh" u 2>&1)"; rc=$?
rcis "aeon.sh refuses to claim behind an unfenced predicate" 1 "$rc"
want "  before it claims anything" "refusing to claim" "$out"
nowant "  so nothing was claimed" "claimed pd-1" "$out"

# ======================================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
