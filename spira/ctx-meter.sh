#!/usr/bin/env bash
# ctx-meter.sh — how much context this session is carrying, and how close that is to the edge.
#
#   ctx-meter.sh          read the status-line hook on stdin, print one coloured line
#   ctx-meter.sh env      read no stdin, print SP_CTX_* key=value for the collector
#
# WHY. Context is re-read in full on every turn, so a long session costs many times a fresh one
# for identical work: measured on this project, a session starts near 50,000 tokens and every
# large one ends up pinned at ~1,000,000, with 53% of all spend happening in turns already
# carrying 600,000+. The number that decides whether to clear was invisible while it mattered.
#
# ONE DEFINITION, TWO READERS. The status line and the cockpit's TOKENS pane ask the same
# question and must not answer it differently — a dashboard that computes "context carried" by
# its own rule is a second opinion, not a view. So the measurement lives here once, the pane
# reads `env`, and the thresholds come from the config keys both of them resolve.
#
# IT READS THE TRANSCRIPT, NOT THE CONVERSATION. Claude Code hands a status-line command a JSON
# blob on stdin naming the transcript; the usage block on the last assistant turn already says
# exactly what that turn carried. So this costs the session nothing — no turn, no tokens — which
# is the whole point: an instrument that spends the thing it measures is useless at the moment
# you need it most.
#
# FALLBACK MATTERS. If stdin carries no transcript_path (a different Claude Code version, or a
# manual run), fall back to the newest transcript for this working directory. Printing nothing
# would be indistinguishable from "context is fine".
#
# `env` MODE MUST NOT READ STDIN. It runs from a collector, where stdin is whatever the parent
# happened to leave open — and a `cat` on an inherited terminal blocks forever, which presents
# as a collector that simply stopped writing its snapshot.
set -uo pipefail
# The thresholds are configuration, not constants, because they are a fact about the plan and
# the model rather than about this box. Sourced rather than defaulted inline so that the pane
# and the status line cannot drift apart.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"

MODE="${1:-line}"
IN=""
[ "$MODE" = "line" ] && IN="$(cat 2>/dev/null || true)"

python3 - "$IN" "$SPIRA_CTX_WARN" "$SPIRA_CTX_HIGH" "$SPIRA_CTX_LIMIT" \
              "$MODE" "$SPIRA_TOKEN_PROJECTS" "$SPIRA_RUN" <<'PY'
import json, sys, os, glob, time

raw, warn, high, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
mode, projects, run = sys.argv[5], sys.argv[6], sys.argv[7]
try: hook = json.loads(raw) if raw.strip() else {}
except Exception: hook = {}

tp = hook.get("transcript_path") or ""
if mode == "env":
    # NO HOOK, SO "THE LIVE SESSION" IS THE TRANSCRIPT BEING WRITTEN RIGHT NOW — the newest
    # across every project, not the one belonging to any particular directory. The collector
    # cannot know which project the operator is sitting in, and guessing one would report a
    # session that ended yesterday as though it were live. Its age is published alongside so
    # a stale answer is legible as stale rather than as calm.
    cands = glob.glob(os.path.join(projects, "*", "*.jsonl"))
    tp = max(cands, key=os.path.getmtime) if cands else ""
elif not tp or not os.path.exists(tp):
    cwd = (hook.get("workspace") or {}).get("current_dir") or hook.get("cwd") or os.getcwd()
    slug = cwd.replace("/", "-")
    cands = glob.glob(os.path.expanduser(f"~/.claude/projects/{slug}/*.jsonl"))
    tp = max(cands, key=os.path.getmtime) if cands else ""

ctx = turns = first = 0
prev = []
if tp:
    seen = set()
    try:
        with open(tp, errors="ignore") as fh:
            for ln in fh:
                if '"usage"' not in ln: continue
                try: o = json.loads(ln.strip())
                except Exception: continue
                m = o.get("message")
                if not isinstance(m, dict): continue
                u, mid = m.get("usage"), m.get("id")
                if not u or not mid or mid in seen: continue
                seen.add(mid); turns += 1
                c = (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)
                prev.append(c)
    except OSError:
        pass
if prev:
    ctx, first = prev[-1], prev[0]

# GROWTH IS THE ACTIONABLE HALF. A number that is merely large says less than one that is
# climbing, and it is the only way to turn headroom into "how many more turns".
growth_per_turn = 0
if len(prev) >= 21:
    growth_per_turn = max(0, (prev[-1] - prev[-21]) // 20)

# ---- the archivist state machine -------------------------------------------------------
# The archivist writes one small file per session as it works, and both modes render it.
# The states are its own: sweeping the transcript, archiving what it found, or done.
#
# "SAFE TO CLEAR" EXPIRES, and that is the whole subtlety. A verdict computed 40 turns ago is a
# statement about a session that no longer exists; clearing on it would discard everything said
# since. So the state records the turn it was computed at, and anything newer than that demotes
# it from "safe" to "safe as of N turns ago" — the operator can still act on it, but is never
# told that unpersisted work is safe to throw away.
state_dir = os.environ.get("SPIRA_RUN", "") or run or os.path.expanduser("~/.claude/spira")
sid = hook.get("session_id") or (os.path.basename(tp).rsplit(".", 1)[0] if tp else "")
arc_name, arc_behind, arc_filed = "", 0, "0"
try:
    with open(os.path.join(state_dir, "archivist", f"{sid}.state")) as fh:
        st = dict(l.strip().split("=", 1) for l in fh if "=" in l)
    arc_name = st.get("state", "")
    arc_filed = st.get("items_filed") or "0"
    arc_behind = max(0, turns - int(st.get("at_turn") or 0))
except FileNotFoundError:
    # No file is a real state, not an error: the archivist has not run for this session.
    arc_name = "none"
except Exception:
    arc_name = "?"

if mode == "env":
    # A READ THAT FOUND NOTHING SAYS SO. `-` is "no session is running", which is a true and
    # useful state; `?` is reserved for a probe that broke, and an exception here never reaches
    # this line — it exits non-zero and the collector writes `?` for the whole block. Zero would
    # be neither, and it reads as the best possible news.
    if not prev:
        for k in ("NOW", "TURNS", "GROWTH", "NEXT", "HEADROOM", "TURNS_LEFT", "AGE"):
            print(f"SP_CTX_{k}=-")
        print("SP_CTX_ARCHIVIST=-")
        print("SP_CTX_ARCHIVIST_BEHIND=-")
        raise SystemExit
    # THE NEXT THRESHOLD, not the ceiling. "248k to the limit" is true and useless when the
    # thing that actually happens next is crossing into the band where clearing is worth it.
    nxt, head = "over", 0
    for name, at in (("warn", warn), ("high", high), ("limit", limit)):
        if ctx < at:
            nxt, head = name, at - ctx
            break
    try: age = int(time.time() - os.path.getmtime(tp))
    except OSError: age = -1
    print(f"SP_CTX_NOW={ctx}")
    print(f"SP_CTX_TURNS={turns}")
    print(f"SP_CTX_GROWTH={growth_per_turn}")
    print(f"SP_CTX_NEXT={nxt}")
    print(f"SP_CTX_HEADROOM={head}")
    # Only meaningful while the session is growing. A flat session is not approaching anything,
    # and a fabricated "∞ turns left" would be a number where there is no measurement.
    print(f"SP_CTX_TURNS_LEFT={head // growth_per_turn if growth_per_turn > 0 else '-'}")
    print(f"SP_CTX_AGE={age}")
    print(f"SP_CTX_ARCHIVIST={arc_name or '-'}")
    print(f"SP_CTX_ARCHIVIST_BEHIND={arc_behind}")
    raise SystemExit

# A READ THAT FAILED SAYS SO. Zero would read as an empty context, which is the best possible
# news, and displacing suspicion is exactly what a broken gauge must not do.
if not prev:
    print("ctx ?"); raise SystemExit

def hue(v):
    return "\x1b[32m" if v < warn else ("\x1b[33m" if v < high else "\x1b[31m")
R = "\x1b[0m"
BLK = "▁▂▃▄▅▆▇█"
# The bar is against the ceiling every large session here has actually reached.
lvl = min(len(BLK) - 1, int(ctx / limit * len(BLK))) if limit > 0 else 0
k = f"{ctx/1000:.0f}k"
growth = f" +{growth_per_turn/1000:.1f}k/turn" if growth_per_turn > 0 else ""
if arc_name == "sweeping":
    arc = " \x1b[36m⟳ sweeping\x1b[0m"
elif arc_name == "archiving":
    arc = " \x1b[36m⇣ archiving\x1b[0m"
elif arc_name == "safe":
    if arc_behind <= 2:
        arc = f" \x1b[32m✓ safe to clear\x1b[0m \x1b[2m({arc_filed} filed)\x1b[0m"
    else:
        arc = f" \x1b[33m✓ safe as of {arc_behind}t ago\x1b[0m"
elif arc_name == "failed":
    arc = " \x1b[31m! archive failed\x1b[0m"
elif arc_name == "none":
    arc = " \x1b[2m· not archived\x1b[0m" if ctx >= warn else ""
elif arc_name == "?":
    arc = " \x1b[31m· archivist ?\x1b[0m"
else:
    arc = f" \x1b[2m{arc_name}\x1b[0m"

print(f"{hue(ctx)}{BLK[lvl]} ctx {k}{R} \x1b[2m/{turns}t{growth}{R}{arc}")
PY
