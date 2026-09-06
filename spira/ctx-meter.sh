#!/usr/bin/env bash
# ctx-meter.sh — how much context this session is carrying, for the status line.
#
# WHY. Context is re-read in full on every turn, so a long session costs many times a fresh one
# for identical work: measured on this project, a session starts near 50,000 tokens and every
# large one ends up pinned at ~1,000,000, with 53% of all spend happening in turns already
# carrying 600,000+. The number that decides whether to clear was invisible while it mattered.
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
set -uo pipefail
IN="$(cat 2>/dev/null || true)"
python3 - "$IN" "${CTX_WARN:-200000}" "${CTX_HIGH:-400000}" <<'PY'
import json, sys, os, glob

raw, warn, high = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try: hook = json.loads(raw) if raw.strip() else {}
except Exception: hook = {}

tp = hook.get("transcript_path") or ""
if not tp or not os.path.exists(tp):
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

# A READ THAT FAILED SAYS SO. Zero would read as an empty context, which is the best possible
# news, and displacing suspicion is exactly what a broken gauge must not do.
if not prev:
    print("ctx ?"); raise SystemExit

def hue(v):
    return "\x1b[32m" if v < warn else ("\x1b[33m" if v < high else "\x1b[31m")
R = "\x1b[0m"
BLK = "▁▂▃▄▅▆▇█"
# The bar is against the 1M ceiling every large session here has actually reached.
lvl = min(len(BLK) - 1, int(ctx / 1_000_000 * len(BLK)))
k = f"{ctx/1000:.0f}k"
growth = ""
if len(prev) >= 21:
    d = (prev[-1] - prev[-21]) // 20
    if d > 0: growth = f" +{d/1000:.1f}k/turn"
# ---- the archivist state machine -------------------------------------------------------
# The archivist (sp-cxh) writes one small file per session as it works, and this renders it.
# The states are its own: sweeping the transcript, archiving what it found, or done.
#
# "SAFE TO CLEAR" EXPIRES, and that is the whole subtlety. A verdict computed 40 turns ago is a
# statement about a session that no longer exists; clearing on it would discard everything said
# since. So the state records the turn it was computed at, and anything newer than that demotes
# it from "safe" to "safe as of N turns ago" — the operator can still act on it, but is never
# told that unpersisted work is safe to throw away.
state_dir = os.environ.get("SPIRA_RUN", "") or os.path.expanduser("~/.claude/spira")
sid = hook.get("session_id") or os.path.basename(tp).rsplit(".", 1)[0]
arc = ""
try:
    with open(os.path.join(state_dir, "archivist", f"{sid}.state")) as fh:
        st = dict(l.strip().split("=", 1) for l in fh if "=" in l)
    name = st.get("state", "")
    at = int(st.get("at_turn") or 0)
    filed = st.get("items_filed") or "0"
    behind = max(0, turns - at)
    if name == "sweeping":
        arc = " \x1b[36m⟳ sweeping\x1b[0m"
    elif name == "archiving":
        arc = f" \x1b[36m⇣ archiving\x1b[0m"
    elif name == "safe":
        if behind <= 2:
            arc = f" \x1b[32m✓ safe to clear\x1b[0m \x1b[2m({filed} filed)\x1b[0m"
        else:
            arc = f" \x1b[33m✓ safe as of {behind}t ago\x1b[0m"
    elif name == "failed":
        arc = " \x1b[31m! archive failed\x1b[0m"
    elif name:
        arc = f" \x1b[2m{name}\x1b[0m"
except FileNotFoundError:
    # No file is a real state, not an error: the archivist has not run for this session.
    arc = " \x1b[2m· not archived\x1b[0m" if ctx >= warn else ""
except Exception:
    arc = " \x1b[31m· archivist ?\x1b[0m"

print(f"{hue(ctx)}{BLK[lvl]} ctx {k}{R} \x1b[2m/{turns}t{growth}{R}{arc}")
PY
