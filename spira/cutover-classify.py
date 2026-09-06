#!/usr/bin/env python3
"""
cutover-classify.py — the classifier behind cutover.sh: landed commits in, an attribution out.

Split out of cutover.sh so it can be run against fixtures without a git repository, the same
split as strand.sh/strand-classify.py and cockpit.sh/cockpit-metrics.py. Everything here is
pure: stdin and environment in, JSON out, no I/O of its own.

THE MEASUREMENT IS LANDED COMMITS, NOT ACTIVITY (sp-builder-cutover). A commit counts when it
is an ancestor of the repository's landing ref; cutover.sh decides that, and every line
reaching here has already passed it. What this program decides is only WHO WROTE IT.

WHY ATTRIBUTION IS BY AUTHOR AND NOT BY BEAD ID. The obvious rule — read the bead id out of
the subject and credit the harness that owns the prefix — is wrong, and wrong in the direction
that matters. The operator personally authored 10 of one repository's landed commits in the sample week,
most of them naming a `pd-` bead, because they finished by hand what a polecat could not. Crediting
those to Gas Town would report the harness as productive precisely where it was failing, and
this number is the gate on retiring it. The bead id says which work; the author says which
worker. Only the second one is being compared.

WHY ATTRIBUTION IS NOT BY REPOSITORY EITHER. `9d70470 ruby "note: measured token cost of the
generated AGENT_INFO surface (hh-6xk)"` is a Gas Town polecat commit that landed in
the home repository, which is Spira's own. Bucketing by repo would have silently credited it
to Spira.

CLASSES

  spira     an aeon — identified by an @spira.local author address, which is an identity this
            harness issues and nothing else can claim
  gastown   a polecat, the mayor, the deacon, a refinery or a witness
  human     the operator, or anything else the actors file marks human
  other     anybody else — NEVER folded into one of the above, always named with a count

`other` is the load-bearing class. A classifier that guesses at an unrecognised author reports a
clean comparison built on an assumption nobody stated; this one hands the name back. The verdict
then decides whether the ambiguity is decisive (see cutover.sh) rather than assuming it away.

ORDER. The actors file wins over everything, because it is the deliberate override for what the
graph cannot vote on. Then the aeon address, then the roster derived from the graph. A name
absent from all three is `other`.

INPUT
  stdin        one landed commit per line: repo <TAB> author-name <TAB> author-email <TAB> subject
  ROSTER       gastown actor names, one per line (cutover.sh derives these from the git graph)
  ACTORS       `name=class` lines, `#` comments — the actors file
  BEAD_IDS     every id in the database, one per line, for the secondary beads-landed count.
               A bead created in Gas Town since the last re-import is not in it, so that count
               is a floor rather than a total — the safe direction for a number that argues
               for switching something off.

OUTPUT  a JSON object on stdout: per-repo counts, totals, distinct beads per class, and the
        unclassified authors with their commit counts.
"""
import json, os, re, sys
from collections import Counter, defaultdict

CLASSES = ("spira", "gastown", "human", "other")


def read_roster(text):
    return {ln.strip() for ln in (text or "").splitlines() if ln.strip() and not ln.startswith("#")}


def read_actors(text):
    """`name=class` lines. A malformed line is skipped rather than guessed at."""
    out = {}
    for ln in (text or "").splitlines():
        ln = ln.split("#", 1)[0].strip()
        if not ln or "=" not in ln:
            continue
        name, cls = (p.strip() for p in ln.split("=", 1))
        if name and cls in CLASSES:
            out[name] = cls
    return out


def classify(name, email, roster, actors):
    if name in actors:
        return actors[name]
    if email.endswith("@spira.local"):
        return "spira"
    if name in roster:
        return "gastown"
    return "other"


BEAD_RE = re.compile(r"\b[a-z]{2}-[a-z0-9][a-z0-9-]*\b")


def bead_ids(subject, known):
    """Bead ids named in a commit subject — the ones that actually EXIST, and no others.

    Restricting by PREFIX is not enough, which is why this takes an id set. `co` and `de` are
    both live prefixes, so a prefix-restricted match reads
    `co-located` and `de-duplication` straight out of an English sentence and reports them as
    landed work. Bead ids have no shape that separates them from hyphenated prose — `pd-lunn`
    and `sp-branch-cleanup` are both just words — so membership in the database is the only
    test that holds.

    An empty set means the probe failed, and then nothing is claimed rather than everything.
    """
    if not known:
        return set()
    return {m for m in BEAD_RE.findall(subject) if m in known}


def main():
    roster = read_roster(os.environ.get("ROSTER"))
    actors = read_actors(os.environ.get("ACTORS"))
    known = {i.strip() for i in (os.environ.get("BEAD_IDS") or "").split("\n") if i.strip()}

    per_repo = defaultdict(Counter)
    totals = Counter()
    beads = defaultdict(set)
    unclassified = Counter()

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            # A subject containing a tab would split further; rejoin the tail rather than
            # dropping the commit. Dropping is the failure this whole program exists to avoid.
            if len(parts) < 3:
                continue
            parts = parts[:3] + ["\t".join(parts[3:])]
        repo, name, email, subject = parts[0], parts[1], parts[2], parts[3]
        cls = classify(name, email, roster, actors)
        per_repo[repo][cls] += 1
        totals[cls] += 1
        if cls == "other":
            unclassified[name] += 1
        beads[cls] |= bead_ids(subject, known)

    print(json.dumps({
        "repos": {r: {c: per_repo[r].get(c, 0) for c in CLASSES} for r in sorted(per_repo)},
        "totals": {c: totals.get(c, 0) for c in CLASSES},
        "beads": {c: sorted(beads[c]) for c in CLASSES},
        "unclassified": dict(unclassified.most_common()),
    }, indent=None, sort_keys=True))


if __name__ == "__main__":
    main()
