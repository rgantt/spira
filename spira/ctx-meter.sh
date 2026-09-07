#!/usr/bin/env bash
# ctx-meter.sh — how much context this session is carrying, how close that is to the edge, and
# how close the account's two rate-limit windows are to full.
#
#   ctx-meter.sh          read the status-line hook on stdin, print one coloured line
#   ctx-meter.sh env      read no stdin, print SP_CTX_*/SP_LIMIT_* key=value for the collector
#   ctx-meter.sh env <t>  the same, but about the transcript named rather than the newest
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
# THE HEADLINE COMES FROM THE CLIENT, NOT FROM THE TRANSCRIPT. The status-line hook already
# carries the answer on stdin as context_window.total_input_tokens, which the client defines as
# input_tokens + cache_creation_input_tokens + cache_read_input_tokens on the last API response,
# and against which it pre-computes context_window.used_percentage. Re-deriving that by parsing
# the transcript is a reimplementation of a supplied field that drifts the moment the client's
# definition moves — and it dropped the uncached input_tokens, so it read low. Where there is no
# hook (the `env` collector) the same three fields are summed off the transcript's last assistant
# turn, deliberately by the client's formula, so the two readers cannot disagree.
#
# THE TRANSCRIPT IS STILL READ, but only for what the hook does not carry: how many turns the
# session has run and how fast it is growing. That is why resolving it wrong is survivable for
# the headline and still not acceptable — a wrong transcript reports another session's history.
#
# IT COSTS THE SESSION NOTHING — no turn, no tokens — which is the whole point: an instrument
# that spends the thing it measures is useless at the moment you need it most.
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
              "$MODE" "$SPIRA_TOKEN_PROJECTS" "$SPIRA_RUN" "${2:-}" <<'PY'
import json, sys, os, glob, time, hashlib, re, math

raw, warn, high, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
mode, projects, run = sys.argv[5], sys.argv[6], sys.argv[7]
# The transcript a caller named, if it named one. `env` mode only; see below.
pick = sys.argv[8] if len(sys.argv) > 8 else ""
try: hook = json.loads(raw) if raw.strip() else {}
except Exception: hook = {}
if not isinstance(hook, dict): hook = {}

state_dir = run or os.path.expanduser("~/.claude/spira")

# ---- which transcript is THIS session's ------------------------------------------------
# THE HOOK NAMES A SESSION; HONOUR THE NAME. session_id is the session's identity, and the
# client writes that session to <project-dir>/<session_id>.jsonl, so composing the two is the
# only resolution that cannot land on somebody else's file. transcript_path is second because
# it is the same answer by a longer route. Newest-by-mtime is last and — the point of the
# ordering — is reached ONLY when the hook named no session at all: it answers "the most
# recently touched session in this project", which is not "this session". Two agents sharing
# one working directory share a project slug, so on that fallback the meter can silently
# report the other one's context, which is a confident wrong number rather than a missing one.
def slug(path):
    # The client's own project-directory rule: every character that is not a letter or a digit
    # becomes a hyphen. Only reached when the hook carried no transcript_path to take the
    # directory from, which no current client does.
    return re.sub(r"[^A-Za-z0-9]", "-", path)

sid = hook.get("session_id") or ""
hp  = hook.get("transcript_path") or ""
# NAMED means the hook identified a session. It is what separates "this session has not spoken
# yet" from "this program could not find out", and those must not render the same.
named = bool(sid or hp)

tp = ""
if mode == "env":
    # A NAMED TRANSCRIPT WINS, because a caller that named one is not asking about "the live
    # session" — the archivist's sweep walks every live session in turn, and answering each of
    # them with the newest on disk would report one session's context under every name.
    #
    # OTHERWISE, NO HOOK MEANS "THE LIVE SESSION" IS THE TRANSCRIPT BEING WRITTEN RIGHT NOW —
    # the newest across every project, not the one belonging to any particular directory. The
    # collector cannot know which project the operator is sitting in, and guessing one would
    # report a session that ended yesterday as though it were live. Its age is published
    # alongside so a stale answer is legible as stale rather than as calm.
    if pick:
        tp = pick
    else:
        cands = glob.glob(os.path.join(projects, "*", "*.jsonl"))
        tp = max(cands, key=os.path.getmtime) if cands else ""
else:
    cwd = (hook.get("workspace") or {}).get("current_dir") or hook.get("cwd") or os.getcwd()
    order = []
    if sid and hp: order.append(os.path.join(os.path.dirname(hp), sid + ".jsonl"))
    if hp:         order.append(hp)
    if sid:        order.append(os.path.join(projects, slug(cwd), sid + ".jsonl"))
    tp = next((c for c in order if os.path.exists(c)), "")
    if not tp and not named:
        cands = glob.glob(os.path.join(projects, slug(cwd), "*.jsonl"))
        tp = max(cands, key=os.path.getmtime) if cands else ""

# ---- turns and growth, read forward from where the last run stopped ---------------------
# A TRANSCRIPT IS APPEND-ONLY, so re-reading it whole on every run is work already done. That
# was affordable at one run per assistant message and is not at a refreshInterval of seconds:
# the pass is linear in the whole file, and a long session's transcript reaches tens of
# megabytes. The cursor — byte offset, turn count, and the tail the growth rate needs — is kept
# beside the archivist's state, so a steady-state run reads only what was appended since.
#
# THE CACHE MAY ONLY EVER MAKE THIS FASTER, NEVER DIFFERENT. It is keyed on the path, the inode
# and a digest of the file's opening bytes, and is discarded whenever the recorded offset is
# past the end of the file or anything about it fails to parse; every one of those falls back to
# reading from byte zero. The digest is what makes "append-only" a checked property rather than
# an assumption — a file rewritten in place keeps its inode and can regrow past the old offset,
# and resuming into that would count turns from two different sessions as one. A cursor that
# cannot be trusted is not consulted, because a wrong turn count would be indistinguishable
# from a real one.
#
# SCANNED BYTES ARE PUBLISHED so the saving is a measured fact rather than a hope: when this
# stops being a few kilobytes a pass, the incremental read has stopped working and the pane
# says so before the status line starts costing a core.
def scan(tp):
    """(turns, tail, scanned, broken) for a transcript — the tail being the last 21 turns' context."""
    KEEP = 21
    try: st = os.stat(tp)
    except OSError: return 0, [], 0, True
    off = turns = 0
    last = ""
    tail = []
    cur = os.path.join(state_dir, "ctx-meter",
                       hashlib.sha1(tp.encode("utf-8", "replace")).hexdigest()[:16] + ".cursor")
    try:
        with open(tp, "rb") as fh: head = hashlib.sha1(fh.read(256)).hexdigest()[:16]
    except OSError:
        return 0, [], 0, True
    try:
        with open(cur) as fh:
            c = dict(l.rstrip("\n").split("=", 1) for l in fh if "=" in l)
        if (c.get("path") == tp and c.get("head") == head
                and int(c["ino"]) == st.st_ino and 0 <= int(c["off"]) <= st.st_size):
            off, turns, last = int(c["off"]), int(c["turns"]), c.get("last", "")
            tail = [int(x) for x in c.get("tail", "").split(",") if x]
    except Exception:
        off, turns, last, tail = 0, 0, "", []

    start = off
    try:
        with open(tp, "rb") as fh:
            fh.seek(off)
            for ln in fh:
                # A HALF-WRITTEN LAST LINE IS NOT CONSUMED. The client appends while this runs,
                # so the final line may be a fragment; advancing the cursor past it would skip
                # the turn permanently once the rest of it lands.
                if not ln.endswith(b"\n"): break
                off += len(ln)
                if b'"usage"' not in ln: continue
                try: o = json.loads(ln)
                except Exception: continue
                m = o.get("message")
                if not isinstance(m, dict): continue
                u, mid = m.get("usage"), m.get("id")
                if not u or not mid or mid == last: continue
                # DE-DUPLICATED AGAINST THE PREVIOUS ROW, not against every row seen. One
                # assistant message is written as one row per content block, consecutively, so
                # the rows sharing an id are always adjacent — which is what lets the cursor
                # carry O(1) state instead of the whole set of ids seen so far.
                last = mid
                turns += 1
                # THE CLIENT'S OWN DEFINITION OF total_input_tokens, so that this fallback and
                # the supplied field are the same measurement rather than two similar ones.
                tail.append((u.get("input_tokens") or 0)
                            + (u.get("cache_creation_input_tokens") or 0)
                            + (u.get("cache_read_input_tokens") or 0))
                if len(tail) > KEEP: del tail[0]
    except OSError:
        return turns, tail, off - start, True

    if off != start or start == 0:
        try:
            os.makedirs(os.path.dirname(cur), exist_ok=True)
            tmp = cur + ".%d" % os.getpid()
            with open(tmp, "w") as fh:
                fh.write("path=%s\nino=%d\nhead=%s\noff=%d\nturns=%d\nlast=%s\ntail=%s\n"
                         % (tp, st.st_ino, head, off, turns, last,
                            ",".join(str(v) for v in tail)))
            os.replace(tmp, cur)
        except OSError:
            pass          # the cursor is an optimisation; losing it costs a full read, not truth
    return turns, tail, off - start, False

turns, tail, scanned, broken = scan(tp) if tp else (0, [], 0, not named)

# ---- the headline ----------------------------------------------------------------------
# THE SUPPLIED FIELD WINS. current_usage is documented null until the first API response, and
# that null is the fresh-session signal — the one case where there is genuinely no measurement
# to report and 0 would be a number nobody took.
cw = hook.get("context_window")
ctx = None
if isinstance(cw, dict) and cw.get("current_usage") is not None:
    v = cw.get("total_input_tokens")
    if isinstance(v, (int, float)) and not isinstance(v, bool): ctx = int(v)
if ctx is None and tail: ctx = tail[-1]

# GROWTH IS THE ACTIONABLE HALF. A number that is merely large says less than one that is
# climbing, and it is the only way to turn headroom into "how many more turns".
growth_per_turn = 0
if len(tail) >= 21:
    growth_per_turn = max(0, (tail[-1] - tail[0]) // 20)

# ---- the archivist state machine -------------------------------------------------------
# The archivist writes one small file per session as it works, and both modes render it.
# The states are its own: sweeping the transcript, archiving what it found, or done.
#
# "SAFE TO CLEAR" EXPIRES, and that is the whole subtlety. A verdict computed 40 turns ago is a
# statement about a session that no longer exists; clearing on it would discard everything said
# since. So the state records the turn it was computed at, and anything newer than that demotes
# it from "safe" to "safe as of N turns ago" — the operator can still act on it, but is never
# told that unpersisted work is safe to throw away.
akey = sid or (os.path.basename(tp).rsplit(".", 1)[0] if tp else "")
arc_name, arc_behind, arc_filed = "", 0, "0"
try:
    with open(os.path.join(state_dir, "archivist", f"{akey}.state")) as fh:
        st = dict(l.strip().split("=", 1) for l in fh if "=" in l)
    arc_name = st.get("state", "")
    arc_filed = st.get("items_filed") or "0"
    arc_behind = max(0, turns - int(st.get("at_turn") or 0))
except FileNotFoundError:
    # No file is a real state, not an error: the archivist has not run for this session.
    arc_name = "none"
except Exception:
    arc_name = "?"

# ---- the two windows that actually stop work --------------------------------------------
# CONTEXT SAYS WHEN TO CLEAR; THESE SAY WHETHER THERE IS ANYTHING LEFT TO CLEAR INTO. The
# 5-hour and 7-day rate-limit windows are what ends a working day outright, and neither was
# visible anywhere while it mattered.
#
# THE CLIENT SUPPLIES THEM AND NOTHING HERE DERIVES THEM. `rate_limits.{five_hour,seven_day}.
# {used_percentage,resets_at}` arrive on the same stdin blob as `context_window` — percentages
# 0-100, `resets_at` in epoch seconds. A window is absent before the session's first API
# response, absent on a login the limits do not apply to, and dropped once its own `resets_at`
# passes; each is independently absent. So MISSING RENDERS AS NOTHING, never as 0 — a window
# shown at 0% is the best possible news, and it would be news nobody measured.
#
# A RATE NEEDS HISTORY AND THE HOOK HAS NONE. Every invocation sees one instant, so the samples
# are persisted beside the cursor and the slope is read back off them. They are ACCOUNT-WIDE,
# not per-session: every session on the account is charged against the same two windows, which
# is what lets `env` — which has no hook at all — answer from the newest sample any session
# wrote.
LIM_TAU = 15.0        # minutes; the time constant the operator asked the projection to smooth over
LIM_KEEP = 1800       # seconds of samples retained — the trailing half hour the EMA can reach
# The colour bands are percentages of a window that is 100% on every box, so unlike the context
# thresholds they are not a fact about one operator's plan and are not a config key.
LIM_WARN, LIM_HIGH = 70.0, 90.0

def _now():
    # SPIRA_NOW IS THE TEST CLOCK, and it is deliberately absent from SPIRA_CONF_KEYS: a config
    # file cannot pin the clock of a live installation, only a caller that exports it on purpose
    # can. A frozen clock in production would make every projection a projection from a moment
    # that has passed.
    v = os.environ.get("SPIRA_NOW", "")
    try:
        return int(v) if v else int(time.time())
    except ValueError:
        return int(time.time())

now = _now()
lim_path = os.path.join(state_dir, "limits.samples")

def limits_win(o):
    """One window off the hook, or None if it is absent or not the shape documented."""
    if not isinstance(o, dict): return None
    p, r = o.get("used_percentage"), o.get("resets_at")
    if isinstance(p, bool) or isinstance(r, bool): return None
    if not isinstance(p, (int, float)) or not isinstance(r, (int, float)): return None
    if not 0 <= p <= 100: return None
    return (float(p), int(r))

def limits_hook(h):
    """(now, five_hour, seven_day) for this instant, or None when the client sent no window."""
    rl = h.get("rate_limits")
    if not isinstance(rl, dict): return None
    five, seven = limits_win(rl.get("five_hour")), limits_win(rl.get("seven_day"))
    if five is None and seven is None: return None
    return (now, five, seven)

def limits_fmt(s):
    def w(x): return "- -" if x is None else "%g %d" % x
    return "%d %s %s\n" % (s[0], w(s[1]), w(s[2]))

def limits_parse(ln):
    f = ln.split()
    if len(f) != 5: raise ValueError(ln)
    def w(a, b):
        if f[a] == "-" and f[b] == "-": return None
        return (float(f[a]), int(f[b]))
    return (int(f[0]), w(1, 2), w(3, 4))

def limits_load(path):
    """(samples oldest-first, broken). Absent is not broken: it is "no sample yet"."""
    try:
        with open(path) as fh: raw = fh.read()
    except FileNotFoundError:
        return [], False
    except OSError:
        return [], True
    out = []
    for ln in raw.splitlines():
        if not ln.strip(): continue
        try: out.append(limits_parse(ln))
        except Exception:
            # THE WHOLE FILE IS REFUSED, not the bad line. It is written by rename, so it is
            # never half-written; a line that does not parse means the file is not ours, and
            # computing a rate off the remainder would be a confident number from a source we
            # have just proved we cannot read.
            return [], True
    out.sort(key=lambda s: s[0])
    return out, False

def limits_record(path, samples, sample):
    """Prune, append, write by rename. Returns the list as it now stands on disk."""
    keep = [s for s in samples if sample[0] - s[0] <= LIM_KEEP]
    # A RUN OF IDENTICAL SAMPLES IS KEPT AS ITS TWO ENDPOINTS. At a five-second refresh, with
    # more than one session on the account, a half hour is many hundreds of lines and nearly
    # all of them repeat the previous reading. The FIRST endpoint is when the value was
    # reached, which is what the slope is measured from; the LAST is that it is still current,
    # which is what the age is measured from. Collapsing a run to a single line would make a
    # flat account read as a stale one.
    if len(keep) >= 2 and keep[-1][1:] == sample[1:] and keep[-2][1:] == sample[1:]:
        keep[-1] = sample
    else:
        keep.append(sample)
    keep.sort(key=lambda s: s[0])
    # WRITTEN WHOLE, THEN RENAMED, under a name carrying this process's pid. Two sessions on
    # one account run this hook against one file, and a reader must never see a partial one.
    # Rename does not prevent a lost update — the loser's sample is simply dropped — and that
    # is acceptable here in a way a torn file is not: both writers are reporting the SAME
    # account-wide reading, so the sample lost is one the winner also recorded.
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.%d" % (path, os.getpid())
        with open(tmp, "w") as fh:
            for s in keep: fh.write(limits_fmt(s))
        os.replace(tmp, path)
    except OSError:
        pass          # the samples are an instrument; losing them costs a projection, not truth
    return keep

def limits_rate(samples, idx):
    """EMA of percent-per-minute for one window, or None when there is nothing to measure."""
    pts = [(s[0], s[idx][0]) for s in samples if s[idx] is not None]
    if len(pts) < 2: return None
    # A DROP OF MORE THAN A POINT IS THE WINDOW RESETTING, not usage falling, so everything
    # before it belongs to a window that no longer exists. Averaging across the boundary would
    # produce a large negative slope and, with it, no projection at exactly the moment a fresh
    # window starts filling. One point of slack, because a percentage is reported rounded.
    start = 0
    for i in range(1, len(pts)):
        if pts[i][1] < pts[i - 1][1] - 1.0: start = i
    pts = pts[start:]
    if len(pts) < 2: return None
    # IRREGULAR INTERVALS ARE WEIGHTED BY THEIR OWN LENGTH. The hook fires on a refresh timer,
    # on every assistant message, and not at all while nothing is happening, so the gap between
    # two samples is five seconds or five minutes. α = 1 − exp(−Δt/τ) is what makes both carry
    # the weight they have earned; a fixed α would let a burst of five-second samples pin the
    # average to the last few seconds of a session.
    ema = None
    for (t0, p0), (t1, p1) in zip(pts, pts[1:]):
        dt = (t1 - t0) / 60.0
        if dt <= 0: continue
        slope = (p1 - p0) / dt
        ema = slope if ema is None else ema + (1.0 - math.exp(-dt / LIM_TAU)) * (slope - ema)
    return ema

def limits_dur(m):
    """Minutes as the coarsest unit that still says something: 48m, 1h20m, 3d."""
    m = max(0, int(round(m)))
    if m < 60: return "%dm" % m
    h, mm = divmod(m, 60)
    if h < 24: return "%dh%dm" % (h, mm) if mm else "%dh"
    return "%dd" % (h // 24)

lim_samples, lim_broken = limits_load(lim_path)
lim_hook = limits_hook(hook) if mode != "env" else None
if lim_hook is not None:
    # A CORRUPT FILE IS REPLACED RATHER THAN APPENDED TO. Its contents cannot be recovered and
    # the hook in hand is authoritative, so the repair is to start again from it — otherwise
    # one bad write leaves `env` answering `?` forever with nothing able to clear it.
    lim_samples = limits_record(lim_path, [] if lim_broken else lim_samples, lim_hook)
    lim_broken = False

def limits_env_lines():
    keys = ("5H_PCT", "5H_ETA", "7D_PCT", "7D_ETA", "AGE")
    # `?` IS A PROBE THAT BROKE AND `-` IS ONE THAT FOUND NOTHING, and neither is 0. No sample
    # yet is a true state — no session on this account has spoken since the harness started —
    # and an unreadable file is a fault. Rendering both as 0% would report a fault as the best
    # possible news (law-absence-needs-a-positive-control).
    if lim_broken: return ["SP_LIMIT_%s=?" % k for k in keys]
    if not lim_samples: return ["SP_LIMIT_%s=-" % k for k in keys]
    newest = lim_samples[-1]
    out = []
    for idx, short in ((1, "5H"), (2, "7D")):
        w = newest[idx]
        if w is None:
            out += ["SP_LIMIT_%s_PCT=-" % short, "SP_LIMIT_%s_ETA=-" % short]
            continue
        pct = w[0]
        out.append("SP_LIMIT_%s_PCT=%g" % (short, pct))
        rate = limits_rate(lim_samples, idx)
        # SECONDS UNTIL THE WINDOW IS FULL, or `-` when nothing is climbing. Never a fabricated
        # infinity, and 0 only where 0 is the measurement — a window already at 100% is full
        # now, which is a fact, whereas `-` means there was nothing to measure. A reader that
        # also needs "resets first" reads `resets_at` out of the sample file, which is the
        # published surface for the raw fields.
        if pct >= 100:
            out.append("SP_LIMIT_%s_ETA=0" % short)
        elif rate is not None and rate > 0:
            out.append("SP_LIMIT_%s_ETA=%d" % (short, (100 - pct) / rate * 60))
        else:
            out.append("SP_LIMIT_%s_ETA=-" % short)
    out.append("SP_LIMIT_AGE=%d" % max(0, now - newest[0]))
    return out

def limits_segment():
    """The rendered segment, or "" when the client sent no window."""
    if lim_hook is None: return ""
    segs = []
    for idx, short in ((1, "5h"), (2, "7d")):
        w = lim_hook[idx]
        if w is None: continue
        pct, reset = w
        col = "\x1b[32m" if pct < LIM_WARN else ("\x1b[33m" if pct < LIM_HIGH else "\x1b[31m")
        rate = limits_rate(lim_samples, idx)
        ttr = (reset - now) / 60.0                   # minutes until the window empties itself
        clause = ""
        if pct >= 100:
            # ALREADY FULL, which is the one state with nothing left to project and the one
            # where the reset is the only number that helps. Rendering nothing here would make
            # the meter go quiet at exactly the moment it matters most.
            if ttr > 0: clause = " \x1b[31mresets in %s\x1b[0m" % limits_dur(ttr)
        elif rate is not None and rate > 0:
            eta = (100 - pct) / rate                 # minutes until the window is full
            if ttr <= 0 or eta < ttr:
                # THE WARNING, and the only place the rate is shown: it is what justifies the
                # claim. Red under an hour, because that is when it changes what to do next.
                cc = "\x1b[31m" if eta < 60 else "\x1b[2m"
                clause = " \x1b[2m↑%.1f%%/h\x1b[0m %sfull in ~%s\x1b[0m" % (
                    rate * 60, cc, limits_dur(eta))
            else:
                # The window empties before it fills, so the limit will not bite this time and
                # the rate is not something to act on.
                clause = " \x1b[2mresets in %s\x1b[0m" % limits_dur(ttr)
        segs.append("%s%s %g%%\x1b[0m%s" % (col, short, pct, clause))
    return "".join(" \x1b[2m·\x1b[0m %s" % s for s in segs)

if mode == "env":
    # A READ THAT FOUND NOTHING SAYS SO. `-` is "no session is running", which is a true and
    # useful state; `?` is reserved for a probe that broke, and an exception here never reaches
    # this line — it exits non-zero and the collector writes `?` for the whole block. Zero would
    # be neither, and it reads as the best possible news.
    if ctx is None:
        for k in ("NOW", "TURNS", "GROWTH", "NEXT", "HEADROOM", "TURNS_LEFT", "AGE"):
            print(f"SP_CTX_{k}=-")
        print("SP_CTX_ARCHIVIST=-")
        print("SP_CTX_ARCHIVIST_BEHIND=-")
        print("SP_CTX_ARCHIVIST_FILED=-")
        print(f"SP_CTX_SCAN_BYTES={scanned}")
        # THE WINDOWS ARE PUBLISHED EVEN WITH NO SESSION TO REPORT ON. They are account-wide,
        # not a property of whichever transcript this pass resolved, so "no live session" says
        # nothing about how full the 5-hour window is — and a collector reading `-` for both
        # here would report an account at its limit as an idle one.
        for _l in limits_env_lines(): print(_l)
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
    # HOW MUCH WAS RESCUED, which is the difference between "the sweep ran" and "the sweep was
    # worth running". A pane reporting only that the archivist finished cannot distinguish a
    # session with nothing left to save from one whose fourteen loose ends are now beads.
    print(f"SP_CTX_ARCHIVIST_FILED={arc_filed}")
    # HOW MUCH OF THE TRANSCRIPT THIS PASS HAD TO READ. The incremental cursor is what keeps a
    # five-second status line off the CPU, and a cursor that has quietly stopped working looks
    # exactly like one that is working. This is the number that tells them apart.
    print(f"SP_CTX_SCAN_BYTES={scanned}")
    for _l in limits_env_lines(): print(_l)
    raise SystemExit

# THREE OUTCOMES, NOT TWO. A session the hook named but that has not spoken yet is FRESH — a
# true state, and the one the operator sees for a few seconds after every clear. A gauge that
# cannot read at all is `?`. Neither is 0, and neither is the previous session's number: zero
# context is the best possible news and a stale number is worse, because both displace exactly
# the suspicion that would have prompted a look.
if ctx is None:
    print(("\x1b[2m· ctx fresh\x1b[0m" if named and not broken else "ctx ?") + limits_segment())
    raise SystemExit

def hue(v):
    return "\x1b[32m" if v < warn else ("\x1b[33m" if v < high else "\x1b[31m")
R = "\x1b[0m"
BLK = "▁▂▃▄▅▆▇█"
# The bar is against the ceiling every large session here has actually reached. That is the
# configured limit and not the hook's context_window_size, which is the model's ceiling: the
# thresholds are a fact about the operator's plan, and they are shared with the pane, which
# has no hook to read a per-model size from.
lvl = min(len(BLK) - 1, int(ctx / limit * len(BLK))) if limit > 0 else 0
k = f"{ctx/1000:.0f}k"
growth = f" +{growth_per_turn/1000:.1f}k/turn" if growth_per_turn > 0 else ""
turned = f"/{turns}t" if turns else ""
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

print(f"{hue(ctx)}{BLK[lvl]} ctx {k}{R} \x1b[2m{turned}{growth}{R}{arc}{limits_segment()}")
PY
