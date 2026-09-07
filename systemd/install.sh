#!/usr/bin/env bash
# install.sh — render the unit TEMPLATES for this box, install them, and start their timers.
#
#   ./install.sh          render, install, enable and start
#   ./install.sh --diff   show how the installed units differ from what this box would
#                         render, and change nothing
#   ./install.sh --render show the rendered units on stdout and change nothing
#
# THE FILES HERE ARE TEMPLATES, NOT UNITS. Every path in them is a placeholder — @SPIRA_HOME@,
# @SPIRA_DB@ and so on — filled from spira.conf. A unit file with a path baked into it runs on
# exactly one box, and systemd gives no clue when the path is wrong: a Documentation= line
# nobody reads and an ExecStart= that fails with a bare "No such file or directory" into a
# journal nobody is watching.
#
# NEVER EDIT AN INSTALLED UNIT. Edit the template and re-run this; `--diff` is how you find
# out that somebody did. The copies here are the source of truth, because
# ~/.config/systemd/user is one directory on one disk that nothing backs up.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$(cd "$SRC/../spira" && pwd -P)/conf.sh"
DEST="$HOME/.config/systemd/user"

UNITS=(spira-sentinel.service spira-sentinel.timer
       spira-ops.service spira-ops.timer
       spira-skew.service spira-skew.timer
       spira-archivist.service spira-archivist.timer
       spira-cockpit.service
       spira-watch@.service
       cockpit-ensure.service cockpit-ensure.timer
       concierge.service concierge.timer
       beads-push.service beads-push.timer
       spira-archive.service spira-archive.timer
       spira-gate-full.service spira-gate-full.timer)
# Only these get enabled. The .service behind a .timer is started BY the timer; enabling it
# as well would also run it once at boot, outside the schedule.
ENABLE=(cockpit-ensure.timer concierge.timer
        beads-push.timer spira-sentinel.timer spira-ops.timer spira-skew.timer
        spira-archive.timer
        spira-archivist.timer
        spira-gate-full.timer
        spira-cockpit.service)

# dolt-beads.service supervises the Dolt server itself, which is only this harness's business
# when the operator says so. Empty SPIRA_DOLT_DATA means they run the server their own way,
# and installing a unit that would fight them is worse than not installing one.
if [ -n "$SPIRA_DOLT_DATA" ]; then
    UNITS+=(dolt-beads.service); ENABLE+=(dolt-beads.service)
else
    echo "note: SPIRA_DOLT_DATA is empty — not installing dolt-beads.service." >&2
    echo "      Start your Dolt server yourself, or set it in ${SPIRA_CONF_FILE:-spira.conf}." >&2
fi

# `dolt` is resolved once, absolutely, because a systemd unit has no PATH worth the name.
DOLT="$(command -v dolt 2>/dev/null || true)"

# ONE INSTANCE PER `daemon` ROW, AND THE MANIFEST DECIDES WHICH. `log` rows name a file
# something else already writes, so they get no unit; enabling one would double up whatever
# is already producing it.
#
# A MALFORMED MANIFEST STOPS THE INSTALL, and it stops it HERE — before a single unit is
# rendered — so a refusal leaves the box as it was rather than half installed. Enabling the
# rows that happened to parse would be worse than refusing: a watcher that was never started
# looks exactly like a watcher with nothing to say, and this is the last moment anybody is
# looking (law-absence-needs-a-positive-control).
if watch_list="$("$SPIRA_HOME/watchd.sh" units)"; then
    watch_units=" "
    for u in $watch_list; do ENABLE+=("$u"); watch_units="$watch_units$u "; done
else
    echo "install: the watcher manifest is malformed — installing none of it" >&2
    exit 1
fi

# render <template> -> the unit for this box, on stdout.
#
# The substitution is done by a program, not by `sed s|@X@|$X|`: a value containing a `|`,
# an `&` or a backslash would be interpreted by sed, and these values are paths an operator
# typed. An UNSUBSTITUTED placeholder is a hard failure rather than a line shipped with an
# `@NAME@` in it, which systemd would accept and then fail on at the worst moment.
# HANDED IN, NOT INHERITED. conf.sh deliberately does not export anything derived from where
# it sits — SPIRA_HOME and its children differ per copy of the harness — so this passes them
# on argv rather than reading an environment that will not have them.
render() {
    python3 - "$1" "$SPIRA_HOME" "$SPIRA_REPO" "$SPIRA_RUN" "$SPIRA_DB" "$SPIRA_COCKPIT" \
                   "$SPIRA_DOLT_DATA" "$DOLT" <<'PY'
import os, re, sys
keys = ["SPIRA_HOME", "SPIRA_REPO", "SPIRA_RUN", "SPIRA_DB", "SPIRA_COCKPIT",
        "SPIRA_DOLT_DATA", "DOLT"]
m = dict(zip(keys, sys.argv[2:]))
text = open(sys.argv[1]).read()
out = re.sub(r"@([A-Z_]+)@", lambda x: m.get(x.group(1), x.group(0)), text)
left = sorted(set(re.findall(r"@([A-Z_]+)@", out)))
if left:
    sys.stderr.write("install: %s has placeholders nothing fills: %s\n"
                     % (os.path.basename(sys.argv[1]), ", ".join(left)))
    raise SystemExit(1)
sys.stdout.write(out)
PY
}

if [ "${1:-}" = "--render" ]; then
    for u in "${UNITS[@]}"; do printf '===== %s =====\n' "$u"; render "$SRC/$u" || exit 1; done
    exit 0
fi

if [ "${1:-}" = "--diff" ]; then
    rc=0
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    for u in "${UNITS[@]}"; do
        render "$SRC/$u" > "$TMP/$u" || { rc=1; continue; }
        if [ ! -f "$DEST/$u" ]; then echo "MISSING  $u (not installed)"; rc=1; continue; fi
        if ! diff -q "$TMP/$u" "$DEST/$u" >/dev/null; then
            echo "DIFFERS  $u"; diff -u "$TMP/$u" "$DEST/$u" | sed 's/^/    /'; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "installed units match what this box renders"
    exit "$rc"
fi

mkdir -p "$DEST"

# THE RUNTIME DIRECTORY, BEFORE ANY UNIT STARTS. `.runtime/` is gitignored — it holds logs,
# leases, worktrees and the cockpit snapshot, none of which is content — so a fresh clone does
# not have one. Most of the harness gets it from lib.sh, but the units start things that source
# only conf.sh, and those fail on a path that does not exist yet. Install is the one act that
# turns a clone into an installation, so it is where the directory is made.
mkdir -p "$SPIRA_RUN"
# AND THE WATCHERS' DIRECTORY. `spira-watch@.service` appends its stdout to a file in here,
# and systemd opens that file BEFORE ExecStart — so a missing directory is not a watcher that
# starts and complains, it is a unit that fails instantly with a message about a path.
mkdir -p "$SPIRA_RUN/watchd"

for u in "${UNITS[@]}"; do
    render "$SRC/$u" > "$DEST/$u.new" || { rm -f "$DEST/$u.new"; echo "install: $u FAILED" >&2; exit 1; }
    mv "$DEST/$u.new" "$DEST/$u" && chmod 0644 "$DEST/$u" && echo "installed $u"
done
systemctl --user daemon-reload

# Without lingering, user units stop when the last session closes — which is precisely the
# case these exist to survive.
# `id -un` rather than $USER alone: this file runs under `set -u`, and a minimal environment
# — a gate, a timer, a test harness — carries no USER, so the install died on an unbound
# variable after having written every unit and before enabling any of them.
loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true

for u in "${ENABLE[@]}"; do systemctl --user enable --now "$u" && echo "enabled   $u"; done

# A ROW THAT HAS GONE MUST STOP RUNNING. Otherwise the manifest is the source of truth only
# for what starts, and a watcher deleted from it goes on polling — and goes on being believed
# — until somebody reads `systemctl` output they had no reason to read.
#
# The instance list is taken from BOTH unit-files (enabled) and units (loaded but perhaps
# no longer enabled), and the name is picked out by pattern rather than by column, because
# `list-units` prefixes a failed unit with a status glyph that shifts every column along.
for u in $({ systemctl --user list-unit-files --no-legend 'spira-watch@*.service' 2>/dev/null
             systemctl --user list-units --all --no-legend 'spira-watch@*.service' 2>/dev/null
           } | tr -s ' \t' '\n\n' | grep -E '^spira-watch@[A-Za-z0-9_-]+\.service$' | sort -u); do
    # SPACE-JOINED ABOVE, and that is the whole reason: matched against `units`' raw
    # newline-separated output, every instance failed to find its own row and a second
    # install disabled every watcher it had just enabled.
    case "$watch_units" in *" $u "*) continue ;; esac
    systemctl --user disable --now "$u" >/dev/null 2>&1 && echo "disabled  $u (no row in the manifest)"
done
systemctl --user list-timers --all 2>/dev/null | grep -E 'cockpit|concierge|beads-push|spira' || true
# Long-running services never appear above. Everything else on this list is worthless if
# they are down.
for u in spira-cockpit.service ${SPIRA_DOLT_DATA:+dolt-beads.service}; do
    printf '%-28s %s\n' "$u" "$(systemctl --user is-active "$u")"
done
