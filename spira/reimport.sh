#!/usr/bin/env bash
#
# reimport.sh — refresh Spira's copy of Gas Town's beads from the JSONL mirror.
#
#   reimport.sh check                 read-only: how stale is the mirror, what would change
#   reimport.sh run [--no-refresh]    refresh the mirror, import it, verify, report
#   reimport.sh fence                 can any persona see the Gas Town replica?
#
# WHY THIS EXISTS
# ---------------
# Imported beads are a SNAPSHOT taken at one moment, and the system they came from goes on
# writing to its own databases afterwards. The drift is invisible in the worst possible
# way: `bd ready` in Spira answers confidently while describing a past state. So the copy
# is refreshed immediately before cutover — import is upsert, so it converges — and until
# then nothing consumes it (`fence`, and the refusal in aeon.sh).
#
# THE STALENESS IS TWO-LAYERED, AND ONLY ONE LAYER IS OBVIOUS
# -----------------------------------------------------------
# live database -> mirror -> Spira. Re-importing closes the second hop. If the first hop is
# stale the re-import converges perfectly onto yesterday, reports every count green, and is
# wrong — which is why `run` refreshes the mirror itself rather than trusting whatever the
# six-hourly cron last left, and why it then checks the refresh actually happened PER RIG.
# export-beads.sh keeps the previous file when a rig's export fails and warns to a stderr
# nobody reads, while still stamping the manifest with the run's time. The manifest cannot
# tell you a rig is stale; the file's mtime can.
#
# NOTHING HERE MAY WRITE TO GAS TOWN. Every read of a live rig passes `--readonly`, which
# blocks writes in the tool rather than in the author's intentions, and lib.sh exports
# BEADS_NO_AUTO_IMPORT=1 so merely looking at a rig cannot import into it.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

MIRROR="$SPIRA_MIRROR"
EXPORTER="$SPIRA_EXPORTER"
PREFIX_MAP="${SPIRA_PREFIX_MAP:-$SPIRA_HOME/prefix-map}"
TOWN="$SPIRA_TOWN"
REPORT="${SPIRA_REIMPORT_LOG:-$SPIRA_RUN/reimport.log}"
BUILD="$SPIRA_HOME/reimport-payload.py"

usage() { sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

fail=0
bad() { fail=$((fail+1)); log "FAIL $*"; }

# One scratch directory for the whole run, removed once. An earlier version made it
# `local` in each command and trapped EXIT on it, so cleanup ran after the name had gone
# out of scope and died on `tmp: unbound variable` under set -u — leaving the payload,
# which carries every bead in the town, in /tmp.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:-}"' EXIT

# --------------------------------------------------------------------------------------
# live_rigs — the same rule export-beads.sh uses, deliberately duplicated rather than
# inferred from what the mirror happens to contain: a rig added to Gas Town and never
# exported has NO mirror file, so asking the mirror what rigs exist can never notice it.
# --------------------------------------------------------------------------------------
live_rigs() {
    local dir rig
    for dir in "$TOWN" "$TOWN"/*/; do
        dir="${dir%/}"
        [ -d "$dir/.beads" ] || continue
        if [ "$dir" = "$TOWN" ]; then rig="town"; else rig="$(basename "$dir")"; fi
        # deacon/ resolves to the town database; it is the same rows under another name.
        [ "$rig" = "deacon" ] && continue
        printf '%s\t%s\n' "$rig" "$dir"
    done
}

# --------------------------------------------------------------------------------------
# CHECK — read-only, and the thing to run before deciding to cut over.
# --------------------------------------------------------------------------------------
cmd_check() {
    log "mirror: $MIRROR"
    if [ -f "$MIRROR/manifest.md" ]; then
        log "  manifest says: $(grep -m1 '^Snapshot:' "$MIRROR/manifest.md" | sed 's/Snapshot: //; s/\*//g')"
    fi

    # Hop 1: live vs mirror. This is the drift a re-import CANNOT fix, so it is reported
    # first and in its own terms.
    log "hop 1 — live Gas Town vs the mirror:"
    local rig dir n_live n_mirror only_live
    while IFS=$'\t' read -r rig dir; do
        [ -n "$rig" ] || continue
        if [ ! -f "$MIRROR/$rig.jsonl" ]; then
            bad "  $rig has no mirror file at all — export-beads.sh has never seen it"
            continue
        fi
        if ! bd --readonly -C "$dir" export -o "$tmp/$rig.live" >/dev/null 2>&1; then
            bad "  $rig will not export; cannot say whether its mirror is current"
            continue
        fi
        read -r n_live n_mirror only_live <<< "$(python3 - "$tmp/$rig.live" "$MIRROR/$rig.jsonl" <<'PY'
import json, sys
def ids(p):
    out = {}
    for line in open(p):
        line = line.strip()
        if not line: continue
        o = json.loads(line)
        if o.get("_type") == "memory" or not o.get("id"): continue
        out[o["id"]] = str(o.get("updated_at") or "")
    return out
a, b = ids(sys.argv[1]), ids(sys.argv[2])
drift = sum(1 for k, v in a.items() if k not in b or b[k] != v)
print(len(a), len(b), drift)
PY
)"
        if [ "${only_live:-0}" -gt 0 ]; then
            log "  $rig: live $n_live, mirror $n_mirror — ${only_live} row(s) newer or absent in the mirror"
        else
            log "  $rig: live $n_live, mirror $n_mirror — current"
        fi
    done < <(live_rigs)

    # Hop 2: mirror vs Spira, answered by the importer itself rather than by a diff of my
    # own devising. `--dry-run --json` is the documented surface and it knows the upsert
    # rules; a hand-rolled comparison would be a second, worse opinion of them.
    log "hop 2 — the mirror vs Spira:"
    python3 "$BUILD" "$MIRROR" "$tmp" "$PREFIX_MAP" >"$tmp/summary.json" || { bad "payload will not build"; return; }
    log "  payload: $(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(str(d["rows"]) + " issues, " + str(d["memories"]) + " memories held back")' "$tmp/summary.json")"
    local dry; dry="$(bdq import --dry-run --json "$tmp/payload.jsonl" 2>/dev/null | json_only)"
    log "  would import: $(printf '%s' "$dry" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(", ".join(f"{k}={v}" for k,v in sorted(d.items()) if k in ("created","unchanged","skipped","updated")))' 2>/dev/null)"
    memory_drift "$tmp/memories.jsonl"

    cmd_fence
}

# --------------------------------------------------------------------------------------
# memory_drift — the statute book, compared and never applied.
#
# `bd import` treats a memory row as `bd remember`: an unconditional overwrite with no
# staleness guard, unlike an issue, which only rewrites when strictly newer. Spira is an
# authoring surface for the book — it holds four records the town has never had — so
# applying the town's copy can only move it backwards. rule.sh writes both databases, so a
# difference means someone wrote to one alone: a fact to surface, not to resolve silently.
# --------------------------------------------------------------------------------------
memory_drift() {         # memory_drift <memories.jsonl>
    local f="$1" out lm
    # BOTH SIDES AS FILES. A heredoc carrying the program REPLACES stdin, so a version of
    # this that piped `bd memories` in read an empty book and reported all 46 statutes
    # missing from a database holding all 46 — a check that cries wolf on its first run is
    # a check nobody reads on its hundredth.
    lm="$(mktemp)"; bdq memories --json 2>/dev/null | json_only > "$lm"
    out="$(python3 - "$f" "$lm" <<'PY'
import json, sys
try: local = json.load(open(sys.argv[2]))
except Exception: local = {}
local = {k: v for k, v in local.items() if isinstance(v, str) and k != "schema_version"}
mirror = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        o = json.loads(line)
        mirror[o["key"]] = o.get("value", "")
missing = sorted(set(mirror) - set(local))
differ = sorted(k for k in mirror if k in local and mirror[k].strip() != local[k].strip())
extra = sorted(set(local) - set(mirror))
print(f"{len(mirror)} in the mirror, {len(local)} in Spira")
if missing: print("  ABSENT FROM SPIRA: " + ", ".join(missing))
if differ:  print("  TEXT DIFFERS: " + ", ".join(differ))
if extra:   print("  SPIRA-ONLY (expected — Spira authors too): " + ", ".join(extra))
PY
)"
    rm -f "$lm"
    while IFS= read -r line; do [ -n "$line" ] && log "  memories: $line"; done <<< "$out"
}

# --------------------------------------------------------------------------------------
# FENCE — can any persona reach the replica? Two questions, because either alone has a
# blind spot: the predicates as written, and the database as it actually is.
# --------------------------------------------------------------------------------------
cmd_fence() {
    log "fence — the Gas Town replica must be unreachable until cutover:"
    local f name
    for f in "$SPIRA_HOME"/chamber/*.fayth; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .fayth)"
        # A subshell per fayth: these files are sourced, and one leaking FAYTH_LABELS into
        # the next would make an unfenced fayth read as fenced by its neighbour's value.
        if (
            # shellcheck disable=SC1090
            . "$f"
            fayth_fenced "$name" "${FAYTH_LABELS:-}"
        ); then
            log "  fayth '$name': fenced"
        else
            bad "  fayth '$name' is not fenced"
        fi
    done

    # And the marker itself, asked as the question it is actually for. What must never
    # happen is that a bead GAS TOWN IS STILL WORKING acquires Spira's ownership marker —
    # two agents on one issue, both of whom will do it.
    #
    # The test used to be "carries both `spira` and a `repo:` label", which was a proxy that
    # held only while `repo:` belonged exclusively to imported rows. It does not any more: a
    # `repo:` label is how a Spira-native bead names the repository it is worked in, which is
    # what made this harness cross-repo at all, so the old test would have failed the moment
    # the first bead of a given prefix was filed. Ask the mirror instead — it IS the roster of
    # what Gas Town owns, and it stays the right question after cutover, when adopting an
    # imported bead deliberately means labelling it `spira`.
    local both fx mids; fx="$(mktemp)"; mids="$(mktemp)"
    cat "$MIRROR"/*.jsonl 2>/dev/null > "$mids"
    bdq export -o "$fx" >/dev/null 2>&1
    both="$(python3 -c '
import json, sys
def ids(path):
    out = set()
    try: fh = open(path)
    except Exception: return out
    for line in fh:
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except Exception: continue
        if o.get("_type") == "memory" or not o.get("id"): continue
        out.add(o["id"])
    return out
imported = ids(sys.argv[1])
bad = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    if "spira" in (o.get("labels") or []) and o.get("id") in imported:
        bad.append(o["id"])
print(" ".join(bad))' "$mids" < "$fx" 2>/dev/null)"
    rm -f "$fx" "$mids"
    if [ -n "${both:-}" ]; then
        bad "  Spira has claimed bead(s) Gas Town is still working: $both"
    else
        log "  marker: no bead in the Gas Town mirror carries Spira's 'spira' marker"
    fi
}

# --------------------------------------------------------------------------------------
# RUN — the thing to execute immediately before cutover.
# --------------------------------------------------------------------------------------
cmd_run() {
    local refresh=1
    [ "${1:-}" = "--no-refresh" ] && refresh=0

    # ---- what must survive unchanged -------------------------------------------------
    # Snapshotted BEFORE anything moves. Verifying afterwards against a re-derived
    # expectation would be verifying the import against itself.
    bdq export -o "$tmp/before.jsonl" >/dev/null 2>&1 || die "cannot export Spira; refusing to import into a database I cannot read"
    bdq memories --json 2>/dev/null | json_only > "$tmp/before-mem.json"

    # ---- hop 1: refresh the mirror ---------------------------------------------------
    if [ "$refresh" = 1 ]; then
        [ -x "$EXPORTER" ] || die "no exporter at $EXPORTER"
        local t0; t0="$(date +%s)"
        log "refreshing the mirror: $EXPORTER"
        "$EXPORTER" >"$tmp/export.log" 2>&1
        log "  exporter exit $? ($(wc -l <"$tmp/export.log" | tr -d ' ') lines of output)"
        head -20 "$tmp/export.log" | sed 's/^/  export: /'
        # PER RIG, not per manifest. A rig whose export failed keeps its previous file and
        # its previous mtime while the manifest is stamped with this run's clock — so the
        # manifest reports a freshness the file does not have. Nothing that failed here is
        # allowed to be imported as if it were current.
        local rig dir stale=0
        while IFS=$'\t' read -r rig dir; do
            [ -n "$rig" ] || continue
            if [ ! -f "$MIRROR/$rig.jsonl" ]; then
                bad "$rig has no mirror file after a refresh"; stale=1; continue
            fi
            if [ "$(stat -c %Y "$MIRROR/$rig.jsonl")" -lt "$t0" ]; then
                bad "$rig.jsonl was not rewritten by the refresh — its export failed and the file is stale"
                stale=1
            fi
        done < <(live_rigs)
        [ "$stale" = 0 ] || die "the mirror is stale for at least one rig; fix the export before importing"
        log "  every live rig's mirror file was rewritten"
    else
        log "--no-refresh: importing whatever the mirror currently holds"
    fi

    # ---- build -----------------------------------------------------------------------
    python3 "$BUILD" "$MIRROR" "$tmp" "$PREFIX_MAP" >"$tmp/summary.json" || die "payload will not build"
    local rows; rows="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["rows"])' "$tmp/summary.json")"
    log "payload: $rows issues (memories held back — see memory_drift)"

    # ---- import ----------------------------------------------------------------------
    # The change report comes from a DRY RUN taken first, not from the import's own result.
    # The two do not use the same words: a real import of a payload the dry-run called
    # a run that changed nothing reports `created=N` alongside `unchanged=N`, so reading the
    # import's own numbers would announce N new beads on a run that did nothing. The
    # convergence check below re-reads the same dry-run surface, so the before and after
    # numbers are comparable to each other, which is the only property that matters.
    local pre
    pre="$(bdq import --dry-run --json "$tmp/payload.jsonl" 2>/dev/null | json_only)"
    log "would change: $(printf '%s' "$pre" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(", ".join(k + "=" + str(v) for k, v in sorted(d.items()) if isinstance(v, int) and not isinstance(v, bool) and k != "schema_version"))' 2>/dev/null)"

    local res
    res="$(bdq import --json "$tmp/payload.jsonl" 2>/dev/null | json_only)"
    if [ -z "${res:-}" ]; then die "import produced no result"; fi
    log "import returned: $(printf '%s' "$res" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(", ".join(k + "=" + str(v) for k, v in sorted(d.items()) if isinstance(v, int) and not isinstance(v, bool) and k != "schema_version"))' 2>/dev/null)"

    # is_blocked is a cached column. An import that lands new blocking edges leaves it
    # stale, and a stale is_blocked is exactly the failure that makes `bd ready` lie —
    # which is the failure this whole bead is about.
    bdq recompute-blocked >/dev/null 2>&1 || bad 'recompute-blocked failed; is_blocked may be stale, which is exactly what makes bd ready lie'

    # ---- verify ----------------------------------------------------------------------
    bdq export -o "$tmp/after.jsonl" >/dev/null 2>&1 || { bad "cannot export Spira after the import"; return; }
    local v
    v="$(python3 - "$tmp/payload.jsonl" "$tmp/before.jsonl" "$tmp/after.jsonl" <<'PY'
import json, sys

def rows(p):
    out = {}
    for line in open(p):
        line = line.strip()
        if line:
            o = json.loads(line)
            out[o["id"]] = o
    return out

payload, before, after = rows(sys.argv[1]), rows(sys.argv[2]), rows(sys.argv[3])
bad = []

missing = sorted(set(payload) - set(after))
if missing:
    bad.append(f"{len(missing)} payload row(s) are not in the database after the import: {missing[:5]}")

wrong = [i for i in payload if i in after
         and len([l for l in (after[i].get('labels') or []) if l.startswith('repo:')]) != 1]
if wrong:
    bad.append(f"{len(wrong)} imported bead(s) do not carry exactly one repo: label: {sorted(wrong)[:5]}")

# THE PLAN ITSELF. Import is upsert by id and the plan lives in the same database as the
# replica, so "could this command overwrite Spira's own work" is what decides whether it is
# safe to run at all. The guarantee is addressability: a row can only touch a bead whose id
# it carries, and reimport-payload.py dies on an `sp-` id rather than importing one.
native_before = {i for i, o in before.items() if "spira" in (o.get("labels") or [])}
native_after = {i for i, o in after.items() if "spira" in (o.get("labels") or [])}
reachable = sorted(native_before & set(payload))
if reachable:
    bad.append(f"the payload ADDRESSES {len(reachable)} Spira-native bead(s): {reachable[:5]}")
if native_before != native_after:
    bad.append("the set of Spira-native beads changed across the import: "
               f"gained {sorted(native_after - native_before)[:5]}, "
               f"lost {sorted(native_before - native_after)[:5]}")

# Content drift is REPORTED, never failed. This database has a live aeon in it heartbeating
# its own lease every two minutes, so a bead's updated_at moving between the two snapshots
# is the normal case — and a check that fails on it fails on nearly every real run, which
# is how a check becomes something people pass with a flag.
drifted = [i for i in sorted(native_before & native_after)
           if json.dumps(before[i], sort_keys=True) != json.dumps(after[i], sort_keys=True)]
print(f"  {len(payload)} payload rows, {len(after)} beads in Spira, {len(native_after)} of them Spira-native")
print(f"  the payload addresses none of the {len(native_after)} Spira-native beads")
if drifted:
    print(f"  {len(drifted)} Spira-native bead(s) changed during the run (a live aeon's "
          f"heartbeat, not this import — it cannot address them): {drifted[:5]}")
for b in bad:
    print("  FAIL " + b)
PY
)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *"FAIL "*) bad "${line#*FAIL }" ;; *) log "verify:$line" ;; esac
    done <<< "$v"

    # The statutes, compared but never applied.
    memory_drift "$tmp/memories.jsonl"
    if ! diff -q <(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$tmp/before-mem.json" 2>/dev/null) \
                 <(bdq memories --json 2>/dev/null | json_only | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))' 2>/dev/null) >/dev/null 2>&1; then
        bad "the re-import changed the statute book; memories must never be written by this command"
    else
        log "verify:  the statute book is byte-identical to before the import"
    fi

    # ---- convergence -----------------------------------------------------------------
    # Proved, not asserted. Re-running the identical payload must now report every row
    # unchanged; anything else means the import did not fully apply and a second run would
    # keep moving the database — which is the opposite of "import is upsert, so it
    # converges", the sentence this whole step rests on.
    local again
    again="$(bdq import --dry-run --json "$tmp/payload.jsonl" 2>/dev/null | json_only)"
    local conv
    conv="$(printf '%s' "$again" | python3 -c '
import sys, json
d = json.load(sys.stdin)
n = d.get("unchanged", 0); c = d.get("created", 0); u = d.get("updated", 0)
print(f"{c} {u} {n}")' 2>/dev/null)"
    read -r c_created c_updated c_unchanged <<< "${conv:-1 1 0}"
    if [ "${c_created:-1}" != 0 ] || [ "${c_updated:-0}" != 0 ] || [ "${c_unchanged:-0}" != "$rows" ]; then
        bad "the import did not converge: a repeat dry-run reports created=$c_created updated=$c_updated unchanged=$c_unchanged of $rows"
    else
        log "verify:  converged — a repeat of the identical payload changes nothing ($c_unchanged/$rows unchanged)"
    fi

    cmd_fence

    # ---- report ----------------------------------------------------------------------
    mkdir -p "$(dirname "$REPORT")"
    printf '%s reimport rows=%s failures=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rows" "$fail" >> "$REPORT"
}

case "${1:-}" in
    check) cmd_check ;;
    run)   shift; cmd_run "$@" ;;
    fence) cmd_fence ;;
    *)     usage ;;
esac

if [ "$fail" -gt 0 ]; then
    log "$fail failure(s) — this re-import is NOT to be treated as a successful refresh"
    exit 1
fi
exit 0
