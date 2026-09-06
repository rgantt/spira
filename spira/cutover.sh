#!/usr/bin/env bash
#
# cutover.sh — Step 3's measurement: LANDED COMMITS per harness, Spira against Gas Town.
#
#   cutover.sh repos              the resolved repository and landing-ref table — the probe
#   cutover.sh window             when the cutover window opened, closes, and where it is now
#   cutover.sh report             the comparison
#   cutover.sh verdict            exit 0 only when the window has closed AND the crossover holds
#
#   --no-fetch                    skip the fetch; every ref is then as stale as the last one
#   --since <iso-date>            override the window start (report only; verdict derives it)
#   --window-days <n>             override the seven days (default SPIRA_CUTOVER_DAYS)
#
# WHY THIS EXISTS. sp-builder-cutover is the gate on retiring Gas Town: *"Run one builder on
# the aeon runner beside Gas Town for a week. Compare LANDED COMMITS, not activity."* Activity
# is what both systems have always had plenty of — 14 standing agents, 102 queued messages, six
# stranded convoys — and none of it is work that reached main. The commit graph is the only
# record that cannot be talked up, and it is retrospective, which is what makes a week-long
# comparison computable in one pass at the end rather than needing a daily snapshot nobody
# would trust.
#
# THE WINDOW OPENS BY ITSELF. Its start is the author date of the earliest aeon commit on any
# landing ref — a fact in the graph, not a file. That matters: a window whose bounds are stored
# can be edited after the outcome is known, and the one number here that decides whether a
# system gets switched off is exactly the one nobody should be able to nudge. It also cannot be
# accidentally reset, which a runtime file under .runtime/ very much can.
#
# A FAILED PROBE IS NEVER A ZERO. An unresolvable landing ref, a rig with no checkout, a fetch
# that failed — each renders `?` and makes the verdict undecided. Zero landed commits and "I
# could not look" are opposite readings, and the first one licenses a retirement.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

TOWN="${GT_TOWN:-$SPIRA_TOWN}"
WORKSPACES="$SPIRA_WORKSPACES"
DAYS="${SPIRA_CUTOVER_DAYS:-7}"
# The crossover bar, as Spira-commits ÷ Gas-Town-commits. 1.0 is parity: Spira lands at least
# as much as the system it replaces. Configurable because it is a judgement about how much
# proof is enough, and that judgement is the operator's — but it is not silently adjustable, because
# the report prints the value it used.
RATIO="${SPIRA_CUTOVER_RATIO:-1.0}"
FETCH=1
SINCE=""

cmd="${1:-report}"; shift 2>/dev/null
while [ $# -gt 0 ]; do
    case "$1" in
        --no-fetch)     FETCH=0 ;;
        --since)        SINCE="${2:?--since needs a date}"; shift ;;
        --window-days)  DAYS="${2:?--window-days needs a number}"; shift ;;
        *) die "unknown flag: $1" ;;
    esac
    shift
done

# ======================================================================================
# Repository discovery. Derived from Gas Town's own rig configuration and from the chamber,
# never from a list of paths in this file — a hardcoded list goes stale in the direction that
# under-counts, and an under-count of Gas Town is what licenses retiring it.
# ======================================================================================

# Compare remote URLs by what they address, not by how they are spelt. The same repository is
# `git@github.com:x/y.git`, `https://github.com/x/y` and `ssh://git@github.com/x/y` depending on
# who cloned it.
norm_url() {
    sed -e 's#^ssh://##' -e 's#^https\{0,1\}://##' -e 's#^git@\([^:]*\):#\1/#' \
        -e 's#\.git$##' -e 's#/$##' <<< "${1:-}"
}

# The remote in <repo> that addresses <url>, if any. Gas Town's rigs do not agree on a remote
# name: a remote need not be called `origin`. Assuming it reported zero landed commits for a
# repository with real work in it.
remote_for() {           # remote_for <repo-path> <url> -> remote name on stdout
    local p="$1" want; want="$(norm_url "$2")"
    local line name url
    while IFS= read -r line; do
        name="${line%% *}"; url="${line#* }"
        [ "$(norm_url "$url")" = "$want" ] && { printf '%s\n' "$name"; return 0; }
    done < <(git -C "$p" config --get-regexp '^remote\..*\.url' 2>/dev/null |
             sed -e 's/^remote\.//' -e 's/\.url / /')
    return 1
}

# The ref a repository's work LANDS on. Resolved, never assumed: three spellings are already in
# use here (origin/main, origin/master, gitea/master). Unresolvable is an error, not a default.
landing_ref() {          # landing_ref <repo-path> <remote> -> ref on stdout, or fail
    local p="$1" r="$2" head c
    head="$(git -C "$p" symbolic-ref --short "refs/remotes/$r/HEAD" 2>/dev/null)"
    if [ -n "$head" ] && git -C "$p" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
        printf '%s\n' "$head"; return 0
    fi
    for c in "$r/main" "$r/master"; do
        git -C "$p" rev-parse -q --verify "$c^{commit}" >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# Every working checkout under $SPIRA_WORKSPACES, indexed by every remote URL it knows. Built once.
declare -A CHECKOUT=()
index_checkouts() {
    local p u
    for p in "$WORKSPACES"/*/; do
        [ -e "$p/.git" ] || continue
        while IFS= read -r u; do
            [ -n "$u" ] || continue
            CHECKOUT["$(norm_url "$u")"]="${p%/}"
        done < <(git -C "$p" config --get-regexp '^remote\..*\.url' 2>/dev/null | sed 's/^[^ ]* //')
    done
}

# name <TAB> path <TAB> remote <TAB> ref, or name <TAB> - <TAB> - <TAB> ERROR:<reason>.
# Spira's repositories come from repo-map (a bead names the repo it is worked in), Gas
# Town's from its rigs. A repository claimed by both — the home repository is Spira's own, and a
# household polecat has landed a commit in it — appears once: attribution is per COMMIT, by
# author, so the union is the right set to walk and the overlap costs nothing.
discover() {
    index_checkouts
    local -A seen=()
    local name repo rig url path rem ref

    while IFS= read -r name; do
        repo="$(repo_root "$name")" || continue
        [ -n "$repo" ] && [ -e "$repo/.git" ] || continue
        [ -n "${seen[$repo]:-}" ] && continue
        seen["$repo"]=1
        rem="$(remote_for "$repo" "$(git -C "$repo" config --get remote.origin.url 2>/dev/null)")" || rem=origin
        # THE DECLARED ANSWER FIRST, for a repository the harness actually manages. Two
        # resolvers that disagree would have this program measure a ref the harness does not
        # land on, and the disagreement would look like a productivity result. `landing_ref`
        # stays for the rigs below, which have no repo-map row to declare anything in.
        if ref="$(spira_landref "$name" 2>/dev/null)"; then
            printf '%s\t%s\t%s\t%s\n' "$(basename "$repo")" "$repo" "$(ref_remote "$ref" || printf '%s' "$rem")" "$ref"
        elif ref="$(landing_ref "$repo" "$rem")"; then
            printf '%s\t%s\t%s\t%s\n' "$(basename "$repo")" "$repo" "$rem" "$ref"
        else
            printf '%s\t-\t-\tERROR:no landing ref under remote %s\n' "$(basename "$repo")" "$rem"
        fi
    done < <(spira_repos)

    for rig in "$TOWN"/*/; do
        rig="${rig%/}"
        [ -d "$rig/.repo.git" ] || continue
        url="$(git -C "$rig/.repo.git" config --get remote.origin.url 2>/dev/null)"
        if [ -z "$url" ]; then
            printf '%s\t-\t-\tERROR:rig has no origin url\n' "$(basename "$rig")"; continue
        fi
        path="${CHECKOUT[$(norm_url "$url")]:-}"
        if [ -z "$path" ]; then
            # A rig whose repository is not checked out here cannot be measured, and must not
            # therefore be counted as having landed nothing.
            printf '%s\t-\t-\tERROR:no checkout of %s under %s\n' "$(basename "$rig")" "$url" "$WORKSPACES"
            continue
        fi
        [ -n "${seen[$path]:-}" ] && continue
        seen["$path"]=1
        if ! rem="$(remote_for "$path" "$url")"; then
            printf '%s\t-\t-\tERROR:%s has no remote addressing %s\n' "$(basename "$rig")" "$path" "$url"; continue
        fi
        if ref="$(landing_ref "$path" "$rem")"; then
            printf '%s\t%s\t%s\t%s\n' "$(basename "$rig")" "$path" "$rem" "$ref"
        else
            printf '%s\t-\t-\tERROR:no landing ref under remote %s in %s\n' "$(basename "$rig")" "$rem" "$path"
        fi
    done
}

# ======================================================================================
# Who wrote it. The Gas Town roster is derived from the graph, because the polecat DIRECTORIES
# are reaped — a roster read from disk shrinks over time, and attributing by it would quietly
# reclassify last week's polecat work as `other` the moment its directory was cleaned up. Branch
# refs and merge subjects are permanent.
# ======================================================================================
roster_for() {           # roster_for <repo-path> <ref> -> gastown actor names, one per line
    local p="$1" ref="$2" refs subjects
    refs="$(git -C "$p" for-each-ref --format='%(refname)' 2>/dev/null)"
    subjects="$(git -C "$p" log --format='%s' --max-count=5000 "$ref" 2>/dev/null)"
    printf '%s\n%s\n' "$refs" "$subjects" |
        grep -oE 'polecat/[A-Za-z0-9._-]+/' 2>/dev/null |
        sed -e 's#^polecat/##' -e 's#/$##'
    # Structural Gas Town identities, one per rig. `mayor` and `deacon` are town-level and named
    # in the actors file; these are per-rig and so are derived alongside the rigs themselves.
    local rig
    for rig in "$TOWN"/*/; do
        rig="$(basename "${rig%/}")"
        printf '%s/refinery\n%s/witness\n' "$rig" "$rig"
    done
}

# Every bead id in the database, so the secondary beads-landed count is checked against what
# exists rather than against a pattern. `--status all --limit 0` because the default is
# open-only and `bd list` silently truncates at 50 otherwise — the documented trap, and here it
# would have quietly shrunk the set of ids a commit is allowed to name.
bead_ids() {
    bdjson list --status all --limit 0 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
if not isinstance(d, list) or not d: sys.exit(1)
print("\n".join(sorted({i.get("id","") for i in d if i.get("id")})))' 2>/dev/null
}

# ======================================================================================
# The window. Derived from the graph — see the header.
# ======================================================================================
window_start() {         # -> ISO-8601 of the earliest aeon commit on any landing ref
    local line name path rem ref out first best=""
    while IFS=$'\t' read -r name path rem ref; do
        case "$ref" in ERROR:*) continue ;; esac
        # Capture, then take the first line. `git log ... | head -1` under `set -o pipefail`
        # returns 141 when head closes the pipe (law-no-grep-q-under-pipefail), and a window
        # start that fails exactly when it succeeds is the whole measurement gone.
        out="$(git -C "$path" log --author='@spira.local' --reverse --format='%aI' "$ref" 2>/dev/null)"
        first="${out%%$'\n'*}"
        [ -n "$first" ] || continue
        if [ -z "$best" ] || [[ "$first" < "$best" ]]; then best="$first"; fi
    done < <(discover)
    [ -n "$best" ] && printf '%s\n' "$best"
}

iso_epoch() { date -u -d "${1:?}" +%s 2>/dev/null; }

# ======================================================================================
# The comparison.
# ======================================================================================
collect() {              # collect <since> <until> -> classifier JSON on stdout; repo table on fd 3
    local since="$1" until="$2" name path rem ref roster="" ids table=""
    local stream="" bad=0
    ids="$(bead_ids)" || ids=""

    # name <TAB> ref <TAB> ok|<reason>. The `ok` marker is what tells render() the difference
    # between a repository that landed nothing and one it could not read — which are the two
    # readings this whole program exists to keep apart, and which look identical from a count.
    while IFS=$'\t' read -r name path rem ref; do
        case "$ref" in
            ERROR:*) table+="$name"$'\t'"?"$'\t'"${ref#ERROR:}"$'\n'; bad=1; continue ;;
        esac
        if [ "$FETCH" = 1 ] && ! timeout 120 git -C "$path" fetch --quiet --prune "$rem" 2>/dev/null; then
            # Reported, never silently tolerated: a stale ref under-counts whichever harness was
            # busiest most recently, and there is no way to know which that is.
            table+="$name"$'\t'"?"$'\t'"fetch of $rem failed — ref is stale"$'\n'; bad=1; continue
        fi
        roster+="$(roster_for "$path" "$ref")"$'\n'
        # BOUNDED AT BOTH ENDS. `--since` alone keeps counting after the week is over, so the
        # verdict would go on moving — a gate that answers differently on day 8 and day 20 is
        # not a gate, and the first reading anyone acted on would be the one nobody could
        # reproduce. The window is seven days of history, not "seven days ago onwards".
        stream+="$(git -C "$path" log --no-merges --since="$since" --until="$until" \
                       --format="$name%x09%an%x09%ae%x09%s" "$ref" 2>/dev/null)"$'\n'
        table+="$name"$'\t'"$ref"$'\t'"ok"$'\n'
    done < <(discover)

    printf '%s' "$table" >&3
    printf '%s' "$bad" >&4
    ROSTER="$roster" ACTORS="$(cat "$HERE/actors" 2>/dev/null || cat "$HERE/actors.example" 2>/dev/null)" BEAD_IDS="$ids" \
        python3 "$HERE/cutover-classify.py" <<< "$stream"
}

# Merge commits are excluded above, and that is the substantive choice in this whole program.
# A polecat's commits land individually AND the refinery lands a merge on top of them; counting
# both would inflate Gas Town by roughly its own merge rate, which is exactly the number under
# scrutiny. Excluding merges also drops the mayor's and the refinery's bookkeeping, leaving
# authored work — the thing being compared.

render() {               # render <json> <repo-table> <since> <days>
    local json="$1" table="$2" since="$3" days="$4"
    python3 - "$since" "$days" "$RATIO" <<'PY' "$json" "$table"
import json, sys, datetime
since, days, ratio = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
d = json.loads(sys.argv[4]); table = sys.argv[5]
t = d["totals"]
start = datetime.datetime.fromisoformat(since)
# `--since` accepts a bare date, which parses naive; the derived window start carries an
# offset. Comparing the two raises rather than misreports, but a report that raises on a
# perfectly good flag is a report nobody runs.
if start.tzinfo is None:
    start = start.replace(tzinfo=datetime.timezone.utc)
end = start + datetime.timedelta(days=days)
now = datetime.datetime.now(datetime.timezone.utc)
elapsed = (now - start).total_seconds() / 86400.0

print("Spira cutover — LANDED COMMITS, not activity  (sp-builder-cutover)")
print()
print("  window   %s → %s   day %.1f of %d%s"
      % (start.strftime("%Y-%m-%dT%H:%M:%SZ"), end.strftime("%Y-%m-%dT%H:%M:%SZ"),
         min(elapsed, days), days, "" if elapsed < days else "  — CLOSED"))
print("  bar      spira >= %.2f x gastown" % ratio)
print()
refs = {}
for line in table.splitlines():
    if not line: continue
    p = line.split("\t")
    refs[p[0]] = (p[1], p[2] if len(p) > 2 else "")
w = max([len(r) for r in list(d["repos"]) + list(refs)] + [5])
print("  %-*s  %-22s %6s %8s %6s %6s" % (w, "repo", "landing ref", "spira", "gastown", "human", "other"))
for name in sorted(set(list(d["repos"]) + list(refs))):
    ref, status = refs.get(name, ("?", "not probed"))
    # A probed repository with no commits in the window has no row in the classifier's output,
    # and that is a real zero. Only a repository whose probe FAILED renders `?`: the first
    # version conflated them and printed `?` for six repositories that had simply been quiet,
    # which reads as a broken measurement instead of a true and useful nothing.
    if status != "ok":
        print("  %-*s  %-22s %6s %8s %6s %6s   %s" % (w, name, "?", "?", "?", "?", "?", status))
    else:
        c = d["repos"].get(name) or {k: 0 for k in ("spira", "gastown", "human", "other")}
        print("  %-*s  %-22s %6d %8d %6d %6d" % (w, name, ref, c["spira"], c["gastown"], c["human"], c["other"]))
print("  %-*s  %-22s %6d %8d %6d %6d" % (w, "TOTAL", "", t["spira"], t["gastown"], t["human"], t["other"]))
print()
b = d["beads"]
print("  beads landed   spira %d   gastown %d   (distinct ids named in those commits)"
      % (len(b["spira"]), len(b["gastown"])))
if d["unclassified"]:
    print("  unclassified   " + ", ".join("%s (%d)" % (k, v) for k, v in d["unclassified"].items()))
    print("                 neither harness claims these; see spira/actors")
print("  human          includes the crons that commit as the operator — statute synthesis, the beads")
print("                 mirror, the tasks view. It is 'neither harness', not 'typed by a person',")
print("                 and it does not enter the comparison.")
PY
}

# ======================================================================================
case "$cmd" in

repos)
    printf 'repo\tpath\tremote\tlanding ref\n'
    discover
    ;;

window)
    s="$(window_start)"
    if [ -z "$s" ]; then
        echo "no aeon commit has landed on any landing ref — the cutover has not begun"
        exit 1
    fi
    se="$(iso_epoch "$s")"; ee=$((se + DAYS * 86400)); now="$(date -u +%s)"
    printf 'start   %s   (earliest aeon commit on a landing ref)\n' "$s"
    printf 'closes  %s   (+%s days)\n' "$(date -u -d "@$ee" +%Y-%m-%dT%H:%M:%SZ)" "$DAYS"
    printf 'now     %s   day %s of %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(( (now - se) / 86400 + 1 ))" "$DAYS"
    [ "$now" -ge "$ee" ]
    ;;

report)
    since="$SINCE"
    if [ -z "$since" ]; then
        since="$(window_start)" || since=""
        [ -n "$since" ] || die "no aeon commit has landed anywhere — nothing to compare yet"
    fi
    until="$(date -u -d "$since + $DAYS days" +%Y-%m-%dT%H:%M:%SZ)"
    tf="$(mktemp)"; bf="$(mktemp)"; trap 'rm -f "$tf" "$bf"' EXIT
    j="$(collect "$since" "$until" 3>"$tf" 4>"$bf")"
    render "$j" "$(cat "$tf")" "$since" "$DAYS"
    ;;

verdict)
    # The VERIFY check for the sp-builder-cutover escalation: read-only, exits 0 exactly when
    # the window has closed and the crossover holds, and prints what it found either way so the
    # close carries evidence rather than a bare tick.
    since="$(window_start)" || since=""
    if [ -z "$since" ]; then echo "UNDECIDED: no aeon commit has landed — the cutover has not begun"; exit 1; fi
    se="$(iso_epoch "$since")"; ee=$((se + DAYS * 86400)); now="$(date -u +%s)"
    tf="$(mktemp)"; bf="$(mktemp)"; trap 'rm -f "$tf" "$bf"' EXIT
    j="$(collect "$since" "$(date -u -d "@$ee" +%Y-%m-%dT%H:%M:%SZ)" 3>"$tf" 4>"$bf")"
    render "$j" "$(cat "$tf")" "$since" "$DAYS"
    echo
    if [ "$(cat "$bf")" = 1 ]; then
        echo "UNDECIDED: at least one repository rendered ? — a probe that could not run is not a zero"
        exit 1
    fi
    if [ "$now" -lt "$ee" ]; then
        printf 'NOT YET: the window closes %s\n' "$(date -u -d "@$ee" +%Y-%m-%dT%H:%M:%SZ)"
        exit 1
    fi
    # Decided twice, once crediting every unclassified commit to each side. Reporting a verdict
    # that an unknown author could flip is the same defect as counting a failed probe as zero.
    python3 - "$RATIO" <<'PY' "$j"
import json, sys
ratio = float(sys.argv[1]); t = json.loads(sys.argv[2])["totals"]
s, g, o = t["spira"], t["gastown"], t["other"]
worst = s >= ratio * (g + o)          # every unknown was Gas Town's
best  = (s + o) >= ratio * g          # every unknown was Spira's
if worst:
    print("CROSSOVER: spira %d >= %.2f x gastown %d, and it holds even if all %d unclassified "
          "commits were Gas Town's" % (s, ratio, g, o)); sys.exit(0)
if not best:
    print("NO CROSSOVER: spira %d < %.2f x gastown %d, and it fails even crediting all %d "
          "unclassified commits to Spira" % (s, ratio, g, o)); sys.exit(1)
print("UNDECIDED: %d unclassified commits decide it — spira %d, gastown %d. Classify them in "
      "spira/actors." % (o, s, g)); sys.exit(1)
PY
    ;;

*) die "usage: cutover.sh [repos|window|report|verdict] [--no-fetch] [--since <date>] [--window-days <n>]" ;;
esac
