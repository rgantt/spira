#!/usr/bin/env bash
#
# test-loom-page.sh — the view model is derived in the page, not delivered pre-chewed.
#
#   ./test-loom-page.sh
#
# `test-loom.sh` beside it gates the SERVER. This gates the page: the two are deliberately
# separate suites because they fail for different reasons and skip on different machines —
# one wants a Rust toolchain, this one wants a JS runtime.
#
# WHAT THIS HOLDS, and why each one is here rather than assumed:
#
#   1. CHAINS FINDS THE COMPONENTS THE PAYLOAD USED TO NAME. Connected components, execution
#      layers, depth and width are the one part of the model that is a real algorithm rather
#      than a bucket count, and they are what the surface is FOR: a component thirty deep and
#      one wide is an epic capped at one worker however many are free, and that is invisible
#      from any single bead in it. The fixture states the shapes; the derivation must find
#      exactly those.
#   2. AND THE COMPARISON CAN SEE A DIFFERENCE. A component check that passes is worthless
#      until it has been shown to fail: the same assertion run against a fixture with one
#      edge removed must reject it (law-absence-needs-a-positive-control).
#   3. THE CONFIGURED LABELS ARE HONOURED. The escalation and CI labels are settable, and the
#      fixture pins both to something the shipped defaults are NOT — asserting against the
#      default passes just as well if the code has the literal written in, which is the thing
#      the key exists to stop.
#   4. IT PARSES WHAT THE TRACKER ACTUALLY EMITS. Not a hand-written idea of it: the last arm
#      seeds a throwaway database, reads it back through `bd`, and derives from that
#      (law-prefer-the-real-dependency). A stub reproduces the surface you remember, so its
#      gaps surface as failures in correct code.
#   5. NOTHING PRE-CHEWED SURVIVES IN THE SHIPPED PAGE. No embedded payload, no coordinates,
#      no server-computed anything — the port is only finished if the old payload is gone.
#
# WHY node AND NOT A BROWSER. model.js is the half that touches no document and no network,
# which is exactly what lets the SHIPPED file be loaded under a bare JS runtime. A browser
# would test more and would also make this suite unrunnable on a machine that has no reason
# to have one; the rendering was verified separately, by eye and by a headless run, against
# the same fixture this asserts on.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOOM="$HERE/../loom/static"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }
# NEVER `... | grep -q` UNDER pipefail: grep -q exits on the first match and closes the pipe,
# the writer dies of SIGPIPE, and pipefail propagates 141 — so the check fails precisely when
# it succeeds. Match a captured string with a herestring instead.
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3]"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "found [$3]"; else ok "$1"; fi; }

NODE="$(command -v node || command -v nodejs)"
if [ -z "$NODE" ]; then
    # A LOUD SKIP, NEVER A SILENT PASS. The page is JavaScript and there is no honest way to
    # assert on it without a JS runtime; a suite that quietly returned 0 here would report
    # the derivation as tested on every machine that cannot run it.
    echo "SKIP test-loom-page: no node on PATH — the view model cannot be exercised" >&2
    echo "     install node, or accept that loom/static/model.js is ungated on this box" >&2
    exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------------------------------------------------------------------------------------
echo "the fixture is what the generator produces"
# A fixture edited by hand no longer matches the shapes its generator claims, and the claim
# is the whole assertion. Regenerating into a scratch file and diffing keeps the two honest
# without making the suite depend on the generator at run time.
if command -v python3 >/dev/null 2>&1; then
    if python3 "$LOOM/fixture.py" > "$TMP/regen.json" 2>"$TMP/regen.err"; then
        if diff -q "$TMP/regen.json" "$LOOM/fixture.json" >/dev/null; then
            ok "fixture.json is fixture.py's own output"
        else
            bad "fixture.json is fixture.py's own output" "they differ — re-run fixture.py"
        fi
    else
        bad "fixture.py runs" "$(head -3 "$TMP/regen.err")"
    fi
fi

# ---------------------------------------------------------------------------------------
echo "the view model, derived from a raw bead array"
cat > "$TMP/derive.js" <<'JS'
const M = require(process.argv[2] + '/model.js');
const F = require(process.argv[3]);
// The fixture pins `now`, so every age, bucket and daily count is a fixed expected value
// rather than one that changes at midnight.
const m = M.derive(F.beads, Object.assign({ now: Date.parse(F.now) }, F.meta));
const out = {
    live: m.stats.live,
    edges: m.edges.length,
    chained: m.stats.chained,
    components: m.components.map(c => [c.size, c.depth, c.width]),
    expect: F.expect.components,
    closedDropped: m.beads['closed-1'] === undefined,
    // the four relations that must NOT become edges
    provenanceIgnored: !m.edges.some(e => e[0] === 'de-rej'),
    danglingDropped: !m.edges.some(e => e[0] === 'long-since-closed' || e[1] === 'long-since-closed'),
    dupeCollapsed: m.edges.filter(e => e[0] === 'dia-a' && e[1] === 'dia-b').length,
    // the configured labels
    askHonoured: m.beads['ga-ask'].nr && m.beads['ga-ask2'].nr,
    askCount: m.stats.waiting,
    ciHonoured: m.beads['ga-ci-0'].ci,
    ciCount: m.stats.parked,
    // label-derived counters
    attempts: m.beads['de-rej'].att,
    reclaims: m.beads['de-churn'].rec,
    poisoned: m.beads['de-poison'].poi,
    // grouping
    repos: m.repos.map(r => r.repo),
    alphaEpics: m.repos.find(r => r.repo === 'alpha').epics.map(e => [e.id, e.title, e.n]),
    unmapped: m.repos.find(r => r.repo === 'unmapped').n,
    // layering: the serial chain's last bead is on the last layer
    lastLayer: m.beads['ch-31'].lay,
    diamondLayers: ['dia-a', 'dia-b', 'dia-c', 'dia-d'].map(i => m.beads[i].lay),
    cyclic: m.cyclic,
    // flow and flight
    flowDays: m.flow.days.length,
    arrivals: m.flow.created.reduce((a, b) => a + b, 0),
    flight: m.flight.buckets,
    // and nothing computed over closed beads is present under a name that implies it
    hasCycleField: 'cycle' in m,
    hasClosedSeries: 'closed' in m.flow,
};
console.log(JSON.stringify(out));
JS
D="$("$NODE" "$TMP/derive.js" "$LOOM" "$LOOM/fixture.json" 2>"$TMP/err")"
if [ -z "$D" ]; then
    bad "model.js loads and derives" "$(head -5 "$TMP/err")"
else
    ok "model.js loads and derives"
    g() { "$NODE" -e 'const d=JSON.parse(process.argv[1]);const v=process.argv[2].split(".").reduce((o,k)=>o&&o[k],d);console.log(typeof v==="object"?JSON.stringify(v):String(v))' "$D" "$1"; }

    echo "chains finds the components the fixture names"
    is "the component shapes match exactly" "$(g expect)" "$(g components)"
    is "every chained bead is in one"       "46" "$(g chained)"
    is "and the edge count is right"        "41" "$(g edges)"
    is "the serial chain is 32 layers deep" "31" "$(g lastLayer)"
    # A diamond is the case a SHORTEST-path layering gets wrong: dia-d has two prerequisites
    # and must sit behind the slower one, on layer 2, not layer 1.
    is "a diamond lays out by longest path" "[0,1,1,2]" "$(g diamondLayers)"
    is "no cycle was reported"              "false" "$(g cyclic)"

    echo "what must not become an edge"
    is "a closed bead is dropped"                  "true" "$(g closedDropped)"
    is "a provenance relation is not an edge"      "true" "$(g provenanceIgnored)"
    is "a dependency on a bead not present is not" "true" "$(g danglingDropped)"
    is "the same edge from both ends is one edge"  "1"    "$(g dupeCollapsed)"

    echo "the configured label vocabulary is honoured"
    # The fixture pins both labels OFF their shipped defaults, so a page with the default
    # written in scores zero here rather than passing by coincidence.
    is "the escalation label is read from config" "true" "$(g askHonoured)"
    is "and counted"                              "2"    "$(g askCount)"
    is "the CI label is read from config"         "true" "$(g ciHonoured)"
    is "and counted"                              "3"    "$(g ciCount)"

    echo "counters come off the labels"
    is "attempts are the largest N"          "3"    "$(g attempts)"
    # `sp-reclaim-4-unrecorded` is the same reclaim as `sp-reclaim-4`, recorded differently.
    is "reclaims count the -unrecorded form" "4"    "$(g reclaims)"
    is "poison is a label, not a status"     "true" "$(g poisoned)"

    echo "grouping by repository and epic"
    is "repos are ordered by size"            '["alpha","beta","delta","gamma","unmapped"]' "$(g repos)"
    is "a bead with no repo label is bucketed" "12" "$(g unmapped)"
    # The epic's title comes from the parent bead when it is present, and falls back to the
    # id when it is not — an epic named by its id is legible, one named "undefined" is a bug.
    # The loose bucket goes LAST however large it is.
    is "epics resolve, fall back, loose last" \
       '[["alpha/ch-epic","Everything alpha has queued",32],["alpha/gone-epic","gone-epic",8],["alpha/seq-epic","Four steps that really do run in order",4],["alpha/loose","(no epic)",2]]' \
       "$(g alphaEpics)"

    echo "flow is arrivals and time in flight, and says so"
    is "the window is fourteen days" "14" "$(g flowDays)"
    # 53 of the fixture's 114 live beads carry a created_at inside the window; the rest are
    # older and must not be counted, which is the case a naive "count every bead" gets wrong.
    is "arrivals are counted"        "53" "$(g arrivals)"
    # Completions per day and created-to-closed cycle time are computed over closed beads,
    # which the read path does not carry. They must be ABSENT rather than approximated from
    # the open population: a number computed over the wrong population still reads as the
    # number it is named after.
    is "no cycle-time field exists"      "false" "$(g hasCycleField)"
    is "no completions series exists"    "false" "$(g hasClosedSeries)"
fi

# ---------------------------------------------------------------------------------------
# THE SERVER LIFTS THE DEPENDENCY RECORDS OUT OF THE ROWS so it does not write each one
# twice; the tracker's own JSON leaves them on each bead. Same records, two arrangements, and
# the page must find the same graph from either — a second reader for the second arrangement
# is how the two come to disagree about which relations count.
echo "both arrangements of the dependency records give the same graph"
"$NODE" -e '
const fs = require("fs");
const M = require(process.argv[1] + "/model.js");
const F = JSON.parse(fs.readFileSync(process.argv[1] + "/fixture.json", "utf8"));
const opts = Object.assign({ now: Date.parse(F.now) }, F.meta);

// on the beads, as the tracker writes it
const onBead = M.derive(JSON.parse(JSON.stringify(F.beads)), opts);

// lifted into one flat array, as the server sends it, with the rows stripped
const lifted = [];
const rows = JSON.parse(JSON.stringify(F.beads));
for (const b of rows) { for (const d of (b.dependencies || [])) lifted.push(d); delete b.dependencies; }
const off = M.derive(rows, Object.assign({ edges: lifted }, opts));

const shape = m => JSON.stringify(m.components.map(c => [c.size, c.depth, c.width]));
// The positive control for this arm: strip the records and send NO edges, and the graph must
// collapse. Without it, two identical answers prove only that both paths found nothing.
const none = M.derive(JSON.parse(JSON.stringify(rows)), opts);
if (shape(onBead) !== shape(off)) { console.log("DIFFER " + shape(onBead) + " vs " + shape(off)); process.exit(1); }
if (none.components.length !== 0) { console.log("STRIPPED-STILL-FOUND-EDGES"); process.exit(1); }
console.log("SAME");
' "$LOOM" > "$TMP/lift" 2>&1
is "lifted edges and on-bead edges agree" "SAME" "$(cat "$TMP/lift")"

# ---------------------------------------------------------------------------------------
echo "the comparison can tell a difference (positive control)"
# Plant an offender: drop one edge from the serial chain, which splits it into two
# components. If the shape assertion above still passes against this, it proves nothing.
"$NODE" -e '
const fs = require("fs");
const F = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
let cut = 0;
for (const b of F.beads) {
    if (b.id !== "ch-16") continue;
    b.dependencies = (b.dependencies || []).filter(d => d.depends_on_id !== "ch-15");
    cut++;
}
if (cut !== 1) { console.error("the planted offender did not apply"); process.exit(3); }
fs.writeFileSync(process.argv[2], JSON.stringify(F));
' "$LOOM/fixture.json" "$TMP/broken.json" 2>"$TMP/planterr"
if [ $? -ne 0 ]; then
    bad "the offender could be planted" "$(cat "$TMP/planterr")"
else
    BROKEN="$("$NODE" "$TMP/derive.js" "$LOOM" "$TMP/broken.json" 2>&1)"
    bshapes="$("$NODE" -e 'console.log(JSON.stringify(JSON.parse(process.argv[1]).components))' "$BROKEN" 2>/dev/null)"
    bexpect="$("$NODE" -e 'console.log(JSON.stringify(JSON.parse(process.argv[1]).expect))' "$BROKEN" 2>/dev/null)"
    if [ "$bshapes" = "$bexpect" ]; then
        bad "one missing edge changes the components" "the check cannot see a difference: $bshapes"
    else
        ok "one missing edge changes the components"
    fi
    has "and it splits the chain in two" "$bshapes" "[16,16,1],[16,16,1]"
fi

# ---------------------------------------------------------------------------------------
echo "nothing pre-chewed survives in the shipped page"
PAGE="$(cat "$LOOM/loom.html")"
hasnt "no embedded payload block"        "$PAGE" 'id="payload"'
hasnt "no server-side layout viewbox"    "$PAGE" '"vb":'
has   "the page loads the model"         "$PAGE" '<script src="model.js">'
has   "and the painter"                  "$PAGE" '<script src="app.js">'
has   "one style block, opened"          "$PAGE" '<style>'
is    "and closed exactly once"          "1" "$(grep -c '^</style>' "$LOOM/loom.html")"
APP="$(cat "$LOOM/app.js")"
has   "the page fetches its own beads"   "$APP" 'fetch(API'
has   "and derives the model itself"     "$APP" 'LoomModel.derive'
hasnt "no coordinates arrive precomputed" "$APP" '.xy'
# EVERY ELEMENT THE PAINTER ADDRESSES MUST EXIST. A stale id is not an error the browser
# reports: `$('#gone').textContent = x` throws mid-render, so everything after that line
# silently does not happen and the page looks merely incomplete. One survived the port.
missing=""
while read -r id; do
    grep -qF "id=\"$id\"" "$LOOM/loom.html" && continue
    # An id the painter WRITES and then addresses is fine — the crumb's unzoom button and the
    # inspector's close button exist only once something is drawn.
    grep -qF "id=\"$id\"" "$LOOM/app.js" && continue
    missing="$missing $id"
done < <(grep -oE "\\\$\('#[A-Za-z0-9_-]+'\)" "$LOOM/app.js" | sed "s/.*'#//;s/'.*//" | sort -u)
is "every id the painter addresses exists" "" "$missing"

# ---------------------------------------------------------------------------------------
# THE REAL DEPENDENCY. Everything above runs against a fixture whose record shape was copied
# from the tracker's JSON; this arm proves the shape is still the tracker's. A model of a
# dependency drifts silently, and its gaps surface as failures in correct code.
echo "it parses what the tracker actually emits"
# shellcheck source=/dev/null
. "$HERE/testdb.sh"
if ! testdb_available; then
    echo "  SKIP  no fixture database reachable — the real-dependency arm did not run" >&2
else
    testdb_up loom >/dev/null 2>&1
    trap 'testdb_drop >/dev/null 2>&1; rm -rf "$TMP"' EXIT INT TERM
    bdq() { bd -C "$SPIRA_DB" "$@"; }
    bdq create "a bead that blocks another" -t task -p 1 -l repo:alpha >/dev/null 2>&1
    bdq create "the bead it blocks" -t task -p 2 -l repo:alpha >/dev/null 2>&1
    ids="$(bdq list --limit 0 --json 2>/dev/null | sed -n '/^[[{]/,$p' \
           | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
               const a=JSON.parse(s); console.log(a.map(b=>b.id).join(" "));})')"
    set -- $ids
    if [ $# -lt 2 ]; then
        bad "two beads could be created" "got [$ids]"
    else
        bdq dep add "$2" "$1" >/dev/null 2>&1
        RAW="$(bdq list --limit 0 --json 2>/dev/null | sed -n '/^[[{]/,$p')"
        printf '%s' "$RAW" > "$TMP/live.json"
        R="$("$NODE" -e '
const M = require(process.argv[1] + "/model.js");
const m = M.derive(JSON.parse(require("fs").readFileSync(process.argv[2], "utf8")), {});
console.log([m.stats.live, m.edges.length, m.components.length,
             m.components[0] ? m.components[0].depth : 0,
             m.repos[0] ? m.repos[0].repo : ""].join(" "));
' "$LOOM" "$TMP/live.json" 2>"$TMP/liveerr")"
        if [ -z "$R" ]; then
            bad "the tracker's own JSON derives" "$(head -5 "$TMP/liveerr")"
        else
            ok "the tracker's own JSON derives"
            set -- $R
            is "both beads are live"                 "2" "$1"
            is "the blocking edge was found"         "1" "$2"
            is "they form one component"             "1" "$3"
            is "two layers deep"                     "2" "$4"
            is "the repo label groups them"     "alpha" "$5"
        fi
    fi
fi

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
