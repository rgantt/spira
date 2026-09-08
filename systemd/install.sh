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
       spira-auron.service spira-auron.timer
       spira-watchtower.service spira-watchtower.timer
       spira-skew.service spira-skew.timer
       spira-archivist.service spira-archivist.timer
       spira-cockpit.service
       spira-loom.service
       spira-watch@.service
       spira-watch-notify.service spira-watch-notify.timer
       spira-watch-refresh.service spira-watch-refresh.timer
       cockpit-ensure.service cockpit-ensure.timer
       concierge.service concierge.timer
       beads-push.service beads-push.timer
       spira-archive.service spira-archive.timer
       spira-suites.service spira-suites.timer
       spira-qa.service spira-qa.timer
       )
# Only these get enabled. The .service behind a .timer is started BY the timer; enabling it
# as well would also run it once at boot, outside the schedule.
ENABLE=(cockpit-ensure.timer concierge.timer spira-watch-refresh.timer
        beads-push.timer spira-sentinel.timer spira-ops.timer spira-auron.timer spira-watchtower.timer spira-skew.timer
        spira-archive.timer
        spira-archivist.timer spira-watch-notify.timer
        spira-suites.timer
        spira-qa.timer
        spira-cockpit.service spira-loom.service)

# UNITS THIS BOX DELIBERATELY DECLINED. A conditional unit is absent from UNITS on purpose,
# so unlisted must be told the difference between "not installed here" and "nobody ever
# listed it" — otherwise the check that exists to catch a forgotten unit cries wolf on every
# box without a Dolt server, and a check that is always red is a check nobody reads.
OPTIONAL=()

# dolt-beads.service supervises the Dolt server itself, which is only this harness's business
# when the operator says so. Empty SPIRA_DOLT_DATA means they run the server their own way,
# and installing a unit that would fight them is worse than not installing one.
if [ -n "$SPIRA_DOLT_DATA" ]; then
    UNITS+=(dolt-beads.service); ENABLE+=(dolt-beads.service)
else
    OPTIONAL+=(dolt-beads.service)
    echo "note: SPIRA_DOLT_DATA is empty — not installing dolt-beads.service." >&2
    echo "      Start your Dolt server yourself, or set it in ${SPIRA_CONF_FILE:-spira.conf}." >&2
fi

# dolt-beads-test.service is a second Dolt server for test fixtures, gated identically.
if [ -n "$SPIRA_TESTDB_DATA" ]; then
    UNITS+=(dolt-beads-test.service); ENABLE+=(dolt-beads-test.service)
else
    OPTIONAL+=(dolt-beads-test.service)
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
                   "$SPIRA_DOLT_DATA" "$SPIRA_TESTDB_DATA" "$DOLT" "$SPIRA_PROD" <<'PY'
import os, re, sys
keys = ["SPIRA_HOME", "SPIRA_REPO", "SPIRA_RUN", "SPIRA_DB", "SPIRA_COCKPIT",
        "SPIRA_DOLT_DATA", "SPIRA_TESTDB_DATA", "DOLT", "SPIRA_PROD"]
m = dict(zip(keys, sys.argv[2:]))
# FALLBACK: an empty SPIRA_PROD is the documented signal that no checkout split
# is wanted — everything runs from the development checkout (SPIRA_HOME). An
# empty string substituted into @SPIRA_PROD@ yields ExecStart=/sentinel.sh,
# which is both wrong and silent (no unresolved placeholder remains).
if not m["SPIRA_PROD"]:
    m["SPIRA_PROD"] = m["SPIRA_HOME"]
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

# A UNIT FILE IN THIS DIRECTORY THAT IS NOT IN UNITS IS INVISIBLE TO EVERYTHING.
# --diff compares the units it already knows about, so a unit added here but never listed
# is never installed, never enabled, and never reported as missing — it simply does not
# exist as far as this script is concerned. spira-cockpit.service sat in exactly that
# state: committed, and enabled by hand on the one box that had it, so it looked healthy
# while the next install.sh would have installed every unit except that one and re-enabled
# the Gas Town collector it replaced. The check is here rather than in a comment because a
# list that must be remembered is the thing that failed.
unlisted() {
    local f b
    for f in "$SRC"/*.service "$SRC"/*.timer; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"
        case " ${UNITS[*]} " in *" $b "*) continue ;; esac
        case " ${OPTIONAL[*]} " in *" $b "*) continue ;; esac
        echo "$b"
    done
}

if [ "${1:-}" = "--diff" ]; then
    rc=0
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    for u in $(unlisted); do
        echo "UNLISTED $u (in this directory but absent from UNITS — it will never be installed)"
        rc=1
    done
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

declare -A _CHANGED=()  # units whose rendered content differs from what is installed
for u in "${UNITS[@]}"; do
    unit_text="$(render "$SRC/$u")" || { echo "install: $u FAILED" >&2; exit 1; }
    # REFUSE AN UNEXECUTABLE ExecStart TARGET before writing a single byte. The failure mode
    # this prevents is 203/EXEC: systemd accepts the unit, a timer reports 'active', and the
    # service never runs. Every path is in hand at render time; an unresolved @KEY@ raises an
    # error above, so what reaches this check is a fully-substituted path.
    # System binaries (/usr/*, /bin/*, /sbin/*) are the OS's responsibility, not ours.
    while IFS= read -r line; do
        case "$line" in
            ExecStart=*)
                exec_path="${line#ExecStart=}"; exec_path="${exec_path%% *}"
                case "$exec_path" in ''|/usr/*|/bin/*|/sbin/*) continue ;; esac
                if [ ! -x "$exec_path" ]; then
                    printf 'install: %s: ExecStart target is not executable: %s\n' \
                        "$u" "$exec_path" >&2
                    exit 1
                fi
                ;;
        esac
    done <<< "$unit_text"
    if [ ! -f "$DEST/$u" ] || ! cmp -s <(printf '%s\n' "$unit_text") "$DEST/$u"; then
        _CHANGED[$u]=1
    fi
    printf '%s\n' "$unit_text" > "$DEST/$u.new"
    mv "$DEST/$u.new" "$DEST/$u" && chmod 0644 "$DEST/$u" && echo "installed $u"
done
systemctl --user daemon-reload

# Without lingering, user units stop when the last session closes — which is precisely the
# case these exist to survive.
# `id -un` rather than $USER alone: this file runs under `set -u`, and a minimal environment
# — a gate, a timer, a test harness — carries no USER, so the install died on an unbound
# variable after having written every unit and before enabling any of them.
loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true

# Wait for a running oneshot service to finish before restarting it.
# A long-running service is not drained — we restart it directly.
# SPIRA_DRAIN_INTERVAL overrides the 2-second poll interval (set to 0 in tests).
_drain_oneshot() {
    local svc="$1" waited=0 max=300
    local state type interval="${SPIRA_DRAIN_INTERVAL:-2}"
    state="$(systemctl --user is-active "$svc" 2>/dev/null || true)"
    [ "$state" = "active" ] || return 0
    type="$(systemctl --user show -p Type --value "$svc" 2>/dev/null || true)"
    [ "$type" = "oneshot" ] || return 0
    printf 'install: %s is mid-pass — waiting for it to finish\n' "$svc"
    while [ "$waited" -lt "$max" ]; do
        state="$(systemctl --user is-active "$svc" 2>/dev/null || true)"
        case "$state" in active|activating) ;; *) return 0 ;; esac
        sleep "$interval"; waited=$(( waited + interval ))
    done
    printf 'install: warning — %s did not finish within %ss; proceeding\n' "$svc" "$max" >&2
}

# IF THE WORLD IS HALTED, install the units but leave them stopped. A routine install
# restarting the loop is the worst shape: the operator believes the world is down, every
# surface agrees, and it is running. An explicit world.sh start is how a halt is lifted.
if [ -f "$SPIRA_RUN/world.halted" ]; then
    printf '\ninstall: world is HALTED (%s)\n' "$(head -1 "$SPIRA_RUN/world.halted")"
    printf 'install: reason: %s\n' "$(sed -n 2p "$SPIRA_RUN/world.halted")"
    printf 'install: units installed but NOT started — run world.sh start to lift the halt\n\n'
    for u in "${ENABLE[@]}"; do
        systemctl --user enable "$u" 2>/dev/null && printf 'enabled   %s (stopped — world is halted)\n' "$u"
    done
else
    # RESTART ONLY WHAT CHANGED. A no-op install touches nothing. An unchanged unit that is
    # already active is skipped; a changed unit is drained (if it is a running oneshot) and
    # then restarted. Transient spira-aeon-* units are never in UNITS or ENABLE, so they are
    # structurally unreachable here — no explicit guard is needed.
    #
    # Template units (spira-watch@.service) cover all their instances: if the template
    # changed, every instance derived from it is restarted.
    for u in "${ENABLE[@]}"; do
        tmpl="${u%%@*}@.service"
        changed="${_CHANGED[$u]:-}${_CHANGED[$tmpl]:-}"
        if [ -z "$changed" ]; then
            state="$(systemctl --user is-active "$u" 2>/dev/null || true)"
            if [ "$state" = "active" ]; then
                printf 'unchanged %s (active, skipping)\n' "$u"
                continue
            fi
        fi
        # Drain the backing oneshot service if it is mid-pass.
        case "$u" in
            *.timer) _drain_oneshot "${u%.timer}.service" ;;
            *)       _drain_oneshot "$u" ;;
        esac
        # Restart if already active and content changed; enable+start otherwise.
        if [ -n "$changed" ]; then
            state="$(systemctl --user is-active "$u" 2>/dev/null || true)"
            if [ "$state" = "active" ]; then
                systemctl --user enable "$u" >/dev/null 2>&1 || true
                systemctl --user restart "$u" && echo "restarted $u"
                continue
            fi
        fi
        systemctl --user enable --now "$u" && echo "enabled   $u"
    done
fi

# AND THE ONE PIECE OF WIRING THAT IS NOT A UNIT. The session hook is registered in the coding
# agent client's own settings file, outside every checkout, so installing the harness is the
# moment to put it there — a fresh clone that had to be told to run a second command would go
# without it. `cockpit-ensure` repairs the same registration on a timer, so this is the first
# write rather than the only one, and both are silent when there is nothing to change.
"$SPIRA_HOME/install-session-hook.sh" install || \
    echo "note: the session hook was not registered — run $SPIRA_HOME/install-session-hook.sh install" >&2

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
for u in spira-cockpit.service spira-loom.service ${SPIRA_DOLT_DATA:+dolt-beads.service}; do
    printf '%-28s %s\n' "$u" "$(systemctl --user is-active "$u")"
done

# REPORT THE END STATE. A silent partial install is the defect: a unit enabled but not
# running is indistinguishable from one that was never started, and daemon-reload is the
# specific mechanism that produces this state for any unit whose file has gone (aeons aside,
# a template change can cause a reload to leave a previously-active unit in failed state).
# Skip this check when the world is halted — units are intentionally not running.
if [ ! -f "$SPIRA_RUN/world.halted" ]; then
    not_active=""
    for u in "${ENABLE[@]}"; do
        state="$(systemctl --user is-active "$u" 2>/dev/null || true)"
        [ "$state" = "active" ] || not_active="${not_active}    $u ($state)"$'\n'
    done
    if [ -n "$not_active" ]; then
        printf '\ninstall: ERROR — these units are enabled but not active:\n' >&2
        printf '%s' "$not_active" >&2
        printf 'install: check journalctl --user -xe for details.\n' >&2
        exit 1
    fi
fi
