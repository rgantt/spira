#!/usr/bin/env bash
#
# release.sh — cut and inspect Spira release units.
#
#   release.sh cut [<name-or-path>]
#   release.sh show <tag>
#
# A release unit is an annotated git tag that names every bead id whose
# commit reached the base branch since the previous release tag for the
# same repository. The tag is simultaneously the review unit, the deploy
# unit and the revert unit: to roll back, promote.sh to the previous tag.
#
# NAMING. Tags follow the form spira-release-<reponame>-<YYYYMMDDTHHMMSSZ>.
# The repo name comes from the repo-map. If two cuts land in the same UTC
# second a counter suffix (-2, -3, ...) is appended.
#
# THE BASE REF comes from spira_landref, never assumed to be 'main' — three
# of seven repositories here use 'master'.
#
# cut  [<name-or-path>]  Tag the HEAD of the base branch of the named
#                        repository (default: the home repository). Prints
#                        the new tag name on stdout. Zero-landed case: says
#                        so on stderr and exits 0 without creating a tag.
#
# show <tag>             Print the bead ids and commits in the named release
#                        tag. The repository is inferred from the tag message.
#
# EXIT   0  success (cut: tagged or nothing to tag; show: tag resolved)
#        1  error or refused
#        2  usage
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

# ---------------------------------------------------------------------------
# cut — create a release tag over beads landed since the previous one.
# ---------------------------------------------------------------------------
do_cut() {
    local arg="${1:-}"

    # Resolve repo path and name from the argument (name, path, or default).
    local name="" repo=""
    case "$arg" in
        "")  name="$(spira_home_repo)" ;;
        */*) repo="$arg" ;;
        *)   name="$arg" ;;
    esac
    if [ -z "$repo" ]; then
        repo="$(repo_root "$name")" || {
            printf 'release: cannot find checkout for repository: %s\n' "$name" >&2
            exit 1
        }
    fi
    [ -n "$name" ] || name="$(repo_name_at "$repo" 2>/dev/null)" || name="$(basename "$repo")"

    # Resolve the base ref — never assume 'main'.
    local base
    base="$(spira_landref "$repo")" || {
        printf 'release: cannot determine base ref for %s\n' "$name" >&2
        exit 1
    }
    local sha
    sha="$(git -C "$repo" rev-parse --verify "$base" 2>/dev/null)" || {
        printf 'release: cannot resolve base ref %s in %s\n' "$base" "$repo" >&2
        exit 1
    }

    # Find the most recent release tag for this repository (if any).
    local tag_prefix="spira-release-${name}-"
    local prev_tag
    prev_tag="$(git -C "$repo" tag -l "${tag_prefix}*" | sort | tail -1)"

    # Collect commit subjects since the previous tag (or from the beginning).
    local subjects
    if [ -n "$prev_tag" ]; then
        subjects="$(git -C "$repo" log --format='%s' "${prev_tag}..${base}" 2>/dev/null)" || subjects=""
    else
        subjects="$(git -C "$repo" log --format='%s' "$base" 2>/dev/null)" || subjects=""
    fi

    # Extract bead ids. The id prefix comes from the harness configuration so
    # a colleague with a different prefix does not need to patch this script.
    local id_prefix="${SPIRA_ID_PREFIX:-sp}"
    local ids
    ids="$(printf '%s\n' "$subjects" \
        | grep -oE "${id_prefix}-[a-z0-9]+(\.[0-9]+)?" \
        | sort -u)" || ids=""

    if [ -z "$ids" ]; then
        printf 'release: no beads landed since %s — no tag created\n' \
            "${prev_tag:-(none)}" >&2
        exit 0
    fi

    # Generate a timestamp-based tag name; handle the rare same-second collision.
    local ts; ts="$(date -u '+%Y%m%dT%H%M%SZ')"
    local tagname="${tag_prefix}${ts}"
    local n=1
    while git -C "$repo" rev-parse --verify "refs/tags/$tagname" >/dev/null 2>&1; do
        n=$((n + 1))
        tagname="${tag_prefix}${ts}-${n}"
    done

    # Build the tag message. One 'bead:' line per id so show can grep it.
    {
        printf 'spira release: %s\n' "$name"
        printf 'base: %s (%s)\n' "$base" "$sha"
        printf 'prev: %s\n' "${prev_tag:-(none)}"
        printf '\n'
        printf '%s\n' "$ids" | while IFS= read -r id; do
            printf 'bead: %s\n' "$id"
        done
    } | git -C "$repo" tag -a "$tagname" "$sha" -F - || {
        printf 'release: could not create tag %s\n' "$tagname" >&2
        exit 1
    }

    printf '%s\n' "$tagname"
}

# ---------------------------------------------------------------------------
# show — resolve a release tag to its bead ids and commits.
# ---------------------------------------------------------------------------
do_show() {
    local tag="${1:-}"
    [ -n "$tag" ] || { printf 'usage: release.sh show <tag>\n' >&2; exit 2; }

    # Find which managed repository holds this tag.
    local repo="" name n
    for n in $(spira_repos); do
        local r; r="$(repo_root "$n" 2>/dev/null)" || continue
        if git -C "$r" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
            repo="$r"; name="$n"; break
        fi
    done

    if [ -z "$repo" ]; then
        printf 'release: tag %s not found in any managed repository\n' "$tag" >&2
        exit 1
    fi

    # Read the tag message via 'git tag -l --format'.
    local msg
    msg="$(git -C "$repo" tag -l --format='%(contents)' "$tag" 2>/dev/null)"

    if [ -z "$msg" ]; then
        printf 'release: %s is a lightweight tag; no bead list embedded\n' "$tag" >&2
        exit 1
    fi

    # Print the full tag message body.
    printf '%s\n' "$msg"

    # Extract bead ids and the previous tag from the message.
    local bead_ids prev_tag
    bead_ids="$(printf '%s\n' "$msg" | grep '^bead: ' | sed 's/^bead: //')"
    prev_tag="$(printf '%s\n' "$msg" | grep '^prev: ' | head -1 | sed 's/^prev: //')"

    if [ -z "$bead_ids" ]; then
        printf '(no beads recorded in this tag)\n'
        return
    fi

    # Resolve the commit this tag points to.
    local tag_sha
    tag_sha="$(git -C "$repo" rev-parse "${tag}^{commit}" 2>/dev/null)" || tag_sha=""

    # Build the commit range: from the previous tag (exclusive) to this tag.
    local from_ref=""
    if [ -n "$prev_tag" ] && [ "$prev_tag" != "(none)" ]; then
        from_ref="${prev_tag}.."
    fi
    local range="${from_ref}${tag_sha:-$tag}"

    printf '\ncommits:\n'
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        # Use --fixed-strings to treat the bead id as a literal, not a regex.
        local commits
        commits="$(git -C "$repo" log --fixed-strings --format='%h %s' "$range" --grep="$id" \
            2>/dev/null)"
        if [ -n "$commits" ]; then
            while IFS= read -r line; do
                printf '  %s  %s\n' "$id" "$line"
            done <<< "$commits"
        else
            printf '  %s  ?\n' "$id"
        fi
    done <<< "$bead_ids"
}

# ---------------------------------------------------------------------------
CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in
    cut)  do_cut "$@" ;;
    show) do_show "$@" ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *)
        printf 'usage: release.sh cut [<name-or-path>]\n' >&2
        printf '       release.sh show <tag>\n' >&2
        exit 2
        ;;
esac
