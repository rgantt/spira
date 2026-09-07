#!/usr/bin/env bash
#
# watchd.sh — the watcher manifest, and the dispatcher systemd starts a watcher through.
#
#   watchd.sh manifest        every valid row, expanded: name|kind|target|health
#   watchd.sh units           the unit name of every `daemon` row, one per line
#   watchd.sh exec <name>     become that watcher; this is what ExecStart calls
#
# WHY A DISPATCHER RATHER THAN A PATH IN THE UNIT. `spira-watch@.service` is ONE template
# taking the watcher's name as its instance, so adding a watcher is a row in the manifest
# plus an install run. Its ExecStart names this script and the instance and nothing else, so
# the manifest stays the only source of truth and no unit encodes a path — a unit with a path
# baked into it runs on exactly one box, and systemd's failure for a wrong one is a bare "No
# such file or directory" in a journal nobody is watching.
#
# WHY A MALFORMED MANIFEST REFUSES THE WHOLE FILE. Every fault is named with its line number
# and then nothing is emitted at all. A parser that skipped the bad row and returned the good
# ones would let `install.sh` enable a partial set and report success — and a watcher that was
# never started looks exactly like a watcher with nothing to say. Refusing is loud; skipping
# is a silence somebody has to notice (law-absence-needs-a-positive-control).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"

# The keys a target may name. An allowlist rather than "any variable", because this file is
# read by the process systemd starts as the operator, and because an unrecognised placeholder
# is a typo that must be reported rather than left standing in a path.
WATCHD_KEYS="SPIRA_HOME SPIRA_REPO SPIRA_RUN SPIRA_COCKPIT SPIRA_DB SPIRA_WORKSPACES SPIRA_TOWN SPIRA_WIKI"

# Where the two files a reader latches onto live. Under SPIRA_RUN, which is gitignored: a
# watcher's log carries whatever it was watching.
watchd_dir() { printf '%s/watchd' "$SPIRA_RUN"; }

_wd_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# _wd_expand <string> -> 0 and the expansion in _wd_out, or 1 and the reason in _wd_err.
#
# The iteration cap is not paranoia about a hostile file: a value that itself contains an
# `@KEY@` would otherwise spin forever, and a manifest parse that hangs is indistinguishable
# from an install that is merely slow.
_wd_expand() {
    local s="$1" key val i=0
    _wd_out=""; _wd_err=""
    while [[ "$s" =~ @([A-Z_]+)@ ]]; do
        i=$((i+1)); [ "$i" -gt 20 ] && { _wd_err="placeholders nest more than 20 deep"; return 1; }
        key="${BASH_REMATCH[1]}"
        case " $WATCHD_KEYS " in
            *" $key "*) ;;
            *) _wd_err="unknown placeholder @$key@ (known: $WATCHD_KEYS)"; return 1 ;;
        esac
        val="${!key-}"
        # AN OPTIONAL KEY NOBODY SET IS A FAULT, NOT AN EMPTY STRING. SPIRA_TOWN and its kind
        # default to empty on purpose, and `@SPIRA_TOWN@/watch.sh` would expand to
        # `/watch.sh` — a path that exists on somebody's box and is nobody's watcher.
        [ -n "$val" ] || { _wd_err="@$key@ is empty — set it in ${SPIRA_CONF_FILE:-spira.conf} or drop the row"; return 1; }
        s="${s//@$key@/$val}"
    done
    _wd_out="$s"; return 0
}

# watchd_rows -> every valid row on stdout as name|kind|target|health, or 1 having named
# every fault on stderr and printed nothing.
watchd_rows() {
    local file="$SPIRA_WATCHERS"
    if [ ! -f "$file" ]; then
        echo "watchd: no watcher manifest at $file" >&2
        return 1
    fi
    local n=0 faults=0 rows="" seen=" " line trimmed nf name kind target health i
    local -a f
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n+1))
        line="${line%$'\r'}"
        trimmed="$(_wd_trim "$line")"
        [ -z "$trimmed" ] && continue
        case "$trimmed" in '#'*) continue ;; esac

        IFS='|' read -r -a f <<< "$trimmed"
        nf="${#f[@]}"
        if [ "$nf" -lt 3 ]; then
            echo "watchd: $file:$n: expected name|kind|target[|health], got $nf field(s): $trimmed" >&2
            faults=1; continue
        fi
        name="$(_wd_trim "${f[0]}")"; kind="$(_wd_trim "${f[1]}")"; target="$(_wd_trim "${f[2]}")"
        # The health command is field four ONWARDS, rejoined: it is a command line and may
        # legitimately contain a pipe, and it is last precisely so that it can.
        health=""
        for ((i=3; i<nf; i++)); do health="$health${health:+|}${f[$i]}"; done
        health="$(_wd_trim "$health")"

        # A NAME IS A SYSTEMD INSTANCE NAME. Restricting it here is what lets every caller
        # write `spira-watch@$name.service` without `systemd-escape` — and an unescaped `/`
        # in an instance name is not an error, it is a DIFFERENT unit.
        if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
            echo "watchd: $file:$n: '$name' is not a usable watcher name (letters, digits, _ and - only)" >&2
            faults=1; continue
        fi
        case "$seen" in *" $name "*)
            echo "watchd: $file:$n: '$name' is already defined above — a duplicate would render one unit for two rows" >&2
            faults=1; continue ;;
        esac
        case "$kind" in
            daemon|log) ;;
            *) echo "watchd: $file:$n: '$kind' is not a kind (daemon: we run it; log: something else writes it)" >&2
               faults=1; continue ;;
        esac
        if [ -z "$target" ]; then
            echo "watchd: $file:$n: '$name' has no target" >&2
            faults=1; continue
        fi
        if ! _wd_expand "$target"; then
            echo "watchd: $file:$n: '$name': $_wd_err" >&2
            faults=1; continue
        fi
        target="$_wd_out"
        # ABSOLUTE, ALWAYS. A unit is started with no working directory worth the name, so a
        # relative target resolves against `/` — which either fails at the worst moment or
        # finds something else entirely.
        case "$target" in /*) ;;
            *) echo "watchd: $file:$n: '$name': target must be an absolute path, got '$target'" >&2
               faults=1; continue ;;
        esac
        if [ -n "$health" ] && ! _wd_expand "$health"; then
            echo "watchd: $file:$n: '$name' health: $_wd_err" >&2
            faults=1; continue
        fi
        [ -n "$health" ] && health="$_wd_out"

        seen="$seen$name "
        rows="$rows$name|$kind|$target|$health
"
    done < "$file"

    if [ "$faults" != 0 ]; then
        echo "watchd: $file is malformed — refusing to answer for any of it" >&2
        return 1
    fi
    # An empty manifest is a legitimate answer — an installation may own no watchers — but it
    # is said out loud, because "no watchers" and "the manifest is somewhere else" read the
    # same in an empty stdout.
    [ -n "$rows" ] || echo "watchd: $file defines no watchers" >&2
    printf '%s' "$rows"
    return 0
}

cmd_manifest() { watchd_rows; }

cmd_units() {
    local rows name kind rest
    rows="$(watchd_rows)" || return 1
    while IFS='|' read -r name kind rest; do
        [ -n "$name" ] || continue
        [ "$kind" = daemon ] || continue
        printf 'spira-watch@%s.service\n' "$name"
    done <<< "$rows"
}

# BECOME THE WATCHER. `exec`, so the process systemd supervises IS the watcher and not a
# shell holding it — a wrapper in between makes `Restart=always` restart the wrapper and
# every signal land on the wrong process.
cmd_exec() {
    local want="${1:-}"
    [ -n "$want" ] || { echo "usage: watchd.sh exec <name>" >&2; return 2; }
    local rows name kind target health found=""
    rows="$(watchd_rows)" || return 1
    while IFS='|' read -r name kind target health; do
        [ "$name" = "$want" ] || continue
        found=1; break
    done <<< "$rows"
    [ -n "$found" ] || { echo "watchd: no watcher named '$want' in $SPIRA_WATCHERS" >&2; return 2; }
    if [ "$kind" != daemon ]; then
        echo "watchd: '$want' is a $kind row — $target is written by something else and there is nothing here to run" >&2
        return 2
    fi
    # The log the unit appends to lives here, and systemd opens it BEFORE ExecStart runs, so
    # this mkdir is for a hand-run watcher and for the cursor beside it. install.sh makes the
    # directory for the units.
    mkdir -p "$(watchd_dir)"
    # SPLIT ON WHITESPACE, NOT SHELL. Nothing in a target is expanded or substituted; a row
    # that needs a pipeline points at a script that is one.
    local -a argv; read -r -a argv <<< "$target"
    [ -x "${argv[0]}" ] || echo "watchd: $want: ${argv[0]} is not executable — starting it anyway so the failure is systemd's to report" >&2
    exec "${argv[@]}"
}

case "${1:-manifest}" in
    manifest) cmd_manifest ;;
    units)    cmd_units ;;
    exec)     shift; cmd_exec "${1:-}" ;;
    *) echo "usage: watchd.sh manifest|units|exec <name>" >&2; exit 2 ;;
esac
