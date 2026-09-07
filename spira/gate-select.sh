#!/usr/bin/env bash
#
# gate-select.sh — which suites does this changed-file list actually need?
#
#   gate-select.sh <changed-file-list>   print the suites to run, one path per line
#   gate-select.sh --lint                print every suite missing a `# covers:` line
#
# Run from the root of the tree under judgement. Both forms read the suites in `spira/` of
# the CURRENT DIRECTORY, because the tree the landing gate judges is an extraction of the
# branch and not the installed harness — a selector resolving suites relative to itself
# would answer about the code already in force.
#
# WHY SELECT AT ALL. Landing is serialised and gate-dominated, so every branch pays the same
# bill: one Dolt fixture and every suite in `spira/`, whether it changed a scheduler or a
# sentence in a README. That bill is the cap on how fast finished work reaches the base ref,
# and it is paid most often by the changes least able to break anything.
#
# WHY A DECLARED MAP RATHER THAN A GUESS. A suite names the files it covers, in itself, on a
# `# covers:` line — so the claim lives beside the assertions that back it and moves when
# they do. Deriving the map instead (grep the suite for the scripts it mentions) reads a
# stub named `offender.sh` as a real dependency and misses a file reached through a variable,
# and it is wrong silently in both directions.
#
# THE THREE RULES THAT MAKE UNDER-SELECTION HARD, which is the only failure that matters
# here — running a suite that could not have failed costs seconds, while skipping one that
# would have costs a bad landing on a branch nothing reviews:
#
#   SHARED    a change to lib.sh, conf.sh, testdb.sh or a gate script selects EVERYTHING.
#             These are underneath every suite, so "which suite covers conf.sh" has no
#             useful answer smaller than all of them.
#   UNCLAIMED a changed path that no suite claims selects EVERYTHING. A new file is
#             unmapped by definition, and the safe reading of "nobody said they test this"
#             is not "nobody needs to".
#   INERT     a short, explicit list of paths that cannot change behaviour — prose, the
#             ignore file, images. Only these may select nothing, and they are named here
#             rather than inferred from a directory, because `cockpit/panel/README.md` and
#             `cockpit/panel/src/main.rs` sit in the same directory and are not the same
#             question.
#
# And an ABSENT OR EMPTY file list selects everything. An empty changed-file list is
# indistinguishable from a list that could not be read, and reading it as "nothing changed"
# is how a gate passes every branch (law-absence-needs-a-positive-control).
#
# A suite always covers ITSELF, without having to say so: editing a suite runs it. That also
# keeps a new suite from being read as an unclaimed path on the very commit that adds it,
# which would select everything for no reason.
set -uo pipefail

SUITE_GLOB='spira/test-*.sh'

# Globs are matched with bash pattern matching, NOT filesystem globbing, so `*` matches `/`
# as well: `cockpit/panel/*` covers `cockpit/panel/src/app.rs`. That is deliberate — the
# alternative is every suite spelling out a directory depth it has no reason to know.
#
# READ INTO AN ARRAY, never through an unquoted `$(...)`. Command substitution outside quotes
# is subject to pathname expansion as well as word splitting, so `cockpit/panel/*` expanded
# against the working directory into the files that happen to sit there and then matched none
# of them — the pattern was gone before it was ever compared. `read -ra` splits and does not
# glob, which is the whole difference.
covers_of() {           # covers_of <suite> -> its declared globs into COVERS[], one per element
    local line
    line="$(sed -n 's/^# covers:[[:space:]]*//p' "$1" | head -1)"
    COVERS=()
    [ -n "$line" ] && read -ra COVERS <<< "$line"
    return 0
}

# SHARED — the files that are underneath every suite. Written as patterns so a second gate
# script or a second library lands here without an edit.
is_shared() {           # is_shared <path>
    case "$1" in
        spira/lib.sh|spira/conf.sh|spira/testdb.sh|spira/gate*.sh) return 0 ;;
    esac
    return 1
}

# INERT — deliberately short. Everything absent from it is a behaviour change until a suite
# claims otherwise.
is_inert() {            # is_inert <path>
    case "$1" in
        *.md|.gitignore|LICENSE|LICENSE.*|*.png|*.jpg|*.jpeg|*.gif|*.svg) return 0 ;;
    esac
    return 1
}

all_suites() {
    local t
    for t in $SUITE_GLOB; do [ -e "$t" ] && printf '%s\n' "$t"; done
}

# --lint — every suite must declare what it covers, and the landing gate refuses a branch
# where one does not. Without this the map decays in the one direction nobody notices: a
# suite added without a `# covers:` line claims nothing, so it is selected only when
# something else forces a full run, and it looks exactly like a suite that is passing.
if [ "${1:-}" = "--lint" ]; then
    missing=""
    while IFS= read -r t; do
        covers_of "$t"
        [ "${#COVERS[@]}" -gt 0 ] || missing="$missing $t"
    done < <(all_suites)
    [ -n "$missing" ] || exit 0
    for t in $missing; do echo "gate-select: $t declares no '# covers:' line" >&2; done
    exit 1
fi

mapfile -t SUITES < <(all_suites)

LIST="${1:-}"
if [ -z "$LIST" ] || [ ! -s "$LIST" ]; then
    echo "gate-select: no changed-file list — selecting every suite" >&2
    all_suites
    exit 0
fi

# One pass over the changed files, deciding per file. `selected` is a newline-delimited set;
# `reasons` is what gets printed, because a selection nobody can explain is one nobody will
# trust enough to keep narrow.
selected=""
reasons=""
add() { case "
$selected" in *"
$1
"*) ;; *) selected="$selected$1
" ;; esac; }

while IFS= read -r f; do
    [ -n "$f" ] || continue

    if is_shared "$f"; then
        echo "gate-select: $f is shared by every suite — selecting all" >&2
        all_suites
        exit 0
    fi
    if is_inert "$f"; then
        reasons="${reasons}    $f — inert
"
        continue
    fi

    claimed=0
    for t in "${SUITES[@]}"; do
        # Its own path first, then its declared globs.
        if [ "$f" = "$t" ]; then claimed=1; add "$t"; continue; fi
        covers_of "$t"
        for g in ${COVERS[@]+"${COVERS[@]}"}; do
            # $g is UNQUOTED on purpose: it is a pattern here, and quoting the right-hand
            # side of `==` compares it literally, which matches nothing and reads as a
            # correctly narrow selection.
            if [[ "$f" == $g ]]; then claimed=1; add "$t"; break; fi
        done
    done
    if [ "$claimed" = 0 ]; then
        echo "gate-select: $f is claimed by no suite — selecting all" >&2
        all_suites
        exit 0
    fi
    reasons="${reasons}    $f
"
done < "$LIST"

if [ -n "$reasons" ]; then
    printf 'gate-select: from the changed files:\n%s' "$reasons" >&2
fi
printf '%s' "$selected"
