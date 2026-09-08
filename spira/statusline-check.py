#!/usr/bin/env python3
"""statusline-check.py — is the client's status line running the context meter, and on a timer?

    statusline-check.py <settings.json> <the meter's path> [<SPIRA_RUN>]

Prints one line for doctor.sh to render, and never more than one:

    unreadable <why>           the settings file is not JSON we can parse
    absent                     there is no status line at all
    other <interval>           a status line with no recognisable meter
    fragile <path> <interval>  the command names a path under /tmp or a worktree
    stale <path> <interval>    a DIFFERENT COPY of ctx-meter.sh, with its path
    ours <interval>            this meter, refreshing every <interval> seconds
    ours -                     this meter, with NO refreshInterval

THE LAST OF THOSE IS THE WHOLE REASON THIS EXISTS. The status line is re-run on a session
starting, a new assistant message, a compaction finishing, a mode change and a refresh timer.
Clearing the session is not on that list. So with no timer the meter goes on showing the
discarded session's context until something is next said — the instrument that exists to say
whether clearing was worth doing, reporting that the clear did not work.

STALE IS THE FIX FOR sp-9ydp. A wrapper around a DIFFERENT COPY of the meter was classified
as `other` and doctor.sh rendered that as 'the context meter is not being shown', which was
false — the meter was being shown, from a worktree. The resolution reads one level of
indirection: if the command names a readable file, the paths inside it are extracted and
checked for ctx-meter.sh copies whose directory is not the landed meter's own.

FRAGILE catches the remaining case: a command that lives under /tmp (lost on reboot) or under
$SPIRA_RUN/worktree (deleted when the Sending reaps it). Neither is wrong per se, but both
deserve their own message rather than being lumped with `other`.

IT IS A SEPARATE FILE AND NOT A HEREDOC because doctor.sh renders its findings through shell
functions whose arguments are quoted prose, and JSON parsing nested inside that is where a
quoting mistake turns a check into a syntax error at the bottom of a file nobody re-reads.

READ-ONLY, like everything doctor.sh calls. This reports on a file outside every repository
that the harness may not write.
"""
import json
import os
import re
import sys


def _extract_paths(text):
    """Absolute paths mentioned in text."""
    return [m for m in re.findall(r'/[\w.+@:/-]+', text) if len(m) > 1]


def _resolve_paths(command, meter_basename):
    """The paths in the command and, one level deep, in any script it names.

    Returns (direct, all) where direct is the paths in the command itself and all includes
    paths found inside readable files the command names.  Files whose basename is already the
    meter are not read — they are what we are looking for, not wrappers to look inside.
    """
    direct = _extract_paths(command)
    resolved = list(direct)
    for p in direct:
        if os.path.basename(p) == meter_basename:
            continue
        try:
            if not os.path.isfile(p):
                continue
            if os.path.getsize(p) > 8192:
                continue
            with open(p) as fh:
                resolved.extend(_extract_paths(fh.read()))
        except OSError:
            pass
    return direct, resolved


def main() -> None:
    settings, meter = sys.argv[1], sys.argv[2]
    spira_run = sys.argv[3] if len(sys.argv) > 3 else ""
    try:
        with open(settings) as fh:
            conf = json.load(fh)
    except Exception as exc:                       # noqa: BLE001 — every failure reads the same
        print("unreadable %s" % exc)
        return
    line = conf.get("statusLine") if isinstance(conf, dict) else None
    if not isinstance(line, dict):
        print("absent")
        return
    command = line.get("command")
    command = command if isinstance(command, str) else ""
    interval = line.get("refreshInterval")
    # A BOOLEAN IS NOT AN INTERVAL, and in Python it would pass an isinstance check for int.
    # `"refreshInterval": true` is a plausible thing to type and would report as a configured
    # timer that the client does not honour.
    if isinstance(interval, bool) or not isinstance(interval, (int, float)):
        interval = "-"
    # SUBSTRING, NOT EQUALITY. The command is a shell fragment: it is commonly wrapped in an
    # interpreter, given arguments, or written as an absolute path with something before it.
    if meter in command:
        print("ours %s" % interval)
        return

    # Resolve the command: extract paths from its text and, one level deep, from any file it
    # names.  A wrapper like /tmp/sl2/rec.sh that pipes to a worktree's ctx-meter.sh is the
    # case this catches that a bare substring never could.
    meter_basename = os.path.basename(meter)
    meter_dir = os.path.dirname(meter)
    direct_paths, all_paths = _resolve_paths(command, meter_basename)

    # A path whose basename is ctx-meter.sh but whose directory is not the meter's own.
    for p in all_paths:
        if os.path.basename(p) == meter_basename and os.path.dirname(p) != meter_dir:
            print("stale %s %s" % (p, interval))
            return

    # A command path under /tmp or under the worktree directory.
    worktree_pfx = (spira_run.rstrip("/") + "/worktree") if spira_run else None
    for p in direct_paths:
        if worktree_pfx and (p.startswith(worktree_pfx + "/") or p == worktree_pfx):
            print("fragile %s %s" % (p, interval))
            return
        if p.startswith("/tmp/") or p == "/tmp":
            print("fragile %s %s" % (p, interval))
            return

    print("other %s" % interval)


main()
