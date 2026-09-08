#!/usr/bin/env bash
#
# skew.sh — is the harness that RUNS the harness that LANDED?
#
#   skew.sh check [--escalate]             audit this box; escalate on divergence (only with --escalate)
#   skew.sh units                          are the installed units what the templates render?
#   skew.sh refresh [repo]                 fast-forward the checkout to its base ref
#   skew.sh copies                         every mapped repository carrying a harness copy
#   skew.sh foreign <repo> <base> <ref>    may this branch land? — the landing gate's fence
#
# WHAT THIS IS FOR
# ----------------
# Landing and running are two claims, and a harness that verifies only the first has a blind
# spot exactly the width of the second. A bead is judged against the branch it named; nothing
# afterwards asks whether the copy the service manager executes IS that branch. This is
# law-closed-is-not-landed one layer further out — landed is not in effect.
#
# It is silent by construction. When the harness exists in two trees — its own repository and
# a copy vendored into another — work lands in one of them and the other goes on running.
# Every check passes, because the tree that was edited is self-consistent: the suites there
# are green, the gate there is satisfied, the commit is on the branch it named. The only
# thing wrong is that nothing executes it, and no test can see that from inside either tree.
# It has caught an unattended worker and a human on the same day, so it is not carelessness;
# it is a property of having two copies and no comparison between them.
#
# THREE FINDINGS, and they are three different faults with three different fixes:
#
#   BEHIND   the copy in force is missing commits that are on the ref it lands on. Somebody
#            landed work and nothing pulled it here.
#   DIRTY    the copy in force carries modifications that are on no branch at all. Whatever
#            is executing was reviewed by nobody.
#   COPY     another mapped repository carries a second harness. Work aimed at the harness
#            can land there, pass everything, and never run.
#   STALE    the installed systemd units differ from what the templates in this checkout
#            would render. A template changed, and nobody re-ran install.sh.
#
# `check` REPORTS; `refresh` REPAIRS — but only by fast-forward, and only when the checkout is
# clean and on the base branch. A dirty tree or a detached HEAD is never clobbered, and a
# non-fast-forward is always refused; the worst a refresh can do is advance a clean checkout
# that was already on the right branch. Deleting somebody's second copy is not a check's
# decision to make.
#
# EXIT   0  checked, and the copy in force is the code that landed
#        1  checked, and it is not — the finding is on stdout; with --escalate it has been escalated
#        3  could not check — said out loud, never a silent pass
#              (law-absence-needs-a-positive-control)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

EXCLUDE="$(dirname "$0")/exclude.sh"

# harness_in <repo-path> -> the harness directories in its WORKING TREE, one per line.
# Exit 1 when it holds none, which is the ordinary answer for most repositories.
harness_in() {
    local root="$1"
    [ -e "$root/.git" ] || return 1
    git -C "$root" ls-files 2>/dev/null | bash "$EXCLUDE" harness-in 2>/dev/null
}

# harness_in_ref <repo-path> <ref> -> the harness directories in that REF, one per line.
# The ref and not the checkout: the question a landing gate asks is what the repository would
# contain after this branch merges, and the branch may be the thing that adds the copy.
harness_in_ref() {
    local root="$1" ref="$2"
    git -C "$root" ls-tree -r --name-only "$ref" 2>/dev/null | bash "$EXCLUDE" harness-in 2>/dev/null
}

# =======================================================================================
# foreign — the landing gate's fence.
#
# A branch in a repository that is NOT the harness's own may not change files inside a copy
# of the harness. Correct work landing there is work nothing will execute, and the aeon that
# wrote it has no way to tell: it committed, on a branch, naming its bead, and every suite in
# the tree it edited passed.
#
# IT FAILS CLOSED, including on its own confusion. A fence that cannot tell whether the rule
# was broken must not answer "not broken" — that is the one output a broken fence produces
# every time.
#
# IT IS SCOPED TO THE COPY, NOT TO THE REPOSITORY. A repository may legitimately carry a
# vendored harness and still have a thousand files of its own; only changes INSIDE the copy
# are the offence, so ordinary work in a repository that happens to hold one is untouched.
# =======================================================================================
foreign() {
    local repo="${1:-}" base="${2:-}" ref="${3:-}" dirs d f hit="" home
    [ -n "$repo" ] && [ -n "$base" ] && [ -n "$ref" ] || {
        echo "skew: foreign needs <repo> <base> <ref>" >&2; return 1; }

    # THE OVERRIDE IS HONOURED HERE, in the fence itself, not in the one caller. A fence is a
    # polite refusal and not a wall, and an override that only works from whichever program
    # happened to invoke it is an override nobody finds when they need it.
    [ -n "${SPIRA_ALLOW_FOREIGN_HARNESS:-}" ] && return 0

    # The harness's own repository is exempt, and that is the whole point of the rule rather
    # than an exception to it: this fence exists to send harness work THERE.
    if spira_same_repo "$repo" "$SPIRA_REPO"; then return 0; fi

    dirs="$(harness_in_ref "$repo" "$ref")"
    [ -n "$dirs" ] || return 0          # no copy in that ref; nothing this fence judges

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            case "$d" in
                .) hit="$hit$f"$'\n' ;;
                *) case "$f/" in "$d"/*) hit="$hit$f"$'\n' ;; esac ;;
            esac
        done <<< "$dirs"
    done < <(git -C "$repo" diff --name-only "$base...$ref" 2>/dev/null)

    [ -n "$hit" ] || return 0
    printf '%s' "$hit" | sort -u
    home="$(spira_home_repo)"
    {
        echo
        echo "REFUSED by skew.sh — this branch changes a COPY of the harness."
        echo
        printf '%s' "$hit" | sort -u | sed 's/^/    /'
        echo
        echo "Those paths are inside a vendored copy of the harness, in a repository that is"
        echo "not the harness's own. The harness in force is ${SPIRA_REPO}, so work landing"
        echo "here would pass its gate, close its bead, and never run. Nothing downstream can"
        echo "tell the difference: the tree that was edited is self-consistent."
        echo
        echo "Move the change to repo:${home} and re-cut the branch there. If the vendored copy"
        echo "is what you actually meant to change, say so:  SPIRA_ALLOW_FOREIGN_HARNESS=1"
    } >&2
    return 1
}

# =======================================================================================
# copies — every mapped repository that carries a harness, and whether it is ours.
#
# One line per copy: `<repo-name> <path> <harness-dir> self|second`. A repository the map
# names but this box does not have is skipped in silence, because a map is shared across
# boxes and a row for another machine is not a fault here.
# =======================================================================================
copies() {
    local n p d found=0
    for n in $(repo_names); do
        p="$(repo_root "$n" 2>/dev/null)" || continue
        [ -n "$p" ] && [ -e "$p/.git" ] || continue
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            found=1
            if spira_same_repo "$p" "$SPIRA_REPO"; then
                printf '%s %s %s self\n' "$n" "$p" "$d"
            else
                printf '%s %s %s second\n' "$n" "$p" "$d"
            fi
        done < <(harness_in "$p")
    done
    [ "$found" = 1 ]
}

# =======================================================================================
# check — the standing audit.
#
# Read-only by default: it reports findings to stdout and exits 0/1/3 but does NOT file an
# ask. Escalation is behind --escalate, which only the timer unit passes. A read that writes
# as a side effect was the fault: two hand inspections filed duplicate asks (sp-624f).
# =======================================================================================
check() {
    local do_escalate=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --escalate) do_escalate=1; shift ;;
            *) echo "skew: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    local findings="" hard=0 base remote behind dirty control c_name c_path c_dir c_kind
    local cond_behind=0 cond_dirty=0 cond_copy=0 cond_stale=0

    # THE POSITIVE CONTROL, FIRST AND UNCONDITIONALLY. Every finding below is an absence
    # claim resting on one matcher, and a matcher that has stopped matching reports a clean
    # box in exactly the state this exists to catch. So prove it can find the harness it is
    # running from before believing it about anywhere else.
    control="$(harness_in "$SPIRA_REPO")"
    if [ -z "$control" ]; then
        echo "skew: cannot find the harness in ${SPIRA_REPO}, which is the tree running this check." >&2
        echo "skew: Either the matcher has stopped matching, or that path is not a checkout of" >&2
        echo "skew: the harness at all." >&2
        echo "skew: Refusing to report a clean box from a check that could not have found anything." >&2
        return 3
    fi

    # ---------------------------------------------------------------- BEHIND
    # Against the remote-tracking ref, refreshed. A verdict of "in effect" read from a ref
    # nobody has fetched is a verdict about this box's memory of the remote, and the whole
    # failure being checked for is a tree that has stopped keeping up.
    if base="$(spira_landref "$SPIRA_REPO")"; then
        remote="$(ref_remote "$base" 2>/dev/null)" || remote=""
        if [ -n "$remote" ]; then
            timeout "${SPIRA_SKEW_FETCH_TIMEOUT:-60}" \
                git -C "$SPIRA_REPO" fetch -q --no-write-fetch-head "$remote" 2>/dev/null || {
                # A fetch that failed is not a pass. It can still prove divergence — a ref
                # already ahead stays ahead — but it cannot prove the absence of any, so a
                # clean answer below is downgraded to "could not check".
                findings="${findings}CANNOT-FETCH could not reach $remote; the verdict below is against this box's last fetch of $base
"; }
        fi
        behind="$(git -C "$SPIRA_REPO" rev-list --count "HEAD..$base" 2>/dev/null || echo 0)"
        if [ "${behind:-0}" -gt 0 ]; then
            hard=1; cond_behind=1
            findings="${findings}BEHIND $SPIRA_REPO is $behind commit(s) behind $base
$(git -C "$SPIRA_REPO" log --oneline --no-decorate -20 "HEAD..$base" 2>/dev/null | sed 's/^/    /')
"
        fi
    else
        findings="${findings}CANNOT-RESOLVE no ref could be resolved for what $SPIRA_REPO lands on, so 'is it current' has no answer
"
    fi

    # ---------------------------------------------------------------- DIRTY
    # Tracked files only. An operator's untracked notes beside the code are their own
    # business; a MODIFIED tracked file is code in force that is on no branch anywhere.
    dirty="$(git -C "$SPIRA_REPO" status --porcelain --untracked-files=no 2>/dev/null)"
    if [ -n "$dirty" ]; then
        hard=1; cond_dirty=1
        findings="${findings}DIRTY $SPIRA_REPO carries modifications that are on no branch
$(printf '%s\n' "$dirty" | head -20 | sed 's/^/    /')
"
        # Among dirty files, identify those where the working tree drops lines from the
        # base ref. Comparing against $base (the remote-tracking ref, already fetched)
        # rather than HEAD means a tree that is both DIRTY and BEHIND is not understated:
        # measuring against HEAD alone reported 330 lines across 16 files; against
        # origin/main it was 1,840 lines across 91 files — wrong by 5x, precise-looking.
        local drop_files="" drop_ref drop_path
        drop_ref="${base:-HEAD}"
        while IFS= read -r drop_path; do
            [ -n "$drop_path" ] || continue
            if git -C "$SPIRA_REPO" diff "$drop_ref" -- "$drop_path" 2>/dev/null \
                    | grep -q '^-[^-]'; then
                drop_files="${drop_files}    $drop_path"$'\n'
            fi
        done < <(git -C "$SPIRA_REPO" diff --name-only HEAD 2>/dev/null)
        if [ -n "$drop_files" ]; then
            findings="${findings}FILES-DROPPING-COMMITTED-LINES dirty files whose working tree drops lines from ${drop_ref}:
$drop_files"
        fi
    fi

    # ---------------------------------------------------------------- COPY
    while read -r c_name c_path c_dir c_kind; do
        [ "${c_kind:-}" = second ] || continue
        hard=1; cond_copy=1
        findings="${findings}COPY repo:$c_name carries a second harness at $c_path/$c_dir
    Work aimed at the harness can land there, pass its gate, and never run.
"
    done < <(copies 2>/dev/null)

    # ---------------------------------------------------------------- STALE
    # The installed systemd units may differ from what the templates in this checkout would
    # render — a template changed and nobody re-ran install.sh. install.sh --diff already
    # finds this state; nothing ran it on a timer until now.
    #
    # IT DOES NOT REPAIR (the operator, over sp-jo6f: REPORT ONLY). Installing units acts on
    # the operator's live service manager, an authority this harness has declined to take.
    local stale_out stale_rc installer
    installer="$(cd "$SPIRA_HOME/../systemd" 2>/dev/null && pwd -P)/install.sh"
    if [ ! -r "$installer" ]; then
        findings="${findings}CANNOT-DIFF install.sh is missing at $installer — unit staleness has no answer
"
    else
        stale_out="$(bash "$installer" --diff 2>&1)"; stale_rc=$?
        if [ "$stale_rc" != 0 ]; then
            hard=1; cond_stale=1
            # Detect un-suffixed legacy units from before per-instance naming. When they
            # are present, --diff reports the new per-instance names as MISSING. install.sh
            # migrates these on the next run (disables the old ones first, then enables the
            # new ones). Name them explicitly so the operator knows what is happening.
            local _legacy_survivors _legacy_note=""
            _legacy_survivors="$(systemctl --user list-unit-files --no-legend \
                'spira-*.service' 'spira-*.timer' 2>/dev/null \
              | tr -s ' \t' '\n\n' \
              | grep -E '^spira-[a-z][^@]*\.(service|timer)$' \
              | grep -v -- "-${SPIRA_INSTANCE:-prod}\." | sort -u || true)"
            if [ -n "$_legacy_survivors" ]; then
                _legacy_note="    NOTE: un-suffixed legacy units present — install.sh will migrate them:
$(printf '%s\n' "$_legacy_survivors" | head -10 | sed 's/^/        /')"$'\n'
            fi
            findings="${findings}STALE installed systemd units differ from what this checkout renders
$(printf '%s\n' "$stale_out" | head -40 | sed 's/^/    /')
${_legacy_note}    Re-run $installer to bring the installed units into line with the templates.
"
        fi
    fi

    if [ -z "$findings" ]; then
        printf 'skew: in effect — %s is %s, clean, the only harness the map names, and units match\n' \
            "$SPIRA_REPO" "${base:-its base ref}"
        return 0
    fi

    printf '%s' "$findings"

    # A CANNOT- line ON ITS OWN is not a verdict in either direction, and must not be
    # escalated as one: the operator would be handed a decision about a divergence nobody has
    # established. It is also not a pass. Say so, and exit 3.
    if [ "$hard" = 0 ]; then
        echo "skew: the check could not complete — this is not a clean verdict" >&2
        return 3
    fi
    if [ "$do_escalate" = 1 ]; then
        # Fingerprint the CONDITION (which finding types are present), not the findings text.
        # Measurements in the findings text — commit count, file list — change every pass while
        # the condition stays constant, which produced a new ask every hour as the repo fell
        # further behind (sp-624f). The condition key is versioned so a stamp written by the
        # old scheme (a bare cksum) cannot match and causes one re-escalation on upgrade.
        local condition_key="v2:BEHIND=${cond_behind} DIRTY=${cond_dirty} COPY=${cond_copy} STALE=${cond_stale}"
        escalate "$condition_key" "$findings"
    fi
    return 1
}

# =======================================================================================
# escalate — once per distinct CONDITION, not once per pass.
#
# Keyed on which finding TYPES are present (BEHIND/DIRTY/COPY/STALE yes/no), not on the
# findings text. The text carries measurements — commits behind, file list — that drift every
# pass while the condition stays constant, which produced a new ask every hour as the repo
# fell further behind (sp-624f). The condition key is versioned (v2:) so a stamp written by
# the old scheme (a bare cksum number) cannot match and causes one re-escalation on upgrade.
# =======================================================================================
escalate() {
    local condition_key="$1" findings="$2"
    local stamp="$SPIRA_RUN/skew.escalated" prev=""
    [ -f "$stamp" ] && prev="$(cat "$stamp" 2>/dev/null)"
    # A stamp without the v2: prefix was written by the old fingerprint scheme; treat it as
    # absent rather than matching — one re-escalation on upgrade is correct.
    [[ "${prev:-}" = v2:* ]] || prev=""
    [ "$condition_key" = "$prev" ] && return 0
    mkdir -p "$SPIRA_RUN" 2>/dev/null
    printf '%s' "$condition_key" > "$stamp"

    # Stdout goes to skew.log under the service unit. Stderr does too (both streams are
    # captured), but everything below writes to stdout so the delivery path is explicit and
    # does not depend on StandardError being redirected — which has changed once already.
    if [ ! -x "${SPIRA_NOTIFY:-}" ]; then
        echo "skew: no escalation path at ${SPIRA_NOTIFY:-(unset)} — the finding above reaches nobody"
        return 1
    fi

    # The installer sits beside the harness directory, not inside it, so it is derived
    # rather than written — the two layouts put it in different places and a hardcoded one
    # would be wrong in whichever the reader is standing in.
    local installer; installer="$(cd "$SPIRA_HOME/../systemd" 2>/dev/null && pwd -P)/install.sh"

    local notify_out notify_rc
    notify_out="$("$SPIRA_NOTIFY" add \
        "The Spira copy in force is not the code that landed" \
        --default "pull $SPIRA_REPO onto its base ref; install.sh now also refuses when the checkout is behind — wait for any live aeons to finish (install.sh refuses while spira-aeon-*.service units are active too), then re-run $installer; pass SPIRA_INSTALL_FORCE=1 to override both refusals; if a second harness is named below, delete that copy so the repository it sits in carries none" \
        --why "beads can be closed, gated and merged while the behaviour they changed never takes effect — the tree that was edited is self-consistent, so nothing downstream reports a fault" \
        --evidence "$findings" 2>&1)"; notify_rc=$?

    if [ "$notify_rc" != 0 ]; then
        echo "skew: escalation failed (rc=$notify_rc): $notify_out"
        return "$notify_rc"
    fi
    echo "skew: escalated — $notify_out"
}

# =======================================================================================
# refresh — fast-forward a checkout to its base ref.
#
# Called unconditionally by the landing pass, so a base ref that moved by ANY route — a
# branch merged, a push from another box, a PR merged on GitHub, a hand-landing — is picked
# up within one pass rather than waiting for `check` to escalate it an hour later.
#
# THE GUARDS ARE THE WHOLE POINT. ff-only, clean-tracked-tree, and on-the-base-branch: any
# violation means something a mechanical advance must not override. A declined refresh names
# which condition refused it, because a refresh that stopped happening is indistinguishable
# in the log from one with nothing to do — the silence that cost eight hours on landing.sh.
#
# TRACKED FILES ONLY. An operator's untracked notes beside the code are their own business;
# a MODIFIED tracked file is code in force that is on no branch. This is the same check as
# `check` above, and the two must agree — --untracked-files=no in both.
# =======================================================================================
refresh() {
    local repo="${1:-$SPIRA_REPO}" base base_branch remote behind dirty current
    [ -e "$repo/.git" ] || {
        echo "skew: refresh: $repo is not a git checkout"; return 1; }
    base="$(spira_landref "$repo")" || {
        echo "skew: refresh: cannot resolve the ref $repo lands on"; return 1; }
    base_branch="$(ref_branch "$base")"
    remote="$(ref_remote "$base" 2>/dev/null)" || remote=""
    [ -n "$remote" ] && git -C "$repo" fetch -q --no-write-fetch-head "$remote" 2>/dev/null

    behind="$(git -C "$repo" rev-list --count "HEAD..$base" 2>/dev/null || echo 0)"
    [ "${behind:-0}" -gt 0 ] || return 0

    dirty="$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)"
    if [ -n "$dirty" ]; then
        echo "skew: refresh declined — tracked files are modified"; return 1; fi

    current="$(git -C "$repo" branch --show-current 2>/dev/null)"
    if [ "$current" != "$base_branch" ]; then
        echo "skew: refresh declined — checkout is on ${current:-a detached HEAD}, not $base_branch"; return 1; fi

    if ! git -C "$repo" merge --ff-only -q "$base" 2>/dev/null; then
        echo "skew: refresh declined — cannot fast-forward to $base"; return 1; fi

    echo "skew: refreshed to $base ($behind commit(s))"
    return 0
}

# =======================================================================================
# units — are the installed units what the templates render?
#
# EXIT   0  the installed units match
#        1  at least one differs — the output names which
#        3  the check itself could not run (install.sh missing, render failure)
#
# This is the standalone entry point; `check` includes it in its audit. It costs no database
# call: install.sh --diff renders templates from conf.sh and diffs files on disk.
# =======================================================================================
units() {
    local installer stale_out stale_rc
    installer="$(cd "$SPIRA_HOME/../systemd" 2>/dev/null && pwd -P)/install.sh"
    if [ ! -r "$installer" ]; then
        printf 'skew: install.sh is missing at %s — unit staleness has no answer\n' "$installer" >&2
        return 3
    fi
    stale_out="$(bash "$installer" --diff 2>&1)"; stale_rc=$?
    if [ "$stale_rc" = 0 ]; then
        printf 'skew: units — installed units match what this box renders\n'
        return 0
    fi
    printf '%s\n' "$stale_out"
    return 1
}

case "${1:-check}" in
    check)   [ "${1:-}" = check ] && shift; check "$@" ;;
    units)   units ;;
    refresh) shift; refresh "$@" ;;
    copies)  copies || { echo "skew: no mapped repository carries a harness — the map or the matcher is wrong" >&2; exit 3; } ;;
    foreign) shift; foreign "$@" ;;
    *)       sed -n '3,9p' "$0" >&2; exit 2 ;;
esac
