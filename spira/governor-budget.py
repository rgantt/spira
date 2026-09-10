#!/usr/bin/env python3
"""
governor-budget.py — the arithmetic behind governor.sh: probes in, a budget out.

Split out of governor.sh so it can be run against fixtures; the shell half reads /proc and
this half decides. Input is environment, output is KEY=value lines governor.sh writes into
budget.env verbatim.

WHY THERE IS HISTORY IN IT. The first governor decided from one two-second sample of
/proc/stat taken every pass. Its own record showed budgets of 0, 1 and 2 within minutes of
each other at a constant aeon count, because a two-second window lands on or between a
gate's test suites at random — and a throttle that flips with the sampling instant is a
throttle nobody can tune. Two things fix that, in order:

  1. The reading is the idle fraction over the WHOLE interval since the last pass, from the
     cumulative counters in /proc/stat (STAT_* now against PREV_STAT_* then). That is the
     true average for those minutes, not a glance at two seconds of them. The two-second
     sample (SAMPLE_IDLE) is only the fallback for a first run, a counter reset, or a gap
     past MAX_INTERVAL seconds, when the previous counters describe some other era.
  2. The reading is folded into an exponentially weighted average (PREV_AVG, ALPHA), so one
     quiet or one loud interval moves the decision a step rather than a cliff.

HEADROOM, NOT A TOTAL. The old formula answered "how many aeons would fit in the idle CPU
right now" — which is a count of ADDITIONAL aeons, since the running ones are already in the
load — and lib.sh then treated it as a total cap and subtracted the running count again. The
more aeons ran, the more it would have withheld, whatever the box could bear. So HEADROOM is
how many more may start, and BUDGET is RUNNING + HEADROOM for readers that want a total.
An aeon costs PER_AEON points of idle (one core's worth by default); FLOOR is what must stay
free regardless.

Every breach — idle average under the floor, memory, disk, a busy CI runner — sets both to 0
and names itself, because a governor that withholds without saying why is a knob the reader
cannot find.
"""
import math
import os

def env(name, default=None):
    v = os.environ.get(name)
    return v if v not in (None, "") else default

def num(name, default=None):
    v = env(name)
    if v is None: return default
    try: return float(v)
    except ValueError: return default

now_total   = num("STAT_TOTAL"); now_idle = num("STAT_IDLE")
prev_total  = num("PREV_STAT_TOTAL"); prev_idle = num("PREV_STAT_IDLE")
prev_at     = num("PREV_AT"); now_at = num("NOW")
max_interval = num("MAX_INTERVAL", 900)
sample      = num("SAMPLE_IDLE")

# -- the reading: the interval average when the previous counters describe THIS era ------
idle = None; source = "none"
if None not in (now_total, now_idle, prev_total, prev_idle):
    dt = now_total - prev_total; di = now_idle - prev_idle
    age = (now_at - prev_at) if None not in (now_at, prev_at) else None
    if dt > 0 and 0 <= di <= dt and (age is None or 0 <= age <= max_interval):
        idle = 100.0 * di / dt; source = "interval"
if idle is None and sample is not None:
    idle = sample; source = "sample"

# -- the average: one step per pass, never a cliff ---------------------------------------
alpha = num("ALPHA", 0.25)
prev_avg = num("PREV_AVG")
if idle is None:
    avg = prev_avg
elif prev_avg is None:
    avg = idle
else:
    avg = prev_avg + alpha * (idle - prev_avg)

# -- the decision ----------------------------------------------------------------------
cores    = int(num("CORES", 1))
floor    = num("FLOOR", 25)
per_aeon = num("PER_AEON") or max(1.0, math.ceil(50.0 / max(cores, 1)))
running  = int(num("RUNNING", 0))
mem      = num("MEM_MB"); min_mem = num("MIN_MEM_MB", 1500)
disk_root = num("DISK_ROOT"); disk_ws = num("DISK_WS"); min_disk = num("MIN_DISK_PCT", 10)
ci_busy  = env("CI_BUSY", "0") == "1"
ws_path  = env("WS_PATH", "workspaces")

reason = "ok"; headroom = 0
if avg is None:
    # No reading at all. Fail closed-ish: one aeon, and say the probe is blind.
    headroom = 1 if running == 0 else 0; reason = "cpu probe unreadable"
elif avg < floor:
    reason = "cpu %.0f%% idle (avg), floor %.0f%%" % (avg, floor)
else:
    headroom = int((avg - floor) // per_aeon)
    if headroom == 0:
        reason = "no headroom: cpu %.0f%% idle (avg), floor %.0f%%, %.0f%% per aeon" % (avg, floor, per_aeon)

breach = None
if mem is not None and mem < min_mem:            breach = "only %dMB available" % mem
elif disk_root is not None and disk_root > 100 - min_disk: breach = "/ at %d%%" % disk_root
elif disk_ws is not None and disk_ws > 100 - min_disk:     breach = "%s at %d%%" % (ws_path, disk_ws)
elif ci_busy and headroom > 0:                   breach = "a CI runner is busy"
if breach:
    headroom = 0; reason = breach

budget = 0 if breach or (avg is not None and avg < floor) else running + headroom

print("IDLE=%s"       % ("?" if idle is None else "%.0f" % idle))
print("IDLE_SOURCE=%s" % source)
print("IDLE_AVG=%s"   % ("?" if avg is None else "%.1f" % avg))
print("HEADROOM=%d"   % headroom)
print("BUDGET=%d"     % budget)
print("PER_AEON=%.0f" % per_aeon)
print("REASON=%s"     % reason)
