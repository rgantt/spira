#!/usr/bin/env bash
#
# doctor.sh — can this harness run on this box, and if not, exactly what is missing.
#
#   doctor.sh          check everything, name every fault, exit 1 if any is fatal
#   doctor.sh --paths  print the resolved configuration and stop
#
# WHY IT EXISTS. A harness that dies with `bd: command not found` from a systemd timer has
# told the operator nothing: not which program, not what it is for, not where to get it, and
# not into a log anyone reads. Every fault here is named, in one pass, with what to do about
# it — because the alternative is discovering them one restart at a time.
#
# FATAL versus WARN is the difference between "the loop cannot run" and "one feature is off".
# A missing `cargo` is a warning: the loop runs fine without the attention panel. A missing
# `bd` is fatal, because beads is the substrate.
#
# IT IS READ-ONLY. It creates nothing and starts nothing, so it is safe to run on a box you
# are unsure about — which is the box you would want to run it on.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"

fatal=0; warn=0
FAIL() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fatal=$((fatal+1)); }
WARN() { printf '  warn  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; warn=$((warn+1)); }
OK()   { printf '  ok    %s\n' "$1"; }

CONF="${SPIRA_CONF_FILE:-}"

if [ "${1:-}" = "--paths" ]; then
    printf 'config file   %s\n' "${CONF:-<none — every value is a default>}"
    for k in SPIRA_HOME SPIRA_REPO $SPIRA_CONF_KEYS; do
        printf '%-18s %s\n' "$k" "${!k:-}"
    done
    printf '%-18s %s\n' PATH "$PATH"
    exit 0
fi

echo "spira doctor"
echo
echo "configuration"
if [ -n "$CONF" ]; then OK "reading $CONF"
else WARN "no spira.conf found — every value is a default" \
          "looked in $SPIRA_REPO/spira.conf, \${XDG_CONFIG_HOME:-\$HOME/.config}/spira/, /etc/spira/"
fi
OK "harness at $SPIRA_HOME (in $SPIRA_REPO)"

echo
echo "programs"
# FATAL: the loop cannot run without these. `flock` is one of them because the landing gate
# serialises on the tree it extracts a branch into, and a gate that cannot take that lock
# refuses rather than judging — so every branch would fail its gate and every finished bead
# would be reopened.
for b in bd git python3 flock; do
    if command -v "$b" >/dev/null 2>&1; then OK "$b — $(command -v "$b")"
    else FAIL "$b is not on PATH — $(spira_bin_purpose "$b")" \
              "PATH is $PATH. If it is installed elsewhere, set SPIRA_PATH in ${CONF:-spira.conf}."; fi
done
# WARN: each disables one feature, named, rather than the loop.
for b in dolt gh claude tmux cargo node; do
    if command -v "$b" >/dev/null 2>&1; then OK "$b — $(command -v "$b")"
    else WARN "$b is not on PATH — $(spira_bin_purpose "$b")" \
              "If it is installed elsewhere, set SPIRA_PATH in ${CONF:-spira.conf}."; fi
done

echo
echo "the database"
if [ -d "$SPIRA_DB/.beads" ]; then
    OK "$SPIRA_DB has a .beads"
    # A DATABASE THAT ANSWERS IS NOT THE SAME AS ONE THAT IS THERE. `bd` takes its database
    # from the path it is pointed at, so a wrong or moved path does not error — it silently
    # answers from some other store (law-bd-c-selects-the-database).
    if out="$(timeout 60 bd -C "$SPIRA_DB" list --limit 1 --json 2>&1)"; then
        OK "bd can read it"
    else
        FAIL "bd cannot read $SPIRA_DB" "$(printf '%s' "$out" | head -2)
        A Dolt server may be down. Try: bd -C $SPIRA_DB dolt start"
    fi
else
    FAIL "$SPIRA_DB has no .beads — the harness refuses to guess a database" \
         "Set SPIRA_DB in ${CONF:-spira.conf}, or create it with: bd -C $SPIRA_DB init"
fi
case "$SPIRA_DB" in
    "$SPIRA_REPO"/*|"$SPIRA_REPO")
        WARN "the database is inside the harness checkout" \
             "It accumulates internal notes and agent memories and must never be committed.
        Move it out, or make certain it is gitignored (law-beads-is-never-public)." ;;
esac

echo
echo "statutes"
if command -v bd >/dev/null 2>&1 && [ -d "$SPIRA_DB/.beads" ]; then
    missing="$("$SPIRA_HOME/seed.sh" --list 2>/dev/null | grep -c ' -$' || true)"
    if [ "${missing:-0}" -gt 0 ]; then
        WARN "$missing shipped statutes are not in this database" \
             "Agents read their law from the database, not from the repository.
        Write them in with: $SPIRA_HOME/seed.sh"
    else
        OK "every shipped statute is in force"
    fi
else
    WARN "cannot check the statute book without bd and a database"
fi

echo
echo "repositories"
if [ ! -f "$SPIRA_REPO_MAP" ]; then
    FAIL "no repo-map at $SPIRA_REPO_MAP" \
         "Copy $SPIRA_HOME/repo-map.example to repo-map and write your own rows."
else
    case "$SPIRA_REPO_MAP" in
        *.example) WARN "still reading the EXAMPLE map — its rows name repositories that do not exist" \
                        "Copy it to $SPIRA_HOME/repo-map and write your own rows." ;;
        *)         OK "map at $SPIRA_REPO_MAP" ;;
    esac
    . "$SPIRA_HOME/lib.sh"
    home="$(spira_home_repo)"
    repo_root "$home" >/dev/null 2>&1 \
        && OK "the home repository '$home' has a row" \
        || FAIL "the home repository '$home' has no row in the map" \
                "A bead that names no repository resolves to '$home', and an unmapped name is
        refused rather than guessed. Add a row, or set SPIRA_HOME_REPO in ${CONF:-spira.conf}."
    for n in $(repo_names); do
        p="$(repo_field "$n" path)"
        b="$(repo_field "$n" base)"
        if [ ! -e "$p/.git" ]; then
            WARN "repo:$n — $p is not a checkout" "Another machine's row, or a path that has moved."
            continue
        fi
        if [ -z "$b" ]; then
            WARN "repo:$n — no base declared; it will be resolved, and refused if it cannot be"
        elif ! git -C "$p" rev-parse --verify -q "$b" >/dev/null 2>&1; then
            FAIL "repo:$n — declared base '$b' does not exist in $p" \
                 "Work would be rebased onto a ref nobody chose. Do not assume 'main'."
        else
            OK "repo:$n — $p on $b"
        fi
    done

    # HOW MANY COPIES OF THE HARNESS THIS BOX HAS. One is the answer; anything else means
    # work aimed at the harness can land in a tree nothing executes, pass every check there,
    # and never run. Nothing else here compares the two, which is what makes that failure
    # silent — landed and in effect quietly became different claims.
    #
    # `copies` and not `check`: doctor is read-only, and the full check fetches and
    # escalates. This is the structural half, which costs an ls-files per repository.
    #
    # A repository the map names that this box does not have is skipped by `copies`, so a
    # verdict of "one" here is about this box and not about the map.
    if ! copies="$(bash "$SPIRA_HOME/skew.sh" copies 2>/dev/null)"; then
        WARN "no mapped repository carries a harness this box can find" \
             "Either no row points at a real checkout, or the signature has changed.
        $SPIRA_HOME/skew.sh copies"
    elif [ "$(grep -c ' second$' <<< "$copies")" -gt 0 ]; then
        while read -r n p d k; do
            [ "$k" = second ] || continue
            # WARN and not FAIL, per this file's own line: the loop runs perfectly well with
            # two copies, which is exactly what makes the fault silent. The loud channel is
            # skew.sh's escalation; doctor's job is to name it in the one pass.
            WARN "repo:$n carries a SECOND harness at $p/$d" \
                 "The harness in force is $SPIRA_REPO. Work landing in that other copy passes
        its own gate and its own suites, closes its bead naming a real commit, and never runs.
        Delete the copy, or point this installation at it — but not both.
        $SPIRA_HOME/skew.sh check"
        done <<< "$copies"
    else
        OK "one harness on this box — $SPIRA_REPO is the only copy the map reaches"
    fi
fi

echo
echo "the cockpit"
[ -d "$SPIRA_COCKPIT" ] && OK "cockpit at $SPIRA_COCKPIT" \
    || WARN "no cockpit directory at $SPIRA_COCKPIT" "The loop runs; you have no way to see it."
if [ -x "$SPIRA_PANEL" ]; then OK "attention panel built at $SPIRA_PANEL"
else WARN "attention panel not built at $SPIRA_PANEL" \
          "Build it: cd $SPIRA_COCKPIT/panel && cargo build --release"; fi
[ -x "$SPIRA_NOTIFY" ] && OK "escalations deliver through $SPIRA_NOTIFY" \
    || FAIL "no escalation path at $SPIRA_NOTIFY" \
            "An ask that reaches nobody is worse than an unanswered question
        (law-answers-need-a-delivery-path). Set SPIRA_NOTIFY in ${CONF:-spira.conf}."

echo
echo "the status line"
# WHY THIS IS DOCTOR'S BUSINESS AT ALL. The status line is where the context meter and the
# archivist's state machine are read, and it lives in the CLIENT's settings file, outside every
# repository — so nothing the harness ships can set it, and nothing that lands here can fix it.
# What the harness owes instead is to say so, once, in the one pass that names everything else.
#
# AND THE REFRESH INTERVAL IS THE LOAD-BEARING HALF. The client re-runs a status-line command on
# a session starting, a new assistant message, a compaction finishing, a mode change, and a
# timer — and clearing the session is not on that list. So without the timer the meter goes on
# displaying the DISCARDED session's context until something is next said, which means the
# instrument that exists to say whether clearing was worth doing reports that the clear did not
# work. Every other state this feature renders — sweeping, archiving, safe to clear — likewise
# changes while the session is IDLE, which is the definition of background work: with no timer
# the pane can only show what was already true at the last assistant message, and "safe to
# clear" would arrive one turn after it stopped being useful.
SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
    WARN "no client settings at $SETTINGS — the context meter is not on the status line" \
         "Point statusLine.command at $SPIRA_HOME/ctx-meter.sh, with refreshInterval beside it."
else
    sl="$(python3 "$SPIRA_HOME/statusline-check.py" "$SETTINGS" "$SPIRA_HOME/ctx-meter.sh")"
    case "$sl" in
        unreadable*) WARN "cannot read $SETTINGS — ${sl#unreadable }" ;;
        absent)      WARN "no status line configured — the context meter is not being shown" \
                          "Add a statusLine object to $SETTINGS whose command is
        $SPIRA_HOME/ctx-meter.sh, with \"refreshInterval\": 5 beside it." ;;
        "other "*)   WARN "the status line runs a different command — the context meter is not being shown" \
                          "Point statusLine.command at $SPIRA_HOME/ctx-meter.sh." ;;
        "ours -")    WARN "the status line has no refreshInterval — it cannot update between turns" \
                          "It will go on showing a cleared session's context until something is next said, and
        the archivist's state will never change on its own. Add \"refreshInterval\": 5 beside
        \"command\" in the statusLine object in $SETTINGS." ;;
        "ours "*)    OK "status line on the context meter, refreshing every ${sl#ours }s" ;;
        *)           WARN "could not judge the status line configuration in $SETTINGS" ;;
    esac
fi

echo
echo "writable state"
if mkdir -p "$SPIRA_RUN" 2>/dev/null && [ -w "$SPIRA_RUN" ]; then OK "runtime directory $SPIRA_RUN"
else FAIL "cannot write $SPIRA_RUN" "Leases, logs and worktrees live here. Set SPIRA_RUN in ${CONF:-spira.conf}."; fi

echo
if [ "$fatal" -gt 0 ]; then
    printf '%d fatal, %d warnings — the harness will not run until the fatals are fixed.\n' "$fatal" "$warn"
    exit 1
fi
printf '0 fatal, %d warnings — the harness can run.\n' "$warn"
exit 0
