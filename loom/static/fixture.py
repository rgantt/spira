#!/usr/bin/env python3
"""fixture.py — regenerate `fixture.json`, the corpus `test-loom.sh` derives against.

    ./fixture.py > fixture.json

WHY A GENERATOR AND NOT A HAND-EDITED BLOB. The fixture is a hundred-odd records and its
value is entirely in properties that are invisible when you read it — that this component is
four beads three layers deep and two wide, that this dependency is provenance rather than
order, that this bead is closed so the derivation must drop it. Written out by hand those
properties are a claim in a comment; written by this they are the code that produced the
data, and a reader can check the shape without counting records.

WHY IT IS SYNTHETIC. It reproduces the SHAPES a real graph produces — a long fully serial
chain, a diamond, a scatter of pairs, beads with no repository and no parent — under names
that belong to nobody. A fixture copied from a live database ships that database's
inventory, and the landing gate refuses it.

THE CLOCK IS PINNED. `now` is a constant here and the suite passes the same value to the
derivation, so every age, bucket and daily count is a fixed expected value rather than one
that changes at midnight. A fixture whose expectations drift with the wall clock fails on a
day nobody changed anything, which is how a suite stops being read.

THE CONFIGURED VALUES ARE PINNED OFF THEIR DEFAULTS. The escalation and CI labels are
settable, so the fixture names them something the shipped defaults are not. Asserting
against the default passes just as well if the code has the literal written in, which is the
thing the key exists to stop.
"""
import json

NOW = "2026-06-15T12:00:00Z"          # the instant the suite measures from
ASK = "escalate-me"                    # deliberately NOT the shipped default
CI = "in-ci"                           # deliberately NOT the shipped default
POISON = "spira-poison"

beads = []
edges = []


def at(days_ago, hours=0):
    """An ISO timestamp `days_ago` days before NOW, to the hour."""
    from datetime import datetime, timedelta, timezone
    t = datetime(2026, 6, 15, 12, tzinfo=timezone.utc) - timedelta(days=days_ago, hours=hours)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def bead(bid, repo=None, parent=None, status="open", prio=2, ty="task",
         created=30, touched=1, labels=(), assignee=None, title=None):
    ls = list(labels)
    if repo:
        ls.append("repo:" + repo)
    b = {
        "id": bid,
        "title": title or ("work item " + bid),
        "description": "A synthetic bead. Its content carries no meaning; its shape does.",
        "status": status,
        "priority": prio,
        "issue_type": ty,
        "created_at": at(created),
        "updated_at": at(touched),
        "labels": ls,
    }
    if parent:
        b["parent"] = parent
    if assignee:
        b["assignee"] = assignee
    beads.append(b)
    return b


def blocks(blocker, blocked):
    """Record a real blocking edge, on the BLOCKED bead, which is where the tracker puts it."""
    edges.append((blocker, blocked))
    for b in beads:
        if b["id"] == blocked:
            b.setdefault("dependencies", []).append({
                "issue_id": blocked, "depends_on_id": blocker,
                "type": "blocks", "created_at": at(20), "created_by": "harness",
            })
            return
    raise SystemExit("blocks(): no such bead " + blocked)


# ---------------------------------------------------------------------------------------
# the chained beads: six components whose shapes are the ones a real harness produces
#
#   (size, depth, width)
#   (32, 32, 1)   one epic's whole backlog chained head to tail — the shape worth seeing,
#                 because it caps that epic at one worker however many are free
#   ( 4,  4, 1)   a genuine four-step sub-task sequence
#   ( 4,  3, 2)   a diamond: one prerequisite fans out to two, which converge
#   ( 2,  2, 1)   a plain pair, three times over
# ---------------------------------------------------------------------------------------
for i in range(32):
    bead("ch-%02d" % i, repo="alpha", parent="ch-epic", prio=1 if i < 2 else 2,
         created=26 - i // 3, touched=(i % 9))
for i in range(31):
    blocks("ch-%02d" % i, "ch-%02d" % (i + 1))

for i in range(4):
    bead("seq-%d" % i, repo="alpha", parent="seq-epic", created=12, touched=i)
for i in range(3):
    blocks("seq-%d" % i, "seq-%d" % (i + 1))

for n in ("dia-a", "dia-b", "dia-c", "dia-d"):
    bead(n, repo="beta", created=9, touched=2)
blocks("dia-a", "dia-b")
blocks("dia-a", "dia-c")
blocks("dia-b", "dia-d")
blocks("dia-c", "dia-d")

for i in range(3):
    bead("pair-%da" % i, repo="beta", created=7 + i, touched=1 + i)
    bead("pair-%db" % i, repo="beta", created=7 + i, touched=1 + i)
    blocks("pair-%da" % i, "pair-%db" % i)

# The epics the chained beads point at. An epic is an ordinary bead, so it appears in the
# corpus and its title is what the grouping shows.
bead("ch-epic", repo="alpha", ty="epic", prio=1, created=27, touched=0,
     title="Everything alpha has queued")
bead("seq-epic", repo="alpha", ty="epic", prio=2, created=13, touched=3,
     title="Four steps that really do run in order")

# ---------------------------------------------------------------------------------------
# unchained beads: the rest of the distribution
# ---------------------------------------------------------------------------------------
# alpha, parented to an epic that is NOT in the corpus — its title must fall back to the id
for i in range(8):
    bead("al-%d" % i, repo="alpha", parent="gone-epic", created=20 + i, touched=15 + i)

# beta, loose, spanning the whole heat ramp from touched-today to long cold
for i in range(18):
    bead("be-%02d" % i, repo="beta", created=1 + i * 2, touched=i * 2, prio=i % 4)

# gamma: the states. Moving, deferred, blocked, and one waiting on the operator.
bead("ga-move", repo="gamma", status="in_progress", touched=0, created=3, assignee="worker-1")
bead("ga-move2", repo="gamma", status="in_progress", touched=0, created=2, assignee="worker-2")
bead("ga-block", repo="gamma", status="blocked", touched=4, created=11)
for i in range(6):
    bead("ga-def-%d" % i, repo="gamma", status="deferred", touched=20 + i, created=40 + i)
bead("ga-ask", repo="gamma", labels=[ASK], touched=2, created=5, ty="decision",
     title="A decision only the operator can take")
bead("ga-ask2", repo="gamma", labels=[ASK], touched=6, created=8, ty="decision",
     title="A second decision, older")
for i in range(3):
    bead("ga-ci-%d" % i, repo="gamma", labels=[CI], touched=1, created=4)

# delta: churn. Attempts, reclaims recorded and unrecorded, and one poisoned bead.
bead("de-rej", repo="delta", labels=["sp-attempt-1", "sp-attempt-2", "sp-attempt-3"],
     touched=1, created=10, title="Rejected at the threshold, not yet poisoned")
bead("de-poison", repo="delta", labels=["sp-attempt-1", "sp-attempt-2", "sp-attempt-3",
                                        "sp-attempt-4", POISON],
     touched=2, created=12, title="Past the threshold and poisoned")
bead("de-churn", repo="delta",
     labels=["sp-reclaim-1", "sp-reclaim-2", "sp-reclaim-3-unrecorded",
             "sp-reclaim-4-unrecorded"],
     touched=1, created=6, title="A lease taken back four times, twice without a charge")
bead("de-both", repo="delta", labels=["sp-attempt-1", "sp-reclaim-1-unrecorded"],
     touched=3, created=9)
for i in range(10):
    bead("de-%02d" % i, repo="delta", created=2 + i, touched=1 + i)

# beads carrying no repository label at all: they must group under one bucket, not vanish
for i in range(12):
    bead("un-%02d" % i, created=5 + i, touched=3 + i)

# ---------------------------------------------------------------------------------------
# the four cases that must NOT become edges or beads
# ---------------------------------------------------------------------------------------
# 1. A closed bead. The read path is bounded to work in flight, but the derivation drops one
#    itself rather than trusting it never arrives.
bead("closed-1", repo="alpha", status="closed", created=30, touched=1,
     title="Closed, and must not appear anywhere in the model")

# 2. A provenance relation is not an order. Drawn as a dependency it shows work as blocked
#    that nothing is waiting on.
beads[-2].setdefault("dependencies", []).append({
    "issue_id": beads[-2]["id"], "depends_on_id": "de-rej",
    "type": "discovered-from", "created_at": at(4), "created_by": "harness"})

# 3. A dependency naming a bead outside the live set — almost always a prerequisite that has
#    already closed. Half an edge leading nowhere is worse than none.
beads[0].setdefault("dependencies", []).append({
    "issue_id": beads[0]["id"], "depends_on_id": "long-since-closed",
    "type": "blocks", "created_at": at(25), "created_by": "harness"})

# 4. The same edge recorded from both ends. It is one edge, and counted twice it makes a
#    component look wider than it is.
for b in beads:
    if b["id"] == "dia-a":
        b.setdefault("dependencies", []).append({
            "issue_id": "dia-b", "depends_on_id": "dia-a",
            "type": "blocks", "created_at": at(9), "created_by": "harness"})

print(json.dumps({
    "now": NOW,
    "meta": {"askLabel": ASK, "ciLabel": CI, "threshold": 3},
    "expect": {
        # what Chains must find, stated here rather than inside the suite so the generator
        # and the assertion cannot drift apart
        "components": [[32, 32, 1], [4, 4, 1], [4, 3, 2], [2, 2, 1], [2, 2, 1], [2, 2, 1]],
        "edges": len(edges),
        "chained": len(set([x for e in edges for x in e])),
    },
    "beads": beads,
}, indent=1, sort_keys=False))
