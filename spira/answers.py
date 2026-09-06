#!/usr/bin/env python3
"""answers.py -- what the operator SAID, since the last time anybody looked.

The operator speaks to this harness in exactly two ways, and both are writes to a bead:

  a CLOSE carrying a reason   -- the verdict on an escalation; the reason IS the answer
  a COMMENT on any bead       -- including one they can never close, because an FYI is
                                 created closed and closing it again means nothing

Only the first had a delivery path. A comment on an FYI reached no session at all: the
close-cursor below cannot see one, because a comment does NOT bump the bead's updated_at
and the row `bd list` returns carries `comment_count` but not the bodies. So a reply sat
unread until the operator said so themselves -- the second time the same escalation queue
lost an answer, which is why this is a program and not a note.

WHOSE VOICE. A close made by an agent is indistinguishable from the operator's on the row:
there is no `closed_by` on it, and the Dolt committer is the literal string `beads` whatever
BEADS_ACTOR says. But beads DOES record the actor, in its audit events -- `bd history <id>
--events` yields an event of type `closed` carrying `actor`. That is authoritative and needs
no new convention, so both legs here filter on it: a verdict is reported only when the
operator's own actor name is on the event. Without that a session acts on its own echo, and
the failure is silent because the text of the announcement looks exactly like a real answer.
The panel must therefore CLOSE as the operator, not merely comment as them.

A CURSOR, NOT A TAIL. There is no file to follow; the record is a row. Each leg keeps a
high-water mark and reports only what is past it, so this is quiet when nothing has been
answered -- which is most of the time, and what makes it safe to run from a Monitor or at
session start. A bare timestamp cannot express "reported everything up to this second": two
writes can share one second, and one of them would be replayed forever or lost. So the mark
carries the timestamp AND the keys already reported AT that timestamp.

Reads the bead list on stdin, because which database to address is the caller's decision
and there is one place that decides it. Shells out only for the bodies, one process at a
time: an unbounded fan-out over every bead spawned hundreds of concurrent `bd` processes
against a single server and drove a four-core box into swap.
"""

import json
import os
import subprocess
import sys

# The fan-out ceiling. Sequential already bounds concurrency to one; this bounds the WALL
# CLOCK of a session-start hook when a cursor is far behind or a database is large. It is
# announced on stderr when it binds, never silently obeyed: a check that quietly stops
# looking reports "nothing was answered" for the one reason that is not true.
SCAN_MAX = int(os.environ.get("SPIRA_ANSWER_SCAN_MAX", "200"))


def json_only(text):
    """`bd --json` can print warnings on stdout BEFORE the payload."""
    i = min((text.find(c) for c in "[{" if text.find(c) >= 0), default=-1)
    if i < 0:
        return None
    try:
        return json.loads(text[i:])
    except Exception:
        return None


def rows_of(doc, key):
    if doc is None:
        return []
    if isinstance(doc, list):
        return doc
    return doc.get(key) or []


class Mark:
    """A high-water mark that survives a tie.

    `ts` is the newest thing reported. `seen` is every key reported AT that exact ts, which
    is what makes a second write in the same second reportable exactly once rather than
    never or forever. Older formats -- a bare timestamp on one line -- are read as a mark
    with no ties, so an installed cursor keeps working.
    """

    def __init__(self, path):
        self.path = path
        self.ts, self.seen = "", set()
        try:
            with open(path) as fh:
                raw = fh.read().strip()
        except Exception:
            return
        if not raw:
            return
        doc = json_only(raw)
        if isinstance(doc, dict):
            self.ts = doc.get("ts") or ""
            self.seen = set(doc.get("seen") or [])
        else:
            self.ts = raw.splitlines()[0].strip()

    def fresh(self):
        """True when there is no mark yet, so the caller SEEDS rather than replays history."""
        return not self.ts

    def is_new(self, ts, key):
        if not ts:
            return False
        if ts > self.ts:
            return True
        return ts == self.ts and key not in self.seen

    def write(self, reported, now):
        """`reported` is [(ts, key), ...] -- everything this pass emitted."""
        ts = self.ts
        for t, _ in reported:
            if t > ts:
                ts = t
        if not ts:
            ts = now
        seen = {k for t, k in reported if t == ts}
        if ts == self.ts:
            seen |= self.seen
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump({"ts": ts, "seen": sorted(seen)}, fh)
        os.replace(tmp, self.path)
        self.ts, self.seen = ts, seen


def bd(cfg, args, timeout=30):
    try:
        out = subprocess.run(
            [cfg["bd"], "-C", cfg["db"]] + args,
            capture_output=True, text=True, timeout=timeout,
            env=dict(os.environ, BEADS_NO_AUTO_IMPORT="1"),
        ).stdout
    except Exception:
        return None
    return json_only(out)


def cap(candidates, what):
    if len(candidates) <= SCAN_MAX:
        return candidates
    sys.stderr.write(
        "answers.py: %d beads to check for %s, scanning the %d most recently updated "
        "(raise SPIRA_ANSWER_SCAN_MAX)\n" % (len(candidates), what, SCAN_MAX))
    return sorted(candidates, key=lambda r: r.get("updated_at") or "", reverse=True)[:SCAN_MAX]


def closed_by(cfg, ident):
    """The actor beads recorded for the most recent close of this bead, or None.

    `bd history --events` is the only place the closing actor exists; the issue row has no
    field for it. None means the audit trail could not be read, which is NOT the same as
    "somebody else closed it" -- the caller reports those separately rather than treating an
    unreadable trail as either an answer or a silence.
    """
    doc = bd(cfg, ["history", ident, "--events", "--json"])
    evs = rows_of(doc, "events")
    if not evs:
        return None
    closes = [e for e in evs if (e.get("event_type") or "") == "closed"]
    if not closes:
        return None
    closes.sort(key=lambda e: e.get("created_at") or "")
    return closes[-1].get("actor") or None


def verdicts(cfg, rows, mark):
    """Closes made BY THE OPERATOR since the mark. [(ts, id, title, reason), ...]"""
    ask, overseer = cfg["ask_label"], "overseer"
    cands = []
    for r in rows:
        if (r.get("status") or "") != "closed":
            continue
        labels = set(r.get("labels") or [])
        # An FYI is CREATED closed, so its close is never a verdict -- only its comments are.
        if "insight" in labels:
            continue
        if ask not in labels and overseer not in labels:
            continue
        ts = r.get("closed_at") or r.get("updated_at") or ""
        if not mark.is_new(ts, r.get("id") or ""):
            continue
        cands.append(r)

    out = []
    for r in cap(cands, "a verdict"):
        ident = r.get("id") or "?"
        if closed_by(cfg, ident) != cfg["operator_actor"]:
            continue
        reason = (r.get("close_reason") or "").strip() or "(closed with no reason given)"
        out.append((r.get("closed_at") or r.get("updated_at") or "",
                    ident, (r.get("title") or "")[:90], reason))
    out.sort()
    return out


def comments(cfg, rows, mark):
    """Comments written BY THE OPERATOR since the mark. [(ts, id, title, text), ...]

    Every bead that reaches the operator's attention surface is a candidate, FYIs included
    and whatever their status: the whole defect this closes is that an FYI is closed at birth
    and carries neither the escalation label nor a transition left to report.
    """
    ask = cfg["ask_label"]
    cands = [r for r in rows
             if ({"insight", ask, "overseer"} & set(r.get("labels") or []))
             and (r.get("comment_count") or 0) > 0]

    out = []
    for r in cap(cands, "a comment"):
        ident = r.get("id") or "?"
        thread = rows_of(bd(cfg, ["comments", ident, "--json"]), "comments")
        for c in thread:
            if (c.get("author") or "") != cfg["operator_actor"]:
                continue
            ts = c.get("created_at") or ""
            key = "%s/%s" % (ident, c.get("id") or ts)
            if not mark.is_new(ts, key):
                continue
            out.append((ts, ident, (r.get("title") or "")[:90],
                        (c.get("text") or "").strip(), key))
    out.sort()
    return out


def main():
    args = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
    cfg = {
        "bd": args.get("bd") or os.environ.get("BD_BIN") or "bd",
        "db": args.get("db") or os.environ.get("SPIRA_DB") or "",
        "ask_label": args.get("ask_label") or os.environ.get("SPIRA_ASK_LABEL") or "needs-operator",
        "operator_actor": (args.get("operator_actor")
                           or os.environ.get("SPIRA_OPERATOR_ACTOR") or "operator"),
    }
    who = (args.get("operator") or os.environ.get("SPIRA_OPERATOR") or "the operator").upper()
    fmt = args.get("format") or "monitor"
    now = args.get("now") or __import__("datetime").datetime.now(
        __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    rows = rows_of(json_only(sys.stdin.read()), "issues")

    vmark = Mark(args["verdict_cursor"]) if args.get("verdict_cursor") else None
    cmark = Mark(args["comment_cursor"]) if args.get("comment_cursor") else None

    # FIRST RUN SEEDS SILENTLY. Without this, arming a watcher replays every historical
    # answer as though it had just landed -- and a burst of stale verdicts is how a real one
    # goes unread.
    vs, cs = [], []
    if vmark is not None:
        if vmark.fresh():
            vmark.write([], now)
        else:
            vs = verdicts(cfg, rows, vmark)
            vmark.write([(t, i) for t, i, _, _ in vs], now)
    if cmark is not None:
        if cmark.fresh():
            cmark.write([], now)
        else:
            cs = comments(cfg, rows, cmark)
            cmark.write([(t, k) for t, _, _, _, k in cs], now)

    if fmt == "session":
        if not vs and not cs:
            return 0
        print("## %s spoke while you were away (%d)" % (who.title(), len(vs) + len(cs)))
        print()
        for ts, ident, title, reason in vs:
            print("- **verdict on `%s`** (%s) — %s" % (ident, ts[:16].replace("T", " "), title))
            print("  > %s" % reason.replace("\n", "\n  > "))
        for ts, ident, title, text, _ in cs:
            print("- **comment on `%s`** (%s) — %s" % (ident, ts[:16].replace("T", " "), title))
            print("  > %s" % text.replace("\n", "\n  > "))
        print()
        print("These are answers, already given. Act on them; do not re-ask. If one")
        print("generalises, enact it as a statute in this session.")
        return 0

    for ts, ident, title, reason in vs:
        print("%s ANSWERED %s — %s" % (who, ident, title), flush=True)
        print("  verdict: %s" % reason, flush=True)
    for ts, ident, title, text, _ in cs:
        print("%s COMMENTED ON %s — %s" % (who, ident, title), flush=True)
        for line in text.splitlines() or [""]:
            print("  %s" % line, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
