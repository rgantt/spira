#!/usr/bin/env bash
#
# confine.sh — a spike may leave a branch; it must not leave a merge.
#
#   confine.sh <bead-id> <branch> <repo-path> <base-ref>
#
# Exits 0 if this branch is allowed to land, and 1 having printed WHICH paths are why not.
# Run by landing.sh immediately before the repository's own gate, for every branch of every
# persona — a bead that is not a spike is allowed through untouched, which is what makes this
# safe to put on the shared path rather than on the spike's own.
#
# WHAT IT IS FOR
# --------------
# A spike is closed by its DOCUMENT. It is allowed the full toolset, including an editor and
# a shell, because for most interesting questions the only honest answer to "is this feasible"
# comes from trying it — a spike that may not build cannot tell "this is hard" from "I could
# not find out", and reports the second as the first. But a proof of concept is EVIDENCE for
# the document, not a change to the repository: it belongs on a branch of its own, named in
# the document, and unmerged.
#
# Nothing else in the harness can hold that line. The landing worker merges the branch of any
# closed bead into the base and pushes it, so a spike that committed its experiment beside its
# write-up would land the experiment, and every downstream check would pass it: the aeon
# committed, the commit names the bead, the gate ran, the branch landed. The refusal has to be
# here, where the diff against the base is still readable.
#
# A FENCE, NOT A WALL. It refuses politely and says exactly which paths offended, so the next
# aeon on the bead can move them to a branch of their own and finish; and an installation that
# wants a spike to land more than a document says so in SPIRA_SPIKE_PATHS rather than deleting
# this. The override is configuration, which is the form a fence's override should take.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ID="${1:-}"; BR="${2:-}"; REPO="${3:-}"; BASE="${4:-}"; labels="${5:-}"
[ -n "$ID" ] && [ -n "$BR" ] && [ -n "$REPO" ] && [ -n "$BASE" ] \
    || die "usage: confine.sh <bead-id> <branch> <repo-path> <base-ref> [labels]"

# ---- is this a spike at all? ----------------------------------------------------------
# Asked of the BEAD, never of the branch name. A branch is a string an aeon chose and a
# successor bead may inherit; the label is what the harness dispatched on, so it is the only
# thing that answers "was this worked by the persona whose deliverable is a document".
#
# AND AN UNREADABLE BEAD IS NOT A SPIKE. Failing open is right here and only here: this check
# stands between finished work and its base, so a bd that times out must not become a harness
# that silently stops landing everything. The confinement is a discipline on one persona, not
# a security boundary.
# THE LABELS MAY BE HANDED IN, and the landing worker hands them in because it already has
# the bead's JSON open for its status and its repository. This runs once per closed branch per
# repository every two minutes; a second query for a fact the caller is already holding is
# thousands of round trips a day to learn nothing. Asking for itself is what keeps the script
# runnable by hand and testable without a caller.
if [ -z "$labels" ]; then
    labels="$(bdjson show "$ID" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
d = d if isinstance(d, list) else [d]
if d: print(" ".join(d[0].get("labels") or []))' 2>/dev/null)"
fi
case " $labels " in
    *" $SPIRA_SPIKE_LABEL "*) ;;
    *) exit 0 ;;
esac

# ---- what did it change? ---------------------------------------------------------------
# THREE DOTS. `diff A..B` is every difference between the two tips, so a base that moved
# ahead would report files the branch never touched as the branch's offence; `diff A...B` is
# the diff from their merge base, which is the branch's own work and nothing else. The
# distinction is the whole check: landing rebases first, but this runs against whatever
# ancestry it is handed and must be right without that assumption.
changed="$(git -C "$REPO" diff --name-only "$BASE...$BR" 2>/dev/null)"
if [ -z "$changed" ]; then
    # Nothing to confine. Not an error and not a pass worth reporting — a branch with no diff
    # against its base is landing's problem, not this one's.
    exit 0
fi

# ---- is all of it inside the allowed trees? ---------------------------------------------
# Prefix match on a PATH BOUNDARY, not on a string. `docs/spikes` must admit
# `docs/spikes/q.md` and the file `docs/spikes` itself, and must not admit
# `docs/spikes-scratch/poc.rs` — which is exactly the name an aeon would reach for when told
# to keep its experiment beside its notes.
outside=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    allowed=0
    for p in $SPIRA_SPIKE_PATHS; do
        p="${p%/}"
        [ -n "$p" ] || continue
        if [ "$f" = "$p" ] || [ "${f#"$p"/}" != "$f" ]; then allowed=1; break; fi
    done
    [ "$allowed" = 1 ] || outside="$outside $f"
done <<< "$changed"

[ -z "$outside" ] && exit 0

OUTSIDE_LIST="$(printf '%s\n' $outside | sed 's/^/    /')"

# THE REFUSAL NAMES THE PATHS AND THE REMEDY. A note saying "failed confinement" tells its
# next aeon nothing it can act on, and after three of those the bead poisons and reaches the
# operator with a reason that is not a reason.
cat <<MSG
$BR is a spike branch and changes files outside the trees a spike may land.

A spike is closed by its document. A proof of concept is evidence FOR that document: keep it
on a branch of its own, name that branch in the document, and leave it unmerged. A spike may
leave a branch and must not leave a merge.

may land: $SPIRA_SPIKE_PATHS
outside:
$OUTSIDE_LIST

Move those commits to a branch of their own, leave $SPIRA_SPIKE_DIR and the sources you
preserved on $BR, and close the bead again. If this repository genuinely expects a spike to
land more than a document, widen SPIRA_SPIKE_PATHS rather than working around this.
MSG
exit 1
