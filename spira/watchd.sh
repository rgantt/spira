#!/usr/bin/env bash
#
# watchd.sh — the watcher manifest, and the face over the logs and cursors systemd fills.
#
#   watchd.sh manifest              every valid row, expanded: name|kind|target|health
#   watchd.sh units                 the unit name of every `daemon` row, one per line
#   watchd.sh exec <name>           become that watcher; this is what ExecStart calls
#   watchd.sh status                unit state and unread count, one line per watcher
#   watchd.sh drain [name] [--all]  print what nobody has read, and mark it read
#   watchd.sh tail <name> [--all]   replay from the cursor, then stream; for a Monitor
#   watchd.sh restart [name]        restart the unit behind a watcher
#
# WHAT A READER LATCHES ONTO is two files per watcher and nothing else: `<name>.log`,
# newline-delimited and append-only, and `<name>.cursor`, an integer counting the lines
# already delivered. Every command below is arithmetic over those two, which is what keeps
# the contract agent-agnostic — `tail -n +$((cursor+1)) -F <log>` is a conforming client, and
# a session that cannot run this script loses nothing but ergonomics.
#
# SYSTEMD OWNS THE PROCESS AND THIS OWNS NOTHING. `status` asks systemd what is running and
# `restart` asks systemd to restart it; nothing here launches a process, detaches one, writes
# a pid file, or decides a watcher is alive by signalling it. There is deliberately no second
# supervision scheme beside systemd's, because a second one is how the defect that prompted
# all of this survived: a watcher started by hand went on reading a database that had been
# retired underneath it for three days, looking perfectly healthy in every process listing,
# while nothing outside that session even knew it was supposed to exist.
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

# _wd_logfile <name> <kind> <target> — where this watcher's events actually are.
#
# A `daemon` row's log is ours: the unit's `StandardOutput=append:` writes it. A `log` row's
# log is the target itself, because something else already writes that file and the row exists
# only to say so. The CURSOR is ours either way — how much of a log a reader has consumed is
# never a fact the log's writer knows.
_wd_logfile() {
    if [ "$2" = log ]; then printf '%s' "$3"; else printf '%s/%s.log' "$(watchd_dir)" "$1"; fi
}
_wd_cursorfile() { printf '%s/%s.cursor' "$(watchd_dir)" "$1"; }

# _wd_total <logfile> — lines in the log, and 0 for a log that is not there yet.
#
# THE ABSENT FILE IS TESTED FOR, not redirected into. `wc -l < missing` fails in the SHELL,
# before `wc` runs, so `2>/dev/null` on the command does not suppress it — and a watcher
# enabled but not yet started is the ordinary case, so `status` printed one shell error per
# such watcher on every pass, into the same stream a session hook reads.
_wd_total() {
    local n
    [ -r "$1" ] || { printf '0'; return 0; }
    n="$(wc -l < "$1" 2>/dev/null)" || n=""
    n="${n#"${n%%[![:space:]]*}"}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# _wd_pos <name> <total> — the cursor, forced into [0, total].
#
# THE CLAMP IS THE WHOLE OF THE ARITHMETIC and it is not defensive padding. Three ordinary
# situations put the cursor past the end of the log: an operator rotates or truncates it, a
# watcher is mid-write so the final line carries no newline and `wc -l` is one short of what
# a reader counted, and a hand-edited cursor file. Unclamped, each of those yields a NEGATIVE
# unread count that renders as a negative number and makes `tail -n +N` start before the
# beginning. Clamped, they read as "nothing unread", which under-reports rather than replaying
# a whole log into a fresh context window — the conservative direction for a value whose
# consumer is a session's first screen.
#
# A cursor that is missing, empty, negative or not a number at all reads as 0. Zero is the
# only safe reading: it replays, where a crash or a silent skip would lose events.
_wd_pos() {
    local p
    p="$(cat "$(_wd_cursorfile "$1")" 2>/dev/null)" || p=""
    case "$p" in ''|*[!0-9]*) p=0 ;; esac
    [ "$p" -gt "$2" ] && p="$2"
    printf '%s' "$p"
}

_wd_setpos() {
    mkdir -p "$(watchd_dir)" || return 1
    printf '%s\n' "$2" > "$(_wd_cursorfile "$1")"
}

# _wd_filter — the expression deciding which lines a reader is shown by default.
#
# WHY THERE IS A DEFAULT FILTER AT ALL. Every line surfaced to a session becomes something it
# reacts to, and a watcher's log is mostly progress: state changes that are already visible
# elsewhere and recoverable from the log itself. Surfacing all of it turns a watcher into a
# siren, and an alert nobody can afford to read is the same as no alert
# (law-alerts-must-be-actionable). ACTIONABLE means something is stuck, something broke,
# something needs a human choice, or a thing being waited on finished.
#
# It is CONFIGURATION and not a literal because an operator's watchers speak their own
# vocabulary, and because the same expression has to serve `drain` and `tail` — the two used
# to disagree, with one filtering and the other not, and the session hook advertised the
# unfiltered one.
#
# AN EMPTY EXPRESSION IS REFUSED. As a regular expression it matches every line, so a
# mistyped or blanked key would turn the filter off with nothing at all to see; `--all` is
# how you ask for that, and it says so at the call site.
_wd_filter() {
    if [ -z "${SPIRA_ACTIONABLE:-}" ]; then
        echo "watchd: SPIRA_ACTIONABLE is empty — that would match every line; pass --all to ask for that deliberately" >&2
        return 1
    fi
    printf '%s' "$SPIRA_ACTIONABLE"
}

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

# _wd_args <argv...> — the one option parser the reading commands share, so that `--all`
# cannot mean one thing to `drain` and another to `tail`. Sets _wd_name and _wd_all.
#
# An unrecognised option is refused rather than taken as a watcher name: `--al` would
# otherwise be looked up as a watcher, found missing, and reported as though the manifest
# were at fault.
_wd_args() {
    _wd_name=""; _wd_all=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --all) _wd_all=1 ;;
            -*)    echo "watchd: unknown option '$1'" >&2; return 2 ;;
            *)     if [ -n "$_wd_name" ]; then
                       echo "watchd: one watcher at a time, got '$_wd_name' and '$1'" >&2; return 2
                   fi
                   _wd_name="$1" ;;
        esac
        shift
    done
    return 0
}

# _wd_find <rows> <name> — sets _wd_kind and _wd_target for one row, or names what is wrong.
_wd_find() {
    local name kind target health
    while IFS='|' read -r name kind target health; do
        [ "$name" = "$2" ] || continue
        _wd_kind="$kind"; _wd_target="$target"; return 0
    done <<< "$1"
    echo "watchd: no watcher named '$2' in $SPIRA_WATCHERS" >&2
    return 2
}

cmd_status() {
    local rows; rows="$(watchd_rows)" || return 1
    local name kind target health
    local -a wname=() wkind=() wtarget=() units=()
    while IFS='|' read -r name kind target health; do
        [ -n "$name" ] || continue
        wname+=("$name"); wkind+=("$kind"); wtarget+=("$target")
        [ "$kind" = daemon ] && units+=("spira-watch@$name.service")
    done <<< "$rows"

    # ONE EXEC FOR EVERY UNIT. `systemctl is-active` takes any number of units and answers one
    # line each, in the order given, so the cost of `status` does not grow with the manifest.
    # A call per watcher on a box that may be running production on the same cores is exactly
    # what law-fence-loops-on-shared-hardware is about, and `status` is the command a session
    # hook runs at every start.
    local -a states=()
    if [ "${#units[@]}" -gt 0 ]; then
        mapfile -t states < <(systemctl --user is-active "${units[@]}" 2>/dev/null)
    fi

    printf '%-14s %-10s %7s  %s\n' NAME UNIT UNREAD LOG
    local i u=0 lf total pos state
    for ((i=0; i<${#wname[@]}; i++)); do
        lf="$(_wd_logfile "${wname[$i]}" "${wkind[$i]}" "${wtarget[$i]}")"
        total="$(_wd_total "$lf")"
        pos="$(_wd_pos "${wname[$i]}" "$total")"
        if [ "${wkind[$i]}" = daemon ]; then
            # AN ANSWER WE DID NOT GET RENDERS `?`, NEVER `inactive`. systemd may not be
            # running at all — a container, a box without a user manager — and a failed probe
            # displayed as a state is a broken check reported as a finding about the watcher
            # (law-absence-needs-a-positive-control).
            state="${states[$u]:-?}"; [ -n "$state" ] || state="?"
            u=$((u+1))
        else
            # Nothing here owns it, so there is no unit to ask about. The unread count is
            # still ours, and is the only thing about a `log` row that can be wrong.
            state="external"
        fi
        printf '%-14s %-10s %7s  %s\n' "${wname[$i]}" "$state" "$(( total - pos ))" "$lf"
    done
}

# cmd_drain [name] [--all] — hand over what nobody has read, and record that it was handed over.
#
# THE DEFAULT IS FILTERED, AND THAT IS THE POINT OF THIS COMMAND. `drain` is what a session
# hook advertises to a context window that has just opened, so an unfiltered drain puts the
# entire backlog into the most expensive place it could go: one real session was offered a
# replay of 283 raw lines as the first thing in it. `--all` is the escape hatch, and it has to
# be asked for.
#
# THE HEADER CARRIES BOTH NUMBERS — actionable and new — because the suppressed lines are the
# cost of the filter, and a filter whose cost is invisible is one nobody can tell has gone
# wrong. It prints even when nothing survived the filter, so "47 events, none of them needed
# you" and "no events" stay distinguishable.
cmd_drain() {
    _wd_args "$@" || return 2
    local re=""
    [ -n "$_wd_all" ] || { re="$(_wd_filter)" || return 2; }
    local rows; rows="$(watchd_rows)" || return 1

    local name kind target health lf total pos new chunk shown k found=""
    while IFS='|' read -r name kind target health; do
        [ -n "$name" ] || continue
        if [ -n "$_wd_name" ]; then [ "$_wd_name" = "$name" ] || continue; fi
        found=1
        lf="$(_wd_logfile "$name" "$kind" "$target")"
        total="$(_wd_total "$lf")"
        pos="$(_wd_pos "$name" "$total")"
        new=$(( total - pos ))
        [ "$new" -gt 0 ] || continue

        # AN EXACT RANGE, NOT A TAIL PIPED INTO A HEAD. The log is being appended to while
        # this runs, so `tail -n +N` would emit lines written after the count was taken —
        # printed here, but still ahead of the cursor set below, and therefore printed again
        # by the next drain. Naming both ends binds what is shown to what is marked read.
        chunk="$(sed -n "$(( pos + 1 )),${total}p" "$lf" 2>/dev/null)"
        if [ -n "$_wd_all" ]; then
            printf '=== %s (%d new) ===\n' "$name" "$new"
            printf '%s\n' "$chunk"
        else
            shown="$(printf '%s\n' "$chunk" | grep -E -- "$re")"
            k=0; [ -n "$shown" ] && k="$(printf '%s\n' "$shown" | wc -l)"
            printf '=== %s (%d actionable of %d new) ===\n' "$name" "$k" "$new"
            [ -n "$shown" ] && printf '%s\n' "$shown"
        fi

        # THE CURSOR ADVANCES BY WHAT WAS READ, NEVER BY WHAT WAS PRINTED. A filtered line has
        # been considered and rejected, not missed; leaving it unread would make every
        # subsequent drain re-examine it and would keep the hook reporting a backlog that no
        # amount of draining could clear.
        _wd_setpos "$name" "$total"
    done <<< "$rows"

    if [ -n "$_wd_name" ] && [ -z "$found" ]; then
        echo "watchd: no watcher named '$_wd_name' in $SPIRA_WATCHERS" >&2
        return 2
    fi
    return 0
}

# cmd_tail <name> [--all] — replay from the cursor, then stream. This is the Monitor command.
#
# It never exits on its own, and it advances the cursor AS IT READS rather than at the end.
# Both properties are what make re-latching after a context reset correct: attaching replays
# exactly what was written while nobody was attached, and re-attaching after that replays
# nothing, because the position was written down line by line. Advancing only on exit would
# make every re-attach re-fire the whole history — which is the noise the filter exists to
# remove, arriving by a different route.
cmd_tail() {
    _wd_args "$@" || return 2
    [ -n "$_wd_name" ] || { echo "usage: watchd.sh tail <name> [--all]" >&2; return 2; }
    local re=""
    [ -n "$_wd_all" ] || { re="$(_wd_filter)" || return 2; }
    local rows; rows="$(watchd_rows)" || return 1
    _wd_find "$rows" "$_wd_name" || return 2

    local lf cf pos
    lf="$(_wd_logfile "$_wd_name" "$_wd_kind" "$_wd_target")"
    cf="$(_wd_cursorfile "$_wd_name")"
    mkdir -p "$(watchd_dir)" || return 1
    pos="$(_wd_pos "$_wd_name" "$(_wd_total "$lf")")"
    # A LOG THAT IS NOT THERE YET IS SAID OUT LOUD, then waited for. `-F` retries by name, so
    # attaching before the unit has started is legitimate and works; what is not acceptable is
    # doing it silently, because a watcher whose log never appears and a watcher with nothing
    # to say would then look identical from here.
    [ -f "$lf" ] || echo "watchd: $lf does not exist yet — waiting for it" >&2

    # awk holds the position, because only awk knows how far the stream has got. It writes the
    # ABSOLUTE line number after every line and closes the file each time, so a reader killed
    # mid-stream loses at most the line it was on. `print` is flushed for the same reason a
    # Monitor exists at all: a line buffered is a line not delivered.
    if [ -n "$_wd_all" ]; then
        tail -n +$(( pos + 1 )) -F "$lf" \
            | awk -v c="$cf" -v p="$pos" '{ n=p+NR; print; fflush(); print n > c; close(c) }'
    else
        tail -n +$(( pos + 1 )) -F "$lf" \
            | awk -v c="$cf" -v p="$pos" -v re="$re" \
                '{ n=p+NR; if ($0 ~ re) { print; fflush() } print n > c; close(c) }'
    fi
}

# cmd_restart [name] — hand the restart to systemd, which is the only thing that owns one.
#
# All of them by default and in ONE call, for the reason `status` batches: the manifest decides
# how many units there are, and a command whose cost grows with it gets slower on exactly the
# installation that needs it most.
cmd_restart() {
    local only="${1:-}"
    local rows; rows="$(watchd_rows)" || return 1
    local name kind target health found=""
    local -a units=()
    while IFS='|' read -r name kind target health; do
        [ -n "$name" ] || continue
        if [ -n "$only" ]; then [ "$only" = "$name" ] || continue; fi
        found=1
        if [ "$kind" != daemon ]; then
            # There is no unit, so there is nothing to restart — and restarting whatever writes
            # that log is not this harness's business.
            #
            # NAMED ON ITS OWN THIS IS A REFUSAL; IN BULK IT IS A SILENT SKIP. The caller who
            # named it asked for something that cannot happen, and a zero exit would tell them
            # it did. The caller who asked for all of them asked about the units, and a line
            # of explanation on every pass is the noise that makes a real one unreadable.
            if [ -n "$only" ]; then
                echo "watchd: $name is a $kind row — $target is written by something else, so there is no unit to restart" >&2
                return 2
            fi
            continue
        fi
        units+=("spira-watch@$name.service")
    done <<< "$rows"

    if [ -n "$only" ] && [ -z "$found" ]; then
        echo "watchd: no watcher named '$only' in $SPIRA_WATCHERS" >&2
        return 2
    fi
    [ "${#units[@]}" -gt 0 ] || return 0
    systemctl --user restart "${units[@]}" || {
        echo "watchd: systemd refused the restart — ask it why with 'systemctl --user status ${units[0]}'" >&2
        return 1
    }
    printf 'restarted: %s\n' "${units[*]}"
}

case "${1:-status}" in
    manifest) cmd_manifest ;;
    units)    cmd_units ;;
    exec)     shift; cmd_exec "${1:-}" ;;
    status)   cmd_status ;;
    drain)    shift; cmd_drain "$@" ;;
    tail)     shift; cmd_tail "$@" ;;
    restart)  shift; cmd_restart "${1:-}" ;;
    *) echo "usage: watchd.sh manifest|units|exec <name>|status|drain [name] [--all]|tail <name> [--all]|restart [name]" >&2
       exit 2 ;;
esac
