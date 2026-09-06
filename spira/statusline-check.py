#!/usr/bin/env python3
"""statusline-check.py — is the client's status line running the context meter, and on a timer?

    statusline-check.py <settings.json> <the meter's path>

Prints one line for doctor.sh to render, and never more than one:

    unreadable <why>    the settings file is not JSON we can parse
    absent              there is no status line at all
    other <interval>    a status line, but not this one
    ours <interval>     this meter, refreshing every <interval> seconds
    ours -              this meter, with NO refreshInterval

THE LAST OF THOSE IS THE WHOLE REASON THIS EXISTS. The status line is re-run on a session
starting, a new assistant message, a compaction finishing, a mode change and a refresh timer.
Clearing the session is not on that list. So with no timer the meter goes on showing the
discarded session's context until something is next said — the instrument that exists to say
whether clearing was worth doing, reporting that the clear did not work.

IT IS A SEPARATE FILE AND NOT A HEREDOC because doctor.sh renders its findings through shell
functions whose arguments are quoted prose, and JSON parsing nested inside that is where a
quoting mistake turns a check into a syntax error at the bottom of a file nobody re-reads.

READ-ONLY, like everything doctor.sh calls. This reports on a file outside every repository
that the harness may not write.
"""
import json
import sys


def main() -> None:
    settings, meter = sys.argv[1], sys.argv[2]
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
    print("%s %s" % ("ours" if meter in command else "other", interval))


main()
