#!/usr/bin/env python3
"""reimport-payload.py — turn the Gas Town JSONL mirror into one import payload.

    reimport-payload.py <mirror-dir> <out-dir> <prefix-map-file>

Writes <out-dir>/payload.jsonl (issues, ready for `bd import`) and
<out-dir>/memories.jsonl (the statute records, held back — see below), then prints a JSON
summary on stdout. Exits non-zero, having written nothing, when the payload cannot be
built safely.

WHY THE MIRROR IS NOT FED TO `bd import` DIRECTLY
-------------------------------------------------
Three things have to happen between the mirror and the database, and each of them is a way
the re-import can quietly do damage.

1. THE `repo:` LABEL IS THE PARTITION. Spira collapsed seven databases into one, so the
   thing that used to be "which database is this in" is now a label. It is not in the
   mirror — Gas Town has no idea it exists — so every row must carry one before it lands.
   Adding it here rather than in a relabelling pass afterwards means it arrives WITH the
   row: `bd import` merges and dedupes labels, so one pass both creates and repairs, and
   there is no window in which an imported bead sits in no partition at all.

   The label is derived from the id PREFIX, not from the file the row came from. town.jsonl
   holds 93 rows whose ids begin pd-, de-, po-, co-, hh- and px- — convoy trackers and
   cross-rig copies — and filing those under `repo:town` would put them in the wrong repo.

2. `sp-` IS SPIRA'S OWN. Import is upsert by id. A mirror row with an `sp-` id would
   overwrite a plan bead — the plan for replacing Gas Town, overwritten by Gas Town. No
   such row exists today; the cost of checking is one comparison and the cost of missing it
   is the epic.

3. MEMORIES ARE HELD BACK. The town mirror carries 46 memory records and `bd import`
   applies them like `bd remember`: an unconditional overwrite with NO staleness guard,
   unlike issues, which only rewrite when strictly newer. Spira is now an authoring surface
   for the book — it holds four records the town has never seen — so importing the town's
   copy can only ever move it backwards. They are written to a separate file and compared
   rather than applied. `rule.sh enact` already writes both databases, so a difference here
   means someone wrote to one alone, which is a fact worth surfacing rather than silently
   resolving.
"""
import collections
import glob
import json
import os
import sys


def die(msg, fix=""):
    print(f"reimport-payload: {msg}", file=sys.stderr)
    if fix:
        print(f"  fix: {fix}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 4:
        die("usage: reimport-payload.py <mirror-dir> <out-dir> <prefix-map-file>")
    mirror, outdir, mapfile = sys.argv[1], sys.argv[2], sys.argv[3]

    files = sorted(glob.glob(os.path.join(mirror, "*.jsonl")))
    if not files:
        die(f"no *.jsonl in {mirror}", "run .claude/export-beads.sh")

    # ---- read ------------------------------------------------------------------------
    # A parse failure is fatal rather than skipped. The mirror is machine-written and a
    # row that will not parse means the exporter produced something new; importing the
    # rest would land a partial snapshot while reporting success.
    per_file, memories = {}, []
    for path in files:
        rig = os.path.basename(path)[: -len(".jsonl")]
        rows = []
        for n, line in enumerate(open(path), 1):
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception as e:
                die(f"{path}:{n} will not parse: {e}",
                    "re-run .claude/export-beads.sh; never hand-edit the mirror")
            if o.get("_type") == "memory":
                memories.append(o)
                continue
            if not o.get("id"):
                die(f"{path}:{n} has no id", "re-run .claude/export-beads.sh")
            rows.append(o)
        if not rows:
            die(f"{path} holds no issues",
                "a rig whose export failed keeps its previous file; check export-beads.sh stderr")
        per_file[rig] = rows

    # ---- the prefix map --------------------------------------------------------------
    # Derived from the mirror itself: a file named for its rig votes its dominant id
    # prefix. Deriving it beats hardcoding it because a rig added to Gas Town tomorrow
    # maps itself. The override file covers only what the mirror can no longer say —
    # a prefix whose rig has been removed, so no file votes for it.
    prefix_map = {}
    for rig, rows in per_file.items():
        counts = collections.Counter(r["id"].split("-")[0] for r in rows)
        ranked = counts.most_common()
        top, n = ranked[0]
        # A PLURALITY, not a majority. The town database legitimately holds rows from every
        # other rig — 93 of its 660 today, convoy trackers and cross-rig copies — so a
        # majority test would reject a perfectly good mirror the day those grew past half.
        # The failure actually being probed for is two files holding the SAME database, and
        # that is caught below by "this prefix is already claimed". What a plurality cannot
        # survive is a TIE, where the mapping this file votes for is a coin flip.
        if len(ranked) > 1 and ranked[1][1] == n:
            die(f"{rig}.jsonl has no single commonest id prefix ({dict(counts)})",
                "two rigs are resolving to one database; check .beads redirects")
        if top in prefix_map:
            die(f"prefix '{top}-' is claimed by both {prefix_map[top]} and {rig}",
                "two mirror files hold the same database")
        prefix_map[top] = rig

    overrides = {}
    if os.path.exists(mapfile):
        for n, line in enumerate(open(mapfile), 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if "=" not in line:
                die(f"{mapfile}:{n} is not <prefix>=<repo>: {line!r}")
            p, r = line.split("=", 1)
            overrides[p.strip()] = r.strip()
    # The mirror wins over the override file. An override is a fallback for a prefix no
    # file can vote for; letting it shadow a live rig would silently misfile that rig.
    resolved = dict(overrides)
    resolved.update(prefix_map)

    # ---- build -----------------------------------------------------------------------
    # Deduped by id, newest updated_at winning. `bd import`'s own staleness guard makes
    # the order irrelevant to the database, but a deterministic payload is what lets the
    # verify step prove convergence by re-running the same dry-run and reading 0.
    unmapped = collections.Counter()
    native, owned = [], []
    best = {}
    for rig, rows in per_file.items():
        for o in rows:
            oid = o["id"]
            prefix = oid.split("-")[0]
            if prefix == "sp":
                native.append(f"{rig}.jsonl:{oid}")
                continue
            repo = resolved.get(prefix)
            if repo is None:
                unmapped[prefix] += 1
                continue
            labels = list(o.get("labels") or [])
            # The ownership marker. An imported bead carrying it would be claimable by
            # every fayth — the exact race this whole step exists to prevent.
            if "spira" in labels:
                owned.append(oid)
                continue
            if f"repo:{repo}" not in labels:
                labels.append(f"repo:{repo}")
            o["labels"] = labels
            prior = best.get(oid)
            if prior is None or str(o.get("updated_at") or "") >= str(prior.get("updated_at") or ""):
                best[oid] = o

    if native:
        die("the mirror holds rows with Spira-native `sp-` ids: " + ", ".join(native[:5]),
            "import is upsert by id — these would overwrite the plan; find out how a "
            "sp- bead reached a Gas Town database before importing anything")
    if owned:
        die("imported rows already carry the `spira` ownership label: " + ", ".join(owned[:5]),
            "an imported bead must never be claimable; remove the label in Gas Town or "
            "rename the marker")
    if unmapped:
        die("no repo for id prefix(es): " + ", ".join(f"{p}- ({n} rows)" for p, n in sorted(unmapped.items())),
            f"add a line '<prefix>=<repo>' to {mapfile} — an unlabelled bead sits in no "
            "repo partition and is invisible to every cross-repo query")

    os.makedirs(outdir, exist_ok=True)
    payload = os.path.join(outdir, "payload.jsonl")
    with open(payload, "w") as fh:
        for oid in sorted(best):
            fh.write(json.dumps(best[oid], sort_keys=True) + "\n")
    with open(os.path.join(outdir, "memories.jsonl"), "w") as fh:
        for m in sorted(memories, key=lambda m: m.get("key", "")):
            fh.write(json.dumps(m, sort_keys=True) + "\n")

    repos = collections.Counter()
    for o in best.values():
        repos[next(l for l in o["labels"] if l.startswith("repo:"))] += 1
    print(json.dumps({
        "rows": len(best),
        "memories": len(memories),
        "files": {rig: len(rows) for rig, rows in sorted(per_file.items())},
        "prefix_map": dict(sorted(resolved.items())),
        "repos": dict(sorted(repos.items())),
    }, indent=2))


if __name__ == "__main__":
    main()
