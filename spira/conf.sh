# conf.sh — the ONE configuration surface. Sourced, never executed.
#
# WHAT THIS FILE IS FOR. Every path this harness touches used to be written into the script
# that touched it: the wiki checkout, the beads database, the directory two binaries happen
# to live in, the seven repositories one operator has. A colleague cloning it has none of
# those, and the failure is not a message — it is `bd: command not found` from a systemd
# timer, into a log nobody reads. So the paths are collected here, in one place, and every
# script asks this file instead of knowing the answer.
#
# THREE SOURCES, IN THIS ORDER, AND THE FIRST ONE THAT SPEAKS WINS:
#
#   1. the ENVIRONMENT — because that is the seam every test suite already drives a fixture
#      through, and a config file that could override a test's own SPIRA_DB would point the
#      suite at the operator's real database. Environment first is not a convenience here;
#      it is what keeps the suites isolated.
#   2. the CONFIG FILE — `spira.conf`, the operator's box.
#   3. a DERIVED DEFAULT — computed from where this file sits, so a clean clone with no
#      config at all still resolves to something coherent rather than to someone else's box.
#
# WHERE THE CONFIG FILE IS LOOKED FOR, first hit wins:
#
#   $SPIRA_CONF                                  an explicit path; set it to a nonexistent
#                                                one to read no file at all
#   $SPIRA_REPO/spira.conf                       beside the checkout the harness runs from
#   ${XDG_CONFIG_HOME:-$HOME/.config}/spira/spira.conf
#   /etc/spira/spira.conf
#
# IT IS NOT SOURCED. A config file that is shell can set PATH, run a command, or shadow a
# function this library defines, and it is read by a process that summons agents. It is
# parsed as `KEY=value` lines, `#` comments, keys restricted to the ones named below, and
# nothing else is honoured — an unknown key is reported, not obeyed, because a typo that is
# silently ignored is a setting the operator believes is in force.

[ -n "${SPIRA_CONF_LOADED:-}" ] && return 0
SPIRA_CONF_LOADED=1

# --------------------------------------------------------------------------------------
# Every key this harness honours, with the default the CODE carries. A key absent from this
# list is refused when it appears in a config file.
#
# This list is also the allowlist: `spira_conf_read` refuses anything not named here, so a
# misspelled key is reported rather than silently ignored. The defaults themselves live in
# `spira_conf_defaults`, which runs AFTER the file is read, so a default may refer to a key
# the operator set.
# --------------------------------------------------------------------------------------
# SPIRA_HOME AND SPIRA_REPO ARE ABSENT FROM THIS LIST DELIBERATELY, and that is a fence.
# Where the harness IS is not a configuration question — it is a fact about where this file
# sits — and letting a config file answer it breaks the landing gate, which extracts a branch
# to a scratch tree and runs that tree's own suites. The config would point them back at the
# installed copy, so the gate would test the code already in force instead of the code being
# judged, and pass. The environment may still override both: that is the seam every suite
# drives a fixture through, and it is explicit rather than ambient.
SPIRA_CONF_KEYS="
SPIRA_HOME_REPO SPIRA_DB SPIRA_RUN SPIRA_GOAL
SPIRA_PATH SPIRA_WORKSPACES SPIRA_REPO_MAP SPIRA_PREFIX_MAP SPIRA_CHAMBER
SPIRA_COCKPIT SPIRA_NOTIFY SPIRA_PANEL SPIRA_OPERATOR SPIRA_OPERATOR_ACTOR SPIRA_TZ SPIRA_ASK_LABEL
SPIRA_CI_LABEL SPIRA_CI_PARK_MAX
COCKPIT_DB COCKPIT_BOTTOM_PCT COCKPIT_RIGHT_PCT COCKPIT_CWD
SPIRA_TOWN SPIRA_MIRROR SPIRA_EXPORTER SPIRA_DESIGN SPIRA_WIKI SPIRA_WIKI_HOOK SPIRA_DOLT_DATA
SPIRA_ALERT_GLOB
SPIRA_FAYTHS SPIRA_MAX_AEONS
SPIRA_TOKEN_WINDOW_H SPIRA_TOKEN_PROJECTS SPIRA_CTX_WARN SPIRA_CTX_HIGH SPIRA_CTX_LIMIT
SPIRA_ARCHIVE
"

# --------------------------------------------------------------------------------------
# Where we are. SPIRA_HOME is the directory holding this file; everything else can be
# derived from it, which is what makes a clean clone runnable.
#
# BASH_SOURCE, not $0: this file is sourced, so $0 is whatever script sourced it, and
# addressing SPIRA_HOME as the caller's directory broke the moment a cockpit tool two
# directories away sourced lib.sh.
# --------------------------------------------------------------------------------------
# WHICH KEYS THE ENVIRONMENT ALREADY OWNS is recorded BEFORE anything is derived. Deriving
# first and testing "is it set?" afterwards makes every derived value indistinguishable from
# one the caller passed in, and the config file — which only fills what is unset — would then
# be silently overridden by defaults this file had just computed.
_spira_conf_env=""
for _k in $SPIRA_CONF_KEYS; do
    [ -n "${!_k+set}" ] && _spira_conf_env="$_spira_conf_env $_k"
done
unset _k

_spira_conf_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Whether SPIRA_HOME was ANSWERED BY THE CALLER or derived is remembered, because it changes
# which repo-map wins below. An explicit SPIRA_HOME is a caller saying "this tree is the
# harness in force" — a fixture, or the gate's scratch checkout — and that tree's map is the
# one it means.
_spira_conf_home_env=""; [ -n "${SPIRA_HOME:-}" ] && _spira_conf_home_env=1
SPIRA_HOME="${SPIRA_HOME:-$_spira_conf_here}"

# The checkout the harness is installed in. `git -C ... --show-toplevel` rather than
# "two directories up", because the harness may be installed anywhere, and because a
# worktree must resolve to ITSELF — an aeon running from a worktree whose helpers resolve
# to the installed copy on main is a version skew that shows up as nothing at all.
SPIRA_REPO_DERIVED="$(git -C "$SPIRA_HOME" rev-parse --show-toplevel 2>/dev/null)" || SPIRA_REPO_DERIVED=""
# THE FALLBACK IS THE PARENT, not a fixed number of levels up. Outside a git checkout there
# is nothing to ask, and "two directories up" was an assumption about one layout that became
# silently wrong the moment the harness moved from `<repo>/.claude/spira` to `<repo>/spira` —
# resolving SPIRA_REPO to the parent of the repository, where nothing it looks for exists.
[ -n "$SPIRA_REPO_DERIVED" ] || SPIRA_REPO_DERIVED="$(cd "$SPIRA_HOME/.." 2>/dev/null && pwd -P)"
SPIRA_REPO="${SPIRA_REPO:-$SPIRA_REPO_DERIVED}"

# THE DERIVED VALUE IS KEPT, because "SPIRA_REPO was set deliberately" and "SPIRA_REPO fell
# out of where this file sits" mean different things to repo_root: the first is an override
# of the repository map, the second is not. Before it was kept, deriving a value made every
# home-repository lookup bypass the map — invisible here, where the two agree, and wrong
# everywhere else. NOT exported, for the same reason SPIRA_HOME is not: it is a fact about
# this copy of the harness, and whatever sources its own conf.sh resolves its own.


# One line, single-spaced, padded at both ends — because the membership test below is a
# `case` on " $key ", and a key that happened to sit at the end of a line in the list above
# was followed by a newline rather than a space and was refused as unknown. Six of the
# twenty-two keys, silently ignored, which is precisely the failure the allowlist exists to
# prevent happening to a typo.
SPIRA_CONF_KEYS=" $(echo $SPIRA_CONF_KEYS) "

# spira_conf_file -> the path of the config file in force, or empty
spira_conf_file() {
    local c
    if [ -n "${SPIRA_CONF+set}" ]; then
        [ -f "$SPIRA_CONF" ] && printf '%s' "$SPIRA_CONF"
        return 0
    fi
    for c in "$SPIRA_REPO/spira.conf" \
             "${XDG_CONFIG_HOME:-$HOME/.config}/spira/spira.conf" \
             /etc/spira/spira.conf; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 0
}

# spira_conf_read <file> — apply the file's settings to any key NOT already set in the
# environment. Prints a warning for a key it does not know and for a malformed line; it
# never fails the caller, because a harness that refuses to start over one bad line in a
# config is a harness that cannot be repaired from the box it is broken on.
spira_conf_read() {
    local file="$1" line key val n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n+1))
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *)
            printf 'spira.conf:%s: not KEY=value, ignored: %s\n' "$n" "$line" >&2
            continue ;;
        esac
        key="${line%%=*}"; val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"             # rtrim key
        val="${val#"${val%%[![:space:]]*}"}"             # ltrim value
        val="${val%"${val##*[![:space:]]}"}"             # rtrim value
        # Quotes are stripped so a value with a trailing space can be written; they are not
        # required, because the common case is a path.
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        case "$SPIRA_CONF_KEYS" in
            *" $key "*) ;;
            *) printf 'spira.conf:%s: unknown key %s, ignored\n' "$n" "$key" >&2
               continue ;;
        esac
        # `~` and $HOME expand, and nothing else does. A value is not shell: `$(date)` in a
        # config file read by the process that summons agents is a command this harness
        # would run as the operator.
        case "$val" in
            '~'|'~/'*) val="$HOME${val#\~}" ;;
        esac
        val="${val//\$HOME/$HOME}"
        val="${val//\$\{HOME\}/$HOME}"
        # THE ENVIRONMENT WINS. `${!key+set}` is the only test that distinguishes "unset"
        # from "set to empty" — and set-to-empty is meaningful here, since an empty
        # SPIRA_TOWN is how an operator says they have no Gas Town.
        case " $_spira_conf_env " in *" $key "*) continue ;; esac
        printf -v "$key" '%s' "$val"
    done < "$file"
}

# spira_conf_defaults — fill in whatever is still unset. Ordered: later defaults refer to
# earlier ones.
spira_conf_defaults() {
    : "${SPIRA_HOME_REPO:=$(basename "$SPIRA_REPO")}"
    # The database is NOT under the checkout by default. A beads database accumulates
    # internal working notes and agent memories, so a default that puts it inside a git
    # repository is one `git add -A` away from publishing them (law-beads-is-never-public).
    : "${SPIRA_DB:=${XDG_DATA_HOME:-$HOME/.local/share}/spira/db}"
    : "${SPIRA_RUN:=$SPIRA_REPO/.runtime/spira}"
    : "${SPIRA_GOAL:=sp-spira}"
    : "${SPIRA_PATH:=}"
    : "${SPIRA_WORKSPACES:=$(dirname "$SPIRA_REPO")}"
    : "${SPIRA_PREFIX_MAP:=$SPIRA_HOME/prefix-map}"
    : "${SPIRA_CHAMBER:=$SPIRA_HOME/chamber}"
    : "${SPIRA_COCKPIT:=$(dirname "$SPIRA_HOME")/cockpit}"
    : "${SPIRA_NOTIFY:=$SPIRA_COCKPIT/ask.sh}"
    # THE LABEL THAT MEANS "WAITING ON THE OPERATOR". It is the one the escalation gate defers
    # on, the one every persona's predicate excludes, and the one the attention panel reads,
    # so all of those must agree on it — which is why it is one key and not five literals.
    # Changing it on a live installation orphans every bead already carrying the old value.
    : "${SPIRA_ASK_LABEL:=needs-operator}"
    # THE LABEL THAT MEANS "PARKED ON A CI RUN". An aeon puts it on a bead whose pull request
    # is open so nothing pays for a session to sit and watch a test suite; the CI sweep takes
    # it off again when the run resolves. Every predicate that decides what an aeon may claim
    # excludes it, and so does the stalled-work report — which is what stops parked work
    # looking abandoned, and is also why a park applied where no run exists is permanent AND
    # invisible. One key rather than five literals, for the same reason as the ask label: the
    # sweep, the personas, the report and the panel must agree on it or the panel is the half
    # nobody notices is wrong, because it simply shows fewer.
    : "${SPIRA_CI_LABEL:=awaiting-ci}"
    # HOW LONG A PARK MAY LAST BEFORE IT IS TREATED AS LOST, in seconds. A park is a promise
    # that something else is watching; past the longest plausible run that promise is false,
    # and the bead should be back in the report that would have found it rather than excluded
    # from it. Ninety minutes is longer than any run this was written against — raise it if
    # your CI is slower, and set it to 0 to disable the deadline, which reinstates the
    # permanent invisible park and should be a deliberate choice.
    : "${SPIRA_CI_PARK_MAX:=5400}"
    # The name the operator's OWN comments are recorded under, so the attention panel can tell
    # a reply of theirs from a reply of the agent's. Both write into the same thread, and a
    # panel that cannot separate them announces the agent's own comment back to it as an answer.
    : "${SPIRA_OPERATOR_ACTOR:=operator}"
    : "${SPIRA_PANEL:=$SPIRA_COCKPIT/panel/target/release/panel}"
    : "${SPIRA_OPERATOR:=the operator}"
    # The timezone dates are written in. Empty means the host's own, which is right until
    # the host is a server in one zone and the operator reads its output in another — the
    # case where an evening's work lands under tomorrow's date and a chronological log
    # quietly stops being chronological.
    : "${SPIRA_TZ:=}"
    : "${SPIRA_WIKI:=}"
    : "${COCKPIT_DB:=$SPIRA_DB}"
    : "${COCKPIT_BOTTOM_PCT:=28}"
    # How wide the ops column is, as a percentage of the window. The dashboard is a
    # FULL-HEIGHT right column, so this is the only dimension it has; COCKPIT_BOTTOM_PCT
    # divides the left column between the session and the attention panel and no longer
    # touches it. A column is what lets each section grow to the space it can use instead
    # of every one of them being cut to a single row.
    : "${COCKPIT_RIGHT_PCT:=33}"
    # WHERE THE COCKPIT'S PANES OPEN. The top pane holds the operator's own session, so its
    # working directory decides which project's instructions that session loads — not a
    # cosmetic choice. It defaults to the wiki when one is configured, because an operator
    # who keeps notes works there rather than in the harness they are merely running.
    : "${COCKPIT_CWD:=${SPIRA_WIKI:-$SPIRA_REPO}}"
    # Optional, and EMPTY IS THE DEFAULT for every one of them. Each names something a
    # colleague does not have — a Gas Town, a wiki, a design document — and every caller
    # must treat empty as "skip this", never as "guess". That is rule 2 of the boundary:
    # an optional call is not a dependency, a hard path is.
    : "${SPIRA_TOWN:=}"
    : "${SPIRA_MIRROR:=}"
    : "${SPIRA_EXPORTER:=}"
    : "${SPIRA_DESIGN:=}"
    : "${SPIRA_WIKI_HOOK:=}"
    # The Dolt server's own data directory, which is NOT the beads project directory: `bd -C`
    # is pointed at the latter, and the former is where the server keeps every database it
    # serves. Empty means this installation does not manage the server, and the unit that
    # would supervise it is not installed.
    : "${SPIRA_DOLT_DATA:=}"
    # The alert units whose failure should be filed as an incident bead, as a find(1) name
    # pattern. Empty means none: these are the operator's own unit names and nothing here can
    # guess them, so install-intake.sh says so rather than wiring whatever matches.
    : "${SPIRA_ALERT_GLOB:=}"

    # ---- WHAT THE ACCOUNT SPENDS -------------------------------------------------------
    # The rate limit is charged against a rolling window, and every figure the token meter
    # reports is "inside the window" — so this number decides what the dashboard means. It is
    # a fact about the operator's PLAN, not about this box, which is why it is a key: a
    # colleague on a different plan reads a window of a different length.
    : "${SPIRA_TOKEN_WINDOW_H:=5}"
    # Where the interactive sessions write their transcripts. The aeons' own traces are found
    # under SPIRA_RUN and need no key, because the harness put them there; this directory
    # belongs to the client, and a client that moves it would otherwise make the session half
    # of the split silently read zero — which is the reading that looks like good news.
    : "${SPIRA_TOKEN_PROJECTS:=$HOME/.claude/projects}"
    # THE THRESHOLDS A LIVE SESSION IS MEASURED AGAINST, shared by the status line and the
    # dashboard so that the two cannot disagree about how close to the edge a session is. The
    # defaults are what this context window actually costs: a session opens near 50,000, and
    # every long one ends up pinned near the ceiling, re-reading all of it on every turn.
    : "${SPIRA_CTX_WARN:=200000}"
    : "${SPIRA_CTX_HIGH:=400000}"
    : "${SPIRA_CTX_LIMIT:=1000000}"

    # WHERE THE TRANSCRIPTS ARE KEPT. The client's own directory is unversioned, on whatever
    # volume the home directory sits on, and promises nothing about retention — so this is a
    # copy of it that outlives both. It defaults under the runtime directory because that is
    # gitignored: the bodies carry paths, credentials read aloud and everything anyone ever
    # said, and a default inside a shared checkout is one `git add -A` away from publishing
    # all of it. Point it at whichever volume has the room; nothing here ever deletes.
    : "${SPIRA_ARCHIVE:=$SPIRA_RUN/archive}"

    # THE MAP FALLS BACK TO THE EXAMPLE, and that is what makes a clean clone runnable at
    # all. The real map is one operator's inventory of checkouts and does not ship; the
    # example does. Resolution runs beside the config file first, because that is where an
    # operator whose harness lives in a repository they did not write can keep theirs.
    if [ -z "${SPIRA_REPO_MAP:-}" ]; then
        local cf d c
        cf="$(spira_conf_file)"
        [ -n "$cf" ] && d="$(dirname "$cf")" || d=""
        # AN EXPLICIT SPIRA_HOME PUTS ITS OWN MAP FIRST. Otherwise the config-dir map leads,
        # for an operator whose harness lives in a repository they did not write.
        #
        # The conditional is not a nicety. Every fixture in these suites plants a map at
        # $SPIRA_HOME/repo-map and sets SPIRA_HOME to reach it; with the config-dir map
        # unconditionally ahead, all of them silently read the operator's REAL seven
        # repositories instead — four suites at once, reporting "0 movements" and "not an
        # ancestor" as though landing were broken, with nothing naming the map they read
        # (law-gates-run-in-a-clean-environment).
        if [ -n "$_spira_conf_home_env" ]; then
            set -- "$SPIRA_HOME/repo-map" ${d:+"$d/repo-map"} "$SPIRA_HOME/repo-map.example"
        else
            set -- ${d:+"$d/repo-map"} "$SPIRA_HOME/repo-map" "$SPIRA_HOME/repo-map.example"
        fi
        for c in "$@"; do
            [ -f "$c" ] && { SPIRA_REPO_MAP="$c"; break; }
        done
        : "${SPIRA_REPO_MAP:=$SPIRA_HOME/repo-map}"
    fi
}

SPIRA_CONF_FILE="$(spira_conf_file)"
[ -n "$SPIRA_CONF_FILE" ] && spira_conf_read "$SPIRA_CONF_FILE"
spira_conf_defaults
unset _spira_conf_here _spira_conf_env _spira_conf_home_env

# --------------------------------------------------------------------------------------
# PATH. `bd`, `git`, `gh` and `claude` live wherever the operator put them, and everything
# here is invoked from systemd, where a login shell's PATH does not exist. Bootstrapping in
# one place is the difference between working and failing silently.
#
# SPIRA_PATH is prepended and is the config's business; the tail is the box's own and is
# not, so it is not written into the config.
# --------------------------------------------------------------------------------------
export PATH="${SPIRA_PATH:+$SPIRA_PATH:}$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

# --------------------------------------------------------------------------------------
# WHAT IS EXPORTED, AND WHAT MUST NEVER BE.
#
# EXPORTED, because the readers are not all shell: a python one-liner, an aeon's session and
# the Rust attention panel are all children of a process that sourced this file, and the
# alternative — threading each value through argv at every call site — is where one gets
# dropped and the tool silently reads a different database.
#
# NOT EXPORTED: EVERYTHING DERIVED FROM WHERE THIS FILE SITS. SPIRA_HOME, SPIRA_REPO, the
# maps, the chamber, the cockpit, the runtime directory. Those differ per COPY of the
# harness, and anything that sources its own conf.sh must resolve them from its own location.
# Exporting them cost eleven tests in one go: a fixture library, sourced by a suite for its
# database helpers, published the live installation's SPIRA_HOME into the environment of the
# sentinel that suite then ran under a temporary one — so the sentinel read the operator's
# REAL repo-map, found none of the fixture's repositories, and landed nothing, while every
# log line it printed looked ordinary (law-gates-run-in-a-clean-environment).
#
# It is safe to export the rest precisely because the landing gate runs its trial under
# `env -i`: configuration reaches the harness's own children and stops at the boundary of
# anything being judged.
#
# SPIRA_FAYTHS and SPIRA_MAX_AEONS are also not exported. They are policy for THIS host, read
# in-process, and exporting SPIRA_FAYTHS is the scar that statute is named for — it reached a
# test suite through systemd and made the suite assert the host's roster instead of the
# defaults it was written to check.
# --------------------------------------------------------------------------------------
export SPIRA_DB COCKPIT_DB COCKPIT_BOTTOM_PCT COCKPIT_RIGHT_PCT COCKPIT_CWD SPIRA_PATH SPIRA_GOAL \
       SPIRA_WORKSPACES SPIRA_OPERATOR SPIRA_OPERATOR_ACTOR SPIRA_TZ SPIRA_ASK_LABEL \
       SPIRA_CI_LABEL SPIRA_CI_PARK_MAX \
       SPIRA_TOWN SPIRA_MIRROR SPIRA_EXPORTER SPIRA_DESIGN SPIRA_WIKI SPIRA_WIKI_HOOK SPIRA_DOLT_DATA \
       SPIRA_ALERT_GLOB \
       SPIRA_CONF_FILE

# --------------------------------------------------------------------------------------
# NAME WHAT IS MISSING. A harness that dies with `bd: command not found` from a timer has
# told the operator nothing: not which program, not what it is for, not where to get it.
#
# `spira_require` is cheap enough to call at the top of anything — it is a `command -v` —
# and it is the only reason a fresh box gets a sentence instead of a shell error.
# --------------------------------------------------------------------------------------
spira_require() {        # spira_require <bin> [<bin>...] -> 0, or 1 having named each one
    local b missing=""
    for b in "$@"; do command -v "$b" >/dev/null 2>&1 || missing="$missing $b"; done
    [ -z "$missing" ] && return 0
    for b in $missing; do
        printf 'spira: required program not found on PATH: %s — %s\n' \
            "$b" "$(spira_bin_purpose "$b")" >&2
    done
    printf 'spira: PATH is %s\n' "$PATH" >&2
    printf 'spira: if it is installed elsewhere, set SPIRA_PATH in %s\n' \
        "${SPIRA_CONF_FILE:-spira.conf}" >&2
    return 1
}

spira_bin_purpose() {
    case "$1" in
        bd)      echo "the beads issue tracker — the substrate; nothing runs without it" ;;
        dolt)    echo "the SQL server beads stores its database in" ;;
        git)     echo "every repository operation" ;;
        gh)      echo "opening and landing pull requests (repos whose land mode is 'pr')" ;;
        claude)  echo "the agent an aeon is a session of" ;;
        tmux)    echo "the cockpit panes" ;;
        python3) echo "every JSON payload this harness parses" ;;
        cargo)   echo "building the decisions panel; not needed to run the loop" ;;
        jq)      echo "optional JSON convenience" ;;
        flock)   echo "serialising the writers of the transcript archive" ;;
        zstd)    echo "compressing archived transcripts; gzip is used when it is absent" ;;
        *)       echo "required by the harness" ;;
    esac
}
