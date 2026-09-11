#!/usr/bin/env bash
#
# test-aeon-prod-dirty.sh — bead close is refused while the shared harness checkout carries
#                           uncommitted tracked modifications.
#
#   ./test-aeon-prod-dirty.sh
#
# THE DEFECT THIS GUARDS. A session hand-applied a file to SPIRA_REPO (the shared
# production checkout every aeon and timer reads from) to make a fix take effect without
# waiting for a pull. The modification was byte-identical to the remote tip: no new
# information, but git saw it as dirty. skew.sh refresh refuses a dirty tree, so the
# hand-copy disabled the hourly automatic repair. The checkout fell behind silently while
# every aeon and timer continued executing the hand-modified version, invisible to the
# commit graph.
#
# FOUR CASES (law-absence-needs-a-positive-control):
#   1. Bead closed, SPIRA_REPO dirty (genuine change) → reopened, paths named, override named.
#   2. Bead closed, SPIRA_REPO dirty with byte-identical content → reopened, remedy named.
#   3. Bead closed, SPIRA_REPO clean → bead stays closed.
#   4. Bead closed, SPIRA_REPO dirty, SPIRA_ALLOW_PROD_DIRTY=1 → bead stays closed (override).
#
# Driven through the REAL aeon.sh against a real bd on a throwaway fixture, with a shim
# standing in for the model (law-prefer-the-real-dependency). SPIRA_REPO is a separate git
# repository from the bead's target repo, matching production topology where the harness
# checkout and the work repo are different paths.
#
# ISOLATION BETWEEN CASES: after each case where the bead is reopened, the bead is marked
# spira-poison so subsequent aeon runs do not claim it. Only the current case's bead is
# available for the next aeon.
#
# covers: spira/aeon.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# CLEAR ANY INHERITED SHARED FIXTURE before building our own. An aeon session exports
# TESTDB_SHARED=1 with temp dirs that may no longer exist on disk; running testdb_up
# against a stale shared fixture always fails. Unsetting here forces a fresh build for
# this suite without affecting the caller's environment (subshell cannot modify parent).
#
# SPIRA_DB IS ALSO UNSET. The aeon session sets SPIRA_DB to the production database path,
# which has a .beads directory. conf.sh (sourced transitively via testdb.sh) runs
# `bd migrate schema` against any SPIRA_DB that has .beads. The production database uses
# a dolt server that may not be running during a test. Unsetting SPIRA_DB causes conf.sh
# to re-derive it to the default path (~/.local/share/spira/db) which has no .beads, so
# the migration check is skipped. testdb_up then sets SPIRA_DB to the fresh fixture.
unset TESTDB_SHARED TESTDB_NAME TESTDB_DIR TESTDB_BASELINE TESTDB_BIN \
      TESTDB_MODE TESTDB_STARTED_SERVICE SPIRA_DB

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-aeon-prod-dirty
TMP="$(mktemp -d)"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up aeonproddirty || { echo "test-aeon-prod-dirty: could not build a fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ---- harness repo (SPIRA_REPO) --------------------------------------------------------
# A tracked file that can be dirtied. SPIRA_HOME lives inside this repo so conf.sh derives
# SPIRA_REPO = the git root = this checkout. Topology matches production: harness and bead
# target are separate checkouts.
HARNESS_ORIGIN="$TMP/harness.git"; git init -q --bare -b main "$HARNESS_ORIGIN"
HARNESS="$TMP/harness"; git clone -q "$HARNESS_ORIGIN" "$HARNESS" 2>/dev/null
git -C "$HARNESS" config user.email t@t; git -C "$HARNESS" config user.name t
printf 'harness script v1\n' > "$HARNESS/incident.sh"
git -C "$HARNESS" add incident.sh
git -C "$HARNESS" commit -qm "seed harness"
git -C "$HARNESS" push -q origin main 2>/dev/null

# Push a "v2" commit to the harness REMOTE via a scratch clone. The fetch comes after the
# push so HARNESS sees origin/main = v2 while HEAD stays at v1 (BEHIND+potentially-DIRTY).
HARNESS_SCRATCH="$TMP/harness-scratch"
git clone -q "$HARNESS_ORIGIN" "$HARNESS_SCRATCH" 2>/dev/null
git -C "$HARNESS_SCRATCH" config user.email t@t; git -C "$HARNESS_SCRATCH" config user.name t
printf 'harness script v2\n' > "$HARNESS_SCRATCH/incident.sh"
git -C "$HARNESS_SCRATCH" add incident.sh
git -C "$HARNESS_SCRATCH" commit -qm "v2: landed fix"
git -C "$HARNESS_SCRATCH" push -q origin main 2>/dev/null
# Now fetch in HARNESS so origin/main points to v2; HEAD still = v1.
git -C "$HARNESS" fetch -q origin 2>/dev/null || true

# THE GUARD: set SPIRA_REPO explicitly to the harness checkout so both the test and the
# verdict block address the same path. conf.sh uses ${SPIRA_REPO:-derived}, so an already-
# exported value wins over derivation.
export SPIRA_REPO="$HARNESS"

# ---- bead target repo (separate from SPIRA_REPO) --------------------------------------
ORIGIN="$TMP/origin.git"; git init -q --bare -b main "$ORIGIN"
REPO="$TMP/repo"; git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/f"
git -C "$REPO" add f; git -C "$REPO" commit -qm seed; git -C "$REPO" push -q origin main 2>/dev/null

# ---- harness setup --------------------------------------------------------------------
# SPIRA_HOME is a subdirectory of HARNESS (a git-tracked repo), so conf.sh derives
# SPIRA_REPO = git root of HARNESS, matching the exported SPIRA_REPO above.
export SPIRA_HOME="$HARNESS/spira-home"; mkdir -p "$SPIRA_HOME/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/aeon.sh" "$SPIRA_HOME/"
cp -r "$HERE/actors" "$SPIRA_HOME/" 2>/dev/null || true
export SPIRA_RUN="$TMP/run"; mkdir -p "$SPIRA_RUN"
export SPIRA_REPO_MAP="$TMP/repo-map"
printf 'fixture | %s | push | origin/main | |\n' "$REPO" > "$SPIRA_REPO_MAP"
# builder.fayth: excludes spira-poison so beads from completed cases are skipped.
cat > "$SPIRA_HOME/chamber/builder.fayth" <<'FAYTH'
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
FAYTH_EXCLUDE_LABELS="spira-poison,needs-operator"
FAYTH_MAX_CONCURRENT=1
FAYTH_HEARTBEAT_SECONDS=600
FAYTH
printf 'work {{BEAD_ID}} in {{REPO}} on {{BRANCH}}\n{{PARK}}\n' > "$SPIRA_HOME/chamber/builder.md"

# ---- shim: stands in for claude -------------------------------------------------------
# conf.sh replaces $PATH entirely, so a PATH shim silently runs the real model.
BIN="$TMP/bin"; mkdir -p "$BIN"; export SPIRA_AGENT="$BIN/claude" TMP HARNESS
grep -q 'SPIRA_AGENT' "$HERE/aeon.sh" \
    || { echo "test-aeon-prod-dirty: aeon.sh has no SPIRA_AGENT injection point — refusing to run the real model" >&2; exit 1; }

# Shim behaviour is driven by $TMP/shim-dirty:
#   clean          — do not touch SPIRA_REPO
#   genuine        — append a unique edit to SPIRA_REPO/incident.sh (differs from origin/main)
#   byte-identical — write v2 content to SPIRA_REPO/incident.sh (matches origin/main)
# The shim writes the bead ID it worked on to $TMP/last-bead so note checks use the right bead.
cat > "$BIN/claude" <<'SHIM'
#!/usr/bin/env bash
cat /dev/stdin > "$TMP/prompt"
id="$(sed -n 's/^work \(sp-[a-z0-9-]*\) .*/\1/p' "$TMP/prompt" | head -1)"
printf '%s' "$id" > "$TMP/last-bead"

# Commit the bead's own work.
printf 'my work\n' >> f
git add -A && git -c user.email=a@a -c user.name=aeon commit -qm "$id: the work"

# Optionally dirty SPIRA_REPO (the shared harness checkout, not the worktree).
case "$(cat "$TMP/shim-dirty" 2>/dev/null)" in
    genuine)
        # Append a unique edit — content differs from both HEAD and origin/main.
        printf 'unexpected local edit\n' >> "$HARNESS/incident.sh"
        ;;
    byte-identical)
        # Write v2 content, which matches origin/main exactly but differs from HEAD.
        printf 'harness script v2\n' > "$HARNESS/incident.sh"
        ;;
esac

bd -C "$SPIRA_DB" close "$id" --reason "done" >/dev/null 2>&1
SHIM
chmod +x "$BIN/claude"

# Helper: read the note body on a bead (bd note sets the top-level "notes" field).
latest_note() {   # latest_note <bead-id>
    bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null \
        | python3 -c '
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]
print(d[0].get("notes","") if d else "")' 2>/dev/null
}

# Helper: read the status of a bead.
bead_status() {
    bd -C "$SPIRA_DB" show "$1" --json 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("status","") if d else "")' 2>/dev/null
}

# Helper: poison a bead so later aeon runs skip it (isolates cases from each other).
poison_bead() {
    bd -C "$SPIRA_DB" label add "$1" spira-poison >/dev/null 2>&1 || true
}

# ============================================================
echo
echo "CASE 1 (positive control): SPIRA_REPO dirty with genuine change — bead must be reopened:"
echo "-----------------------------------------------------------------------"
printf 'genuine' > "$TMP/shim-dirty"
b1="$(bd -C "$SPIRA_DB" create --title "test: genuine dirty" --type task \
        -l spira,plan,repo:fixture 2>/dev/null | grep -oE 'sp-[a-z0-9-]+')"
[ -n "$b1" ] || { bad "case 1 bead created" "(bead-create failed)"; true; }
unset SPIRA_ALLOW_PROD_DIRTY
bash "$SPIRA_HOME/aeon.sh" builder >/dev/null 2>&1 || true
is "genuine dirty: bead is reopened" "open" "$(bead_status "$b1")"
note1="$(latest_note "$b1")"
want "genuine dirty: note names the modified path" "incident.sh" "$note1"
want "genuine dirty: note names the override variable" "SPIRA_ALLOW_PROD_DIRTY" "$note1"
# Restore HARNESS and exclude bead1 from future aeon claims.
git -C "$HARNESS" checkout -q -- incident.sh 2>/dev/null || true
poison_bead "$b1"

# ============================================================
echo
echo "CASE 2: SPIRA_REPO dirty with byte-identical content — reopened with remedy:"
echo "-----------------------------------------------------------------------"
printf 'byte-identical' > "$TMP/shim-dirty"
b2="$(bd -C "$SPIRA_DB" create --title "test: byte-identical" --type task \
        -l spira,plan,repo:fixture 2>/dev/null | grep -oE 'sp-[a-z0-9-]+')"
[ -n "$b2" ] || { bad "case 2 bead created" "(bead-create failed)"; true; }
unset SPIRA_ALLOW_PROD_DIRTY
bash "$SPIRA_HOME/aeon.sh" builder >/dev/null 2>&1 || true
# Read the note on the bead the aeon actually worked (should be b2).
worked2="$(cat "$TMP/last-bead" 2>/dev/null)"
is "byte-identical: bead is reopened" "open" "$(bead_status "$b2")"
note2="$(latest_note "${worked2:-$b2}")"
want "byte-identical: note names the modified path" "incident.sh" "$note2"
want "byte-identical: note contains checkout remedy" "checkout --" "$note2"
want "byte-identical: note names the override variable" "SPIRA_ALLOW_PROD_DIRTY" "$note2"
git -C "$HARNESS" checkout -q -- incident.sh 2>/dev/null || true
poison_bead "$b2"

# ============================================================
echo
echo "CASE 3: SPIRA_REPO clean — bead must stay closed:"
echo "-----------------------------------------------------------------------"
printf 'clean' > "$TMP/shim-dirty"
b3="$(bd -C "$SPIRA_DB" create --title "test: clean checkout" --type task \
        -l spira,plan,repo:fixture 2>/dev/null | grep -oE 'sp-[a-z0-9-]+')"
[ -n "$b3" ] || { bad "case 3 bead created" "(bead-create failed)"; true; }
unset SPIRA_ALLOW_PROD_DIRTY
bash "$SPIRA_HOME/aeon.sh" builder >/dev/null 2>&1 || true
is "clean checkout: bead stays closed" "closed" "$(bead_status "$b3")"

# ============================================================
echo
echo "CASE 4: SPIRA_REPO dirty with SPIRA_ALLOW_PROD_DIRTY=1 — bead must stay closed:"
echo "-----------------------------------------------------------------------"
printf 'genuine' > "$TMP/shim-dirty"
b4="$(bd -C "$SPIRA_DB" create --title "test: dirty with override" --type task \
        -l spira,plan,repo:fixture 2>/dev/null | grep -oE 'sp-[a-z0-9-]+')"
[ -n "$b4" ] || { bad "case 4 bead created" "(bead-create failed)"; true; }
SPIRA_ALLOW_PROD_DIRTY=1 bash "$SPIRA_HOME/aeon.sh" builder >/dev/null 2>&1 || true
is "override: bead stays closed despite dirty checkout" "closed" "$(bead_status "$b4")"
git -C "$HARNESS" checkout -q -- incident.sh 2>/dev/null || true

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
