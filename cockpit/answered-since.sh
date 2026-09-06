#!/usr/bin/env bash
#
# answered-since.sh — at session start, report the verdicts the operator gave while nobody was home.
#
# WHY. watch-answers.sh only runs inside a live session. the operator answers from their
# phone and from the cockpit pane at hours when no session exists, and a verdict delivered
# to nobody is worse than an unanswered question: they believe they have replied, and the next
# session cheerfully re-asks. One sat answered ("take your default") until the operator asked why
# nothing had happened.
#
# The SessionStart hook already reports what is still OPEN for the operator. This is its other half.
#
# Prints only what closed since the LAST time it ran, so a verdict is announced once rather
# than every session for a day. The marker is written even when there is nothing to say.
set -uo pipefail

. "$(dirname "$0")/db.sh"
MARK="${ANSWER_MARK:-$(dirname "$0")/.runtime/answered-mark}"

mkdir -p "$(dirname "$MARK")"
since=$(cat "$MARK" 2>/dev/null || echo "")

raw=$(cockpit_beads) || exit 0
printf '%s' "$raw" | SINCE="$since" MARK="$MARK" python3 -c '
import json, os, sys, datetime
ASK = os.environ.get("SPIRA_ASK_LABEL", "needs-operator")

since = os.environ.get("SINCE") or ""
try:
    doc = json.loads(sys.stdin.read())
    rows = doc if isinstance(doc, list) else doc.get("issues", [])
except Exception:
    rows = []

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
# First ever run: record the mark and say nothing, rather than replaying all history.
if not since:
    with open(os.environ["MARK"], "w") as fh:
        fh.write(now)
    sys.exit(0)

out = []
for r in rows:
    labels = r.get("labels") or []
    # The escalation label is the one that MEANS "waiting on the operator" -- the one the gate defers on.
    # Requiring `overseer` too was wrong: an escalation filed inside a rig never carries it,
    # and that is how sixteen stayed invisible. Insights are records, not questions.
    # (No apostrophes in this block: it lives inside a single-quoted bash -c string.)
    if "insight" in labels:
        continue
    if ASK not in labels and "overseer" not in labels:
        continue
    if (r.get("status") or "") != "closed":
        continue
    closed = r.get("closed_at") or ""
    if not closed or closed <= since:
        continue
    reason = (r.get("close_reason") or "").strip() or "(no reason given)"
    out.append((closed, r.get("id"), (r.get("title") or "")[:80], reason))

with open(os.environ["MARK"], "w") as fh:
    fh.write(now)

if out:
    out.sort()
    print("## the operator answered while you were away (%d)" % len(out))
    print()
    for closed, rid, title, reason in out:
        print("- **%s** (`%s`, %s) — %s" % (reason, rid, closed[:16].replace("T", " "), title))
    print()
    print("These are verdicts, already given. Act on them; do not re-ask. If one generalises,")
    print("enact it as a statute with .claude/rule.sh in this session.")
'
