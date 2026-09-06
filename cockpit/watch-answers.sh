#!/usr/bin/env bash
#
# watch-answers.sh — tell the session when the operator answers something.
#
# WHY THIS EXISTS. The operator answered an escalation in the cockpit pane with "take your
# default" and the session never noticed. They had to ask, hours later, whether a notification
# job was missing. It was.
#
# The regression was mine and it came from an improvement. The old panel wrote every reply
# to .runtime/replies.log and the session tailed that file. The from-scratch rewrite made
# beads the single source of truth -- `bd close --reason` IS the verdict now, which is the
# better data model -- but it deleted the write to replies.log and nothing replaced the
# notification leg. There is no replies.log on disk at all.
#
# The lesson is the one that keeps recurring here: an escalation queue has two halves, the
# ask and the answer, and only the ask had a mechanism. A verdict that reaches nobody is
# indistinguishable from an unanswered question -- and worse, the operator believes they have replied.
#
# Emits one line per event, so it is a Monitor command:
#   Monitor({command: '.claude/cockpit/watch-answers.sh', persistent: true})
#
# First run SEEDS SILENTLY. Without that, arming it would replay every historical verdict
# as if it had just landed.
set -uo pipefail

. "$(dirname "$0")/db.sh"
STATE="${ANSWER_STATE:-$(dirname "$0")/.runtime/answered-seen.json}"
INTERVAL="${ANSWER_POLL:-45}"

# WHICH DATABASE IS NOT THIS FILE'S TO DECIDE (db.sh). The first version read only the town.
# the operator then answered three escalations that live in another repository's database -- one of them
# "i have answered this multiple times already. JUST FUCKING DO IT." -- and this watcher said
# nothing, exactly the failure it was built to end. Five copies of that answer existed at one
# point, and correcting one of them was never going to correct the rest.
mkdir -p "$(dirname "$STATE")"

while true; do
  raw=$(cockpit_beads) || raw=""
  if [ -n "$raw" ]; then
    printf '%s' "$raw" | STATE="$STATE" BD_BIN="$BD" COCKPIT_DB="$COCKPIT_DB" \
      SELF_CLOSED="${SELF_CLOSED:-$(dirname "$0")/.runtime/self-closed}" python3 -c '
import json, os, sys
ASK = os.environ.get("SPIRA_ASK_LABEL", "needs-operator")

state_path = os.environ["STATE"]
text = sys.stdin.read()
i = min((text.find(c) for c in "[{" if text.find(c) >= 0), default=-1)
if i < 0:
    sys.exit(0)
try:
    doc = json.loads(text[i:])
except Exception:
    sys.exit(0)
rows = doc if isinstance(doc, list) else doc.get("issues", [])

try:
    with open(state_path) as fh:
        seen = json.load(fh)
    first_run = False
except Exception:
    seen, first_run = {}, True

self_closed = set()
try:
    with open(os.environ.get("SELF_CLOSED", "")) as fh:
        self_closed = {line.strip() for line in fh if line.strip()}
except Exception:
    pass

now = {}
events = []
for r in rows:
    labels = r.get("labels") or []
    # The escalation label is the one that MEANS "waiting on the operator" -- the one the gate defers on.
    # Requiring `overseer` too was wrong: an escalation filed inside a rig never carries it,
    # and that is how sixteen stayed invisible. Insights are records, not questions.
    # (No apostrophes in this block: it lives inside a single-quoted bash -c string.)
    # An insight is a record, not a question -- so its status never matters here. But a
    # COMMENT on one is the operator speaking, and skipping insights outright meant their reply could
    # not reach anyone. The operator once answered one with "yes, this seems worth a
    # fix" and it surfaced only because an unrelated test fixture happened to capture the
    # pane rendering it. Watch insights for comments alone.
    is_insight = "insight" in labels
    if not is_insight and ASK not in labels and "overseer" not in labels:
        continue
    rid = r.get("id")
    if not rid:
        continue
    status = r.get("status") or ""
    ccount = r.get("comment_count") or 0
    now[rid] = {"status": status, "comments": ccount, "insight": is_insight}
    prev = seen.get(rid)
    if first_run or prev is None:
        continue
    title = (r.get("title") or "")[:90]
    # An insight is CREATED closed, so a status transition on one is meaningless noise.
    # Only its comments are signal.
    if is_insight:
        if ccount > (prev.get("comments") or 0):
            events.append((rid, ccount, title))
        continue
    if prev.get("status") != "closed" and status == "closed":
        # Not if I closed it. A beads close records no actor -- there is no closed_by, and
        # the Dolt committer is always "beads" whatever BEADS_ACTOR says -- so resolve.sh
        # records the id and this skips it. Without that, the harness's own close came back
        # to me as "RYAN ANSWERED", which is the comment-path bug all over again.
        if rid in self_closed:
            continue
        reason = (r.get("close_reason") or "").strip() or "(no reason given)"
        events.append(f"RYAN ANSWERED {rid}: {reason}  --  {title}")
    elif ccount > (prev.get("comments") or 0):
        # Only if the newest comment is not mine. This session and the pane both wrote as
        # "overseer" at first, so the watcher announced my OWN reply back to me as "RYAN
        # COMMENTED" -- a notification loop with itself. Mine are authored "claude".
        events.append((rid, ccount, title))

tmp = state_path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(now, fh)
os.replace(tmp, state_path)

import subprocess
for ev in events:
    if isinstance(ev, str):
        print(ev, flush=True)
        continue
    rid, ccount, title = ev
    who = None
    try:
        out = subprocess.run(
            [os.environ.get("BD_BIN", "bd"),
             "-C", os.environ["COCKPIT_DB"],
             "comments", rid, "--json"],
            capture_output=True, text=True, timeout=30).stdout
        j = out[min((out.find(c) for c in "[{" if out.find(c) >= 0), default=0):]
        cs = json.loads(j)
        cs = cs if isinstance(cs, list) else cs.get("comments", [])
        who = cs[-1].get("author") if cs else None
    except Exception:
        who = None
    if who == "claude":
        continue          # my own reply; not news
    print(f"RYAN COMMENTED on {rid} ({ccount} total)  --  {title}", flush=True)
'
  fi
  sleep "$INTERVAL"
done
