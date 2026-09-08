#!/usr/bin/env bash
#
# cockpit.sh — gather Spira health into .runtime/spira/cockpit.env for the cockpit pane.
#
#   cockpit.sh          one pass, write the snapshot, append a history row, exit
#   cockpit.sh loop     forever, every INTERVAL seconds
#   cockpit.sh history  append one history row from the snapshot already on disk
#
# WHY A SNAPSHOT FILE AND NOT DIRECT CALLS
# ----------------------------------------
# The pane repaints every two seconds. A pane that shelled out to `bd` and `git` would
# freeze on every repaint and paint stale frames while it did — the reason the town
# collector exists, arriving here for the same reason. The cost is paid once per pass; the
# pane reads a file.
#
# Flat `KEY='value'` so a renderer can `source` it with no parser. EVERY VALUE IS
# SHELL-QUOTED: the town snapshot once carried an unquoted `SCHED_CAP=direct dispatch
# (scheduler.max_polecats=-1)`, which is a syntax error that aborts the source, so every
# key after it silently read as unset and the whole panel rendered "?" while the collector
# looked healthy. Writes are atomic, so a half-written file cannot wedge a pane.
#
# SEPARATE FROM .runtime/cockpit.env, DELIBERATELY. That file is Gas Town's and is deleted
# with it; this one is Spira's and must survive that.
#
# THE RULE THAT GOVERNS EVERY PROBE: a probe that fails renders `?`, never 0. The town
# collector's first version returned 0 from its exception handler, so a broken parser
# displayed as "no parked beads" — a panel that reports a broken check as all-clear
# displaces the suspicion that would have prompted a look.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# The analyser is addressed as a SIBLING of this file, not through $SPIRA_HOME. A collector
# running from a worktree while its analyser resolves to the installed copy on main is a
# version skew that shows up as `?` on the panel and as nothing at all in any log.
HERE="$(cd "$(dirname "$0")" && pwd)"
COCK_DIR="$SPIRA_COCKPIT"

SNAP="$SPIRA_RUN/cockpit.env"
# No single $REPO. Every git question here is asked of the repository the BEAD named, or of
# every registered repository — see spira_repos / repo_root in lib.sh.
WINDOW_HOURS="${SPIRA_COCKPIT_WINDOW_HOURS:-24}"
INTERVAL="${SPIRA_COCKPIT_INTERVAL:-60}"

# THE SNAPSHOT HAS EXACTLY ONE WRITER: spira-cockpit.service. A second writer — an aeon
# running the collector from its worktree, a retired brain collector calling a vendored copy,
# a manual `cockpit.sh once` — overwrites the live snapshot with whatever keys its branch
# carries, and the pane reads `?` for every key the interloper lacked. The fence is
# INVOCATION_ID, which systemd sets for exactly one process tree per invocation: if this
# process's INVOCATION_ID matches the service's, it IS the service. SPIRA_COCKPIT_FORCE=1
# names the override (a fence, not a wall).
cockpit_may_write() {
    [ "${SPIRA_COCKPIT_FORCE:-0}" = 1 ] && return 0
    [ -n "${INVOCATION_ID:-}" ] || return 1
    local svc_id
    svc_id="$(systemctl --user show spira-cockpit.service -p InvocationID --value 2>/dev/null)" \
        || return 1
    [ "$INVOCATION_ID" = "$svc_id" ]
}

# Read partition definitions from the chamber without hardcoding a label list. A .fayth file
# added to the chamber appears here with no edit — the same reason the repository comes from
# the bead. Returns a JSON object: {"spira,plan": "builder", "spira,incident": "ops", ...}
_chamber_part_map() {
    python3 - "$HERE/chamber" "${SPIRA_SPIKE_LABEL:-spike}" <<'PY' 2>/dev/null || echo '{}'
import sys, glob, json, os
chamber, spike = sys.argv[1], sys.argv[2]
result = {}
for f in sorted(glob.glob(os.path.join(chamber, "*.fayth"))):
    name = labels = ""
    for line in open(f, errors="replace"):
        s = line.strip()
        if s.startswith("FAYTH_NAME="):
            name = s[len("FAYTH_NAME="):].strip('"').strip("'")
        elif s.startswith("FAYTH_LABELS="):
            labels = s[len("FAYTH_LABELS="):].strip('"').strip("'")
            labels = labels.replace("$SPIRA_SPIKE_LABEL", spike)
    if name and labels:
        result[labels] = name
print(json.dumps(result))
PY
}

# count <bd-args...> -> number of rows, or `?` if the query or the parse failed.
count() {
    bdq "$@" --json 2>/dev/null | json_only | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("?"); raise SystemExit
print(len(d if isinstance(d, list) else [d]))' 2>/dev/null || echo "?"
}

# age_of <path> -> seconds since last write, or `?` if it does not exist.
age_of() {
    local f="$1" m
    m="$(stat -c %Y "$f" 2>/dev/null)" || { printf '?'; return; }
    [ -n "$m" ] || { printf '?'; return; }
    printf '%d' $(( $(date +%s) - m ))
}

# unit_active <unit> -> 1 or 0. A timer that is not active is why nothing is happening, and
# it is the first thing to look at when every other number has stopped moving.
unit_active() {
    [ "$(systemctl --user is-active "$1" 2>/dev/null)" = active ] && printf 1 || printf 0
}

probe() {
    echo "SP_AT=$(date +%s)"
    echo "SP_WINDOW_HOURS=$WINDOW_HOURS"

    # Partition map — derived from the chamber once per pass, used by NOW, NEXT and RECENT.
    _PART_MAP="$(_chamber_part_map)"

    # ---- NOW: what each aeon is doing, by name -----------------------------------------
    # The pane repaints every two seconds and must never shell out, so the live picture is
    # assembled here: which named aeon holds which bead, for how long, and the last thing
    # it actually did — read from its stream-json trace, which is the only honest answer to
    # "is it working and on what".
    local i=0
    for pf in "$SPIRA_RUN"/aeon-*.pid; do
        [ -e "$pf" ] || continue
        aeon_alive "$pf" || continue
        local base name bead fay secs
        base="$(basename "$pf" .pid)"          # aeon-<fayth>-<bead>
        fay="$(printf '%s' "$base" | cut -d- -f2)"
        bead="$(printf '%s' "$base" | cut -d- -f3-)"
        name="$(aeon_named "$pf")"
        secs="$(ps -o etimes= -p "$(cat "$pf" 2>/dev/null)" 2>/dev/null | tr -d ' ')"
        # The title, so NOW says what is being worked and not only its id — the same help
        # NEXT gives for queued work.
        # THE PRIORITY COMES BACK WITH THE TITLE, from the one call already being made.
        # NEXT and RECENT both lead with P<n>; NOW did not, so the three sections describing
        # the same beads at three stages of one lifecycle did not line up and could not be
        # compared down the column (the operator: "parallel structure with the NEXT and
        # RECENT ones").
        # THE PARTITION IS DERIVED FROM BEAD LABELS, never from the holding persona, so NOW
        # cannot disagree with NEXT and RECENT about which partition a bead belongs to.
        local title pri partition meta
        meta="$(bdjson show "$bead" 2>/dev/null | python3 -c '
import sys, json, re
part_map = json.loads(sys.argv[1])
try: d = json.load(sys.stdin); i = (d if isinstance(d, list) else [d])[0]
except Exception: raise SystemExit
# Partition from bead labels: which fayths label-set is a subset of the bead labels.
labels = set(i.get("labels") or [])
partition = "?"
for lset, pname in part_map.items():
    if all(l in labels for l in lset.split(",")):
        partition = pname
        break
# Tab separated: priority, partition, title (title may contain anything, the rest may not).
print("%s\t%s\t%s" % (i.get("priority"), partition,
    re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", (i.get("title") or ""))[:80]))' "$_PART_MAP" 2>/dev/null)"
        pri="${meta%%$'\t'*}"; _rest="${meta#*$'\t'}"
        partition="${_rest%%$'\t'*}"; title="${_rest#*$'\t'}"
        [ "$pri" = "$meta" ] && { pri=""; partition=""; title=""; }
        echo "SP_AEON${i}_PRI=${pri:-?}"
        echo "SP_AEON${i}_PARTITION=${partition:-?}"
        echo "SP_AEON${i}_TITLE=${title:-?}"
        echo "SP_AEON${i}_NAME=${name:-?}"
        echo "SP_AEON${i}_FAYTH=${fay:-?}"
        echo "SP_AEON${i}_BEAD=${bead:-?}"
        echo "SP_AEON${i}_MIN=$(( ${secs:-0} / 60 ))"
        # HOW HEALTHY THE SESSION IS, not merely that it exists. TURNS CTX TOOLS FILES QUIET
        # ACT SAID, from ONE streaming read of the aeon's stream-json trace — the only
        # artifact that knows any of it. Held to one read per aeon per pass because the trace
        # is the single thing here that grows without bound; the pane reads what this wrote
        # and never opens the file itself.
        #
        # trace_stats SANITISES ITS OWN VALUES, and it has to: they are arbitrary text from an
        # agent — a shell command, a code fragment, a sentence — and this file is sourced by
        # the pane with no parser. A newline injects extra lines and an "=" makes a bogus key;
        # the pane rendered a tools help page where the ops summary belongs before that was
        # clamped at the source.
        #
        # A KEY IT DOES NOT EMIT STAYS UNSET, and the renderer shows `?` for it. That is the
        # wanted behaviour rather than a gap: a failed read must never arrive as a zero
        # (law-absence-needs-a-positive-control).
        trace_stats "$SPIRA_RUN/$bead.log" 2>/dev/null | sed "s/^/SP_AEON${i}_/"
        # THE TRAILING MOMENTS, from trace_tail. Each line is sanitised by the same
        # allowlist trace_stats uses for ACT: the snapshot is a KEY=value file the pane
        # SOURCES, so a newline injects extra lines and an "=" makes a bogus key. trace_tail
        # has no such clamp — it is multi-line by design and emits $ and -> prefixes —
        # so every line goes through the allowlist before it becomes a value.
        local tl="${SPIRA_COCKPIT_TRACE_LINES:-3}"
        if [ "$tl" -gt 0 ] 2>/dev/null; then
            trace_tail "$SPIRA_RUN/$bead.log" "$tl" 2>/dev/null | python3 -c '
import sys, re
ALLOW = re.compile(r"[^ A-Za-z0-9._/:,()#+-]")
pfx = sys.argv[1]
n = int(sys.argv[2])
lines = []
for raw in sys.stdin:
    c = re.sub(r"\s+", " ", ALLOW.sub(" ", raw)).strip()[:96]
    if c:
        lines.append(c)
for j, l in enumerate(lines[-n:]):
    print("%sACT%d=%s" % (pfx, j, l))
' "SP_AEON${i}_" "$tl" 2>/dev/null
        fi
        i=$((i+1))
    done
    echo "SP_AEON_N=$i"

    # ---- NEXT: ready beads from EVERY declared partition, ordered by priority ------------
    # PARTITIONS COME FROM THE CHAMBER. Each .fayth defines its own label predicate; a new
    # persona appears here with no edit because _PART_MAP was already read at the top of
    # probe(). Querying only builder's `spira,plan` left the incident queue invisible: a
    # stalled incident looked identical to an empty one on the pane Ryan reads.
    #
    # CLAIM ORDER IS PARTITION-SPECIFIC, not global. Each partition is drained by its own
    # persona concurrently, so there is no single claim order across them. Interleaved by
    # priority this shows outstanding P0 work everywhere, which is what was asked for; the
    # header now says so rather than promising a single order that does not exist.
    #
    # SP_READY IS EMITTED HERE because it is the same population: the union across partitions
    # that NEXT shows. Counting it again at the old site would be a second query for a number
    # already in hand; the old PLAN_READY_ARGS site is removed along with the hardcoded label.
    {
        python3 -c '
import sys, json
for labels, name in json.loads(sys.argv[1]).items():
    print(name + "\t" + labels)
' "$_PART_MAP" 2>/dev/null
    } | while IFS=$(printf '\t') read -r _pname _plabels; do
        bdjson "${READY_ARGS[@]}" \
            --label "$_plabels" \
            --exclude-label "spira-poison,$SPIRA_ASK_LABEL,$SPIRA_CI_LABEL" \
            2>/dev/null | python3 -c '
import sys, json
name = sys.argv[1]
try:
    d = json.load(sys.stdin)
    for r in (d if isinstance(d, list) else [d]):
        r["_partition"] = name
        print(json.dumps(r))
except Exception:
    pass
' "$_pname" 2>/dev/null
    done | python3 -c '
import sys, json, re
rows = []
seen = set()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        r = json.loads(line)
        bid = r.get("id", "")
        if bid and bid not in seen:
            seen.add(bid)
            rows.append(r)
    except Exception:
        pass
# P0 across all partitions, then P1, then P2 — harness order preserved within each priority.
rows.sort(key=lambda r: (r.get("priority") or 9))
# FORTY, AND THE RENDERER AGREES. Matches health.sh MAX_NEXT_ROWS; the pane allocator
# decides the actual height. A collector cap tighter than the renderer is the one that cannot
# be seen: rows never emitted look exactly like rows that do not exist.
for n, i in enumerate(rows[:40]):
    part = i.get("_partition", "?")
    title = re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", (i.get("title") or ""))[:80].replace("=", "-")
    print("SP_NEXT%d=P%s %s %s %s" % (n, i.get("priority") or "?", part, i["id"], title))
print("SP_NEXT_N=%d" % len(rows))
print("SP_READY=%d" % len(rows))
' 2>/dev/null

    # ---- RECENT: TRANSITIONS, not just outcomes ----------------------------------------
    # The id->title map for the rows below, fetched once through the harness chokepoint and
    # passed as a file. An unreadable map leaves the rows bare rather than failing the pass:
    # "what happened" is the load-bearing half and must survive a database that will not
    # answer (law-absence-needs-a-positive-control applies to the TITLE, not to the event).
    TITLEMAP="$(mktemp)"; trap 'rm -f "$TITLEMAP"' RETURN
    bdjson list --all --limit 0 > "$TITLEMAP" 2>/dev/null || echo '[]' > "$TITLEMAP"
    # This listed sentinel ACTs alone — landed, reopened, poisoned, reaped — which are all
    # ENDINGS. A bead being CLAIMED was invisible, and so was a bead being DROPPED: an aeon
    # exited mid-CI believing something would resume it, the lease expired, and the pane
    # showed a 52-minute-old landing while 21 commits sat abandoned. Nothing on screen said
    # a thing had changed hands. Merging the aeon ledger in makes this a lifecycle, so a
    # switch explains itself instead of having to be inferred from a clock.
    {
        grep -E 'ACT (landed|reopened|poisoned|reclaimed [0-9]|announced|reaped)' \
             "$SPIRA_RUN/sentinel.log" 2>/dev/null | tail -80 \
          | sed -E 's/^([^ ]+) spira: ACT /\1 sentinel /'
        # strand.sh's output carries NO timestamp of its own — it is printed inside a pass.
        # Stamping it with now() made a half-hour-old reclaim read "0s ago", which is the
        # dashboard lying about the single event that mattered. Attribute each line to the
        # most recent timestamped line above it, as the sending's counters already are.
        python3 -c '
import sys, re
ts, out = None, []
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) ", line)
    if m:
        ts = m.group(1)
        continue
    if line.startswith("RECLAIMED ") and ts:
        parts = line.split()
        if len(parts) > 1:
            out.append("%s sentinel reclaimed %s" % (ts, parts[1]))
print("\n".join(out[-40:]))
' "$SPIRA_RUN/sentinel.log" 2>/dev/null
        # THE BEAD IS FIELD 4, NOT 3. A ledger line is `<ts> <verb> <fayth> <bead>`, so `$3`
        # is "builder" and the predicate `$3 ~ /^sp-/` was never once true — claims have been
        # silently absent from RECENT for the whole life of this section, which is exactly the
        # blindness it was written to remove. The operator, watching an aeon finish a bead and
        # take another: "i don't see anything from the last hour in RECENT."
        #
        # AND ENDINGS TOO. Only `awake` was read, so a turn that ENDED left no trace unless
        # the sentinel also acted — and an aeon that finishes without landing (the common case
        # while the gate is advisory) produced nothing at all. `done` carries the outcome in
        # its status field; a turn that ended with the bead still in progress is the shape
        # worth seeing, because it is the one that repeats.
        awk '$2 == "awake" && $4 ~ /^sp-/ { printf "%s %s claimed %s\n", $1, $3, $4 }
             $2 == "done"  && $4 ~ /^sp-/ {
                 st = "ended"
                 for (i = 5; i <= NF; i++) if ($i ~ /^status=/) { sub(/^status=/, "", $i); st = $i }
                 printf "%s %s %s %s\n", $1, $3, st == "closed" ? "finished" : st, $4
             }' \
            "$SPIRA_RUN/aeon-ledger.log" 2>/dev/null | tail -80
    # EVERY STAGE OF THIS PIPELINE IS A CAP AND THE SMALLEST ONE DECIDES. Widening only the
    # last would still emit four events, because each source is trimmed before the merge —
    # which is why raising the renderer's ceiling to forty meant raising every `tail` above
    # this line too, not just the `head` on it.
    # -u BECAUSE THE SOURCES OVERLAP AND THE LEDGER REPEATS ITSELF. slay.sh can write two
    # `done` lines for one aeon, and a bead that is both claimed and ended in the window
    # arrives from two branches of the merge — so the pane showed the same event twice and
    # spent two of twenty rows saying it once. The dedupe is also why the sources are trimmed
    # LOOSER than the output: forty unique events can need well over forty input lines.
    } | sort -r -u | head -60 | python3 -c '
import sys, json, re, datetime
now = datetime.datetime.now(datetime.timezone.utc)

# THE TITLE MAP IS BUILT BY THE SHELL, through bdjson, and handed here as a file. Calling bd
# from inside this python meant reinventing how the harness invokes it — the binary, -C, the
# PATH conf.sh exports — and every one of those is a way to get an empty map that renders as
# "no titles" rather than as an error. bdjson is the one chokepoint that already knows.
#
# ONE list call for all of them, never one show per event: twenty shows is twenty round trips
# to Dolt on a pass that runs every minute. --limit 0 because bd list truncates at 50 by
# default, and a silently short map leaves later rows bare (law-bd-list-truncates-at-50).
titles = {}
titlemeta = {}
try:
    for i in json.load(open(sys.argv[1])):
        bid = i["id"]
        titles[bid] = re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", (i.get("title") or ""))
        titlemeta[bid] = i
except Exception:
    titles = {}; titlemeta = {}

try: part_map = json.loads(sys.argv[2])
except Exception: part_map = {}

NON_AEON = {"sentinel", "overseer", "ryan"}

# DEDUPED ON THE EVENT, NOT THE LINE. `sort -u` above collapses byte-identical rows, which
# is not what repeats here: slay.sh writes two `done` lines a SECOND apart, so the timestamps
# differ, both survive, and the pane spends two of twenty rows saying one thing once. Keyed on
# (actor, verb, bead) and keeping the first seen — input is newest-first, so that is the newest.
seen, rows = set(), []
for line in sys.stdin:
    parts = line.strip().split(" ", 2)
    if len(parts) < 3:
        continue
    ts_str, actor, body = parts[0], parts[1], parts[2]
    toks = body.split()
    bead = toks[-1] if toks else ""
    if "/" in bead:
        bead = bead.rsplit("/", 1)[-1]
    verb = toks[0] if toks else ""
    key = (actor, verb, bead)
    if key in seen:
        continue
    seen.add(key)
    rows.append((ts_str, actor, body, verb, bead))

# FORTY ROWS, AND THE CAP IS APPLIED HERE RATHER THAN ON THE PIPE ABOVE. The head above is
# the MERGE WINDOW and has to stay wider than the cap, because the dedup that follows it
# removes rows: trimming to forty before it would emit thirty-one events and call that the cap.
# Forty matches MAX_RECENT_ROWS in health.sh -- a CEILING, not a height. How many of these the
# pane actually shows is decided per repaint by `share`, which hands RECENT whatever NOW is
# not using. The renderer holds the same ceiling, so a snapshot from a collector with a wider
# one still renders at most forty.
for n, (ts_str, actor, body, verb, bead) in enumerate(rows[:40]):
    try:
        t = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        secs = int((now - t).total_seconds())
    except Exception:
        continue
    if secs < 90: rel = "%ds ago" % secs
    elif secs < 5400: rel = "%dm ago" % (secs // 60)
    elif secs < 172800: rel = "%dh ago" % (secs // 3600)
    else: rel = "%dd ago" % (secs // 86400)

    # ACTOR DISPLAY. Bare for non-aeon actors (sentinel, overseer, ryan). For aeon actors
    # (fayth names like builder/ops/spike) append the bead assignee as the specific aeon;
    # the assignee field in the titlemap is the name the aeon registered when it claimed work.
    # If the bead is already closed and unassigned, we fall back to just the fayth name —
    # knowing which persona did it is more useful than a question mark where a name was.
    if actor in NON_AEON:
        actor_disp = actor
    else:
        meta = titlemeta.get(bead, {})
        assignee = (meta.get("assignee") or "").strip()
        actor_disp = ("%s/%s" % (actor, assignee)) if assignee else actor

    # PARTITION from bead labels against the chamber map. A bead matching no declared
    # partition renders "?" and is still listed — never silently dropped.
    bead_labels = set(titlemeta.get(bead, {}).get("labels") or [])
    partition = "?"
    for lset, pname in part_map.items():
        if all(l in bead_labels for l in lset.split(",")):
            partition = pname
            break

    # The last word of an event is its bead id; look the title up and append it. A missing
    # title is left absent rather than filled with a placeholder, so the row still says what
    # happened when the map could not be built.
    #
    # AND THE LAST WORD IS SOMETIMES A REF, NOT AN ID. The sentinel logs a landing as
    # `landed spira/sp-mebw`, which is the BRANCH. Looked up whole it matches nothing, so every
    # landed row on the pane rendered with no title at all -- the one event class where the
    # reader most wants to know what landed. Fall back to the ref basename, which is the bead.
    toks = body.split()
    # A LANDING NAMES THE BEAD; A REAP NAMES THE BRANCH. They are different questions. What
    # landed is work, and the branch it arrived on is an implementation detail the reader
    # already knows -- so `spira/` is noise on that row. What was reaped is a REF, in one of
    # seven repositories, and the whole point of the row is which one; there the bare id is
    # the redundant half, because the branch already ends with it.
    if verb == "landed" and toks and "/" in toks[-1]:
        toks[-1] = bead
        body = " ".join(toks)
    elif len(toks) > 2 and toks[-1] != bead and toks[-1].endswith("/" + bead):
        body = " ".join(toks[:-1])
    title = titles.get(bead, "")
    body_display = ("%s %s" % (body, title) if title else body)[:80].replace("=", "-")
    print("SP_EVENT%d=%-7s %-12s %-8s %s" % (n, rel, actor_disp[:12], partition[:8], body_display))
' "$TITLEMAP" "$_PART_MAP"

    # ---- AWAITING CI: parked on a run, and parked on nothing -----------------------------
    # A parked bead has no aeon and is not stranded — its review is open and the sweep is
    # watching. That makes it invisible in every other figure on this pane: not in progress,
    # not ready, nothing moving. Without a line of its own, work parked for an hour looks
    # exactly like work nobody started.
    #
    # TWO POPULATIONS, AND THE SMALLER ONE IS THE ONE THAT MATTERS. "Waiting on a run" is
    # routine and needs no reader. "Parked with no run to wait for" is a bead that will wait
    # forever: the label excludes it from every predicate and from the stranded-work report,
    # so a park in a repository that opens no pull requests is not merely stalled, it is
    # invisible — and this pane called it "in CI", which is the one description that stops
    # anybody looking for the real cause. spira_ci_park_state decides which it is, and it is
    # the same function the sweep acts on, so the pane cannot disagree with the harness.
    #
    # Age comes from updated_at, which the label write moves. It is a proxy for "entered this
    # state" and a good one, since a parked bead is not otherwise touched.
    # NOT `--status open`. A parked bead may still be in_progress — the aeon that labelled
    # it has not necessarily exited yet — and filtering on open alone reported zero while a
    # bead sat labelled and visible in `bd show`. Take everything not closed.
    # ONE PYTHON PASS FOR THE ORDERING, ONE BASH PASS FOR THE VERDICT. The rows come out
    # oldest first with their age already rendered, because the timestamps are python's to
    # parse; the classification is spira_ci_park_state, which is the SAME function the sweep
    # acts on, so this pane cannot disagree with the harness about what is parked on nothing.
    local ci_rows ci_id ci_repo ci_at ci_rel ci_title ci_state ci_n=0
    local ci_watch=0 ci_stuck=0 ci_oldest=- ci_age=- ci_stuck_id=-
    if ci_rows="$(bdjson list --all --limit 0 --label "$SPIRA_CI_LABEL" 2>/dev/null | python3 -c '
import sys, json, datetime, re
d = json.load(sys.stdin)
home = sys.argv[1]
rows = [i for i in (d if isinstance(d, list) else [d]) if i.get("status") != "closed"]
def when(v):
    try: return datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception: return None
def rel(secs):
    if secs < 90: return "%ds" % secs
    if secs < 5400: return "%dm" % (secs // 60)
    if secs < 172800: return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)
now = datetime.datetime.now(datetime.timezone.utc)
aged = sorted(((when(i.get("updated_at")) or now, i) for i in rows), key=lambda r: r[0])
for t, i in aged[:20]:
    repo = next((l[5:] for l in (i.get("labels") or []) if l.startswith("repo:")), home)
    # The title is sanitised and the fields are tab separated, so a title carrying a tab or a
    # control character cannot shift the columns the reader below splits on.
    title = re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", (i.get("title") or ""))[:80]
    print("%s\t%s\t%s\t%s\t%s" % (i["id"], repo, i.get("updated_at") or "",
                                    rel(int((now - t).total_seconds())), title))' "$(spira_home_repo)" 2>/dev/null)"
    then
        while IFS="$(printf '\t')" read -r ci_id ci_repo ci_at ci_rel ci_title; do
            [ -n "$ci_id" ] || continue
            # A PARK THIS CANNOT AGE COUNTS AS STUCK, which is where the pane and the sweep
            # deliberately part company: the sweep will not strip a label on the strength of a
            # clock it could not read, but a pane that paints an unreadable check as normal
            # displaces the suspicion that would have prompted a look.
            ci_state="$(spira_ci_park_state "$ci_repo" "$ci_at")" || ci_state=no-ci
            # OLDEST FIRST, so the first row is the oldest and the first STUCK row is the
            # oldest of those — no second sort, and no arithmetic that can disagree with the
            # order the section renders in.
            [ "$ci_oldest" = - ] && { ci_oldest="$ci_id"; ci_age="$ci_rel"; }
            if [ "$ci_state" = watch ]; then
                ci_watch=$(( ci_watch + 1 ))
            else
                ci_stuck=$(( ci_stuck + 1 ))
                [ "$ci_stuck_id" = - ] && ci_stuck_id="$ci_id"
                # THE ROW CARRIES ITS OWN REASON. A count in the summary says how many are
                # stuck; only the row says which, and a reader looking at one bead should not
                # have to work out which population it fell into.
                ci_title="no run to wait for · $ci_title"
            fi
            # ONE KEY PER PARKED BEAD, so the CI section has something to expand INTO. The
            # summary line answers "is anything parked"; it cannot answer "which of them has
            # been parked since yesterday", and that is the question a stalled run is found by.
            printf 'SP_AWAITING%d=%-10s %-4s %s\n' "$ci_n" "$ci_id" "$ci_rel" "$ci_title"
            ci_n=$(( ci_n + 1 ))
        done <<< "$ci_rows"
        echo "SP_AWAITING_N=$ci_watch"
        echo "SP_AWAITING_STUCK=$ci_stuck"
        echo "SP_AWAITING_STUCK_ID=$ci_stuck_id"
        echo "SP_AWAITING_OLDEST=$ci_oldest"
        echo "SP_AWAITING_AGE=$ci_age"
    else
        # A FAILED PROBE RENDERS `?`, NEVER 0. The first version of this pane returned 0 from
        # its exception handler, so a broken parser displayed as "no parked beads".
        echo "SP_AWAITING_N=?"; echo "SP_AWAITING_STUCK=?"; echo "SP_AWAITING_STUCK_ID=?"
        echo "SP_AWAITING_OLDEST=?"; echo "SP_AWAITING_AGE=?"
    fi

    # ---- FLOW: what is moving between the operator and the harness ------------------------------
    local waiting unread
    waiting=$(bdjson list --status open --limit 0 --label "$SPIRA_ASK_LABEL" 2>/dev/null | json_count)
    unread=$("$COCK_DIR/unanswered.sh" --count 2>/dev/null | tail -1)
    echo "SP_WAITING=${waiting:-?}"
    echo "SP_UNANSWERED=${unread:-?}"

    # ---- THROUGHPUT: what closed and what opened, by kind --------------------------------
    bdjson list --all --limit 0 --label spira,plan 2>/dev/null | python3 -c '
import sys, json, datetime
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
rows = d if isinstance(d, list) else [d]
cut = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
def when(v):
    try: return datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception: return None
closed = [i for i in rows if i.get("status") == "closed" and (when(i.get("closed_at") or i.get("updated_at")) or cut) >= cut]
opened = [i for i in rows if (when(i.get("created_at")) or cut - datetime.timedelta(1)) >= cut]
kinds = {}
for i in closed: kinds[i.get("issue_type") or "task"] = kinds.get(i.get("issue_type") or "task", 0) + 1
print("SP_CLOSED_24H=%d" % len(closed))
print("SP_OPENED_24H=%d" % len(opened))
print("SP_CLOSED_KINDS=%s" % (", ".join("%s %d" % (k, v) for k, v in sorted(kinds.items(), key=lambda x: -x[1])[:4]) or "-"))
' 2>/dev/null

    # ---- the unsent backlog ------------------------------------------------------------
    # Current state, not log history: how many spira/* branches exist right now and how old
    # the oldest is. A branch that keeps ageing is work that landed nowhere, which is how a
    # fiend starts — before sending.sh, one such branch was re-merged and re-pushed every
    # two minutes forever because git would not delete it while a worktree held it.
    # A failed probe renders `?`, never 0: "no unsent work" is the reassuring answer and
    # must never be the one a broken git call produces.
    # ACROSS EVERY REPOSITORY. A bead names the checkout it is worked in, so counting only
    # the home repo's branches would report "no unsent work" while another repository's
    # branches aged forever — the reassuring answer, produced by looking in the wrong place.
    # Refs are a local read, so this costs nothing per repository; no fetch happens here.
    _fail=0; _n=0; _o=""; _done=0; _unadopted=0
    for _r in $(spira_repos); do
        _p="$(repo_root "$_r")" || continue
        [ -e "$_p/.git" ] || continue
        # ONE LOOP PER REPOSITORY, fetching both name and timestamp. The bead lookup decides
        # whether a branch counts as unsent work or as an unadopted stray — a ref whose suffix
        # resolves to no bead can never be reaped by any rite and is a permanent +1 on a figure
        # whose whole purpose is to trend to zero.
        if _brs="$(git -C "$_p" for-each-ref --format='%(refname:short) %(committerdate:unix)' 'refs/heads/spira/*' 2>/dev/null)"; then
            while read -r _b _ts; do
                [ -n "$_b" ] || continue
                _st="$(bdjson show "${_b#spira/}" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin); print((d if isinstance(d, list) else [d])[0].get("status", ""))
except Exception: print("")' 2>/dev/null)"
                if [ -z "$_st" ]; then
                    _unadopted=$((_unadopted+1))
                    continue
                fi
                [ "$_st" = closed ] && _done=$((_done+1))
                _n=$((_n+1))
                if [ -n "$_ts" ]; then
                    if [ -z "$_o" ] || [ "$_ts" -lt "$_o" ]; then _o="$_ts"; fi
                fi
            done <<< "$_brs"
        else
            _fail=1
        fi
    done
    echo "SP_BRANCH_DONE=$_done"
    echo "SP_UNADOPTED=$_unadopted"
    if [ "$_fail" = 1 ]; then
        echo "SP_UNSENT=?"
        echo "SP_UNSENT_OLDEST_H=?"
    else
        echo "SP_UNSENT=$_n"
        if [ "$_n" -gt 0 ]; then
            echo "SP_UNSENT_OLDEST_H=$(( ( $(date +%s) - _o ) / 3600 ))"
        else
            echo "SP_UNSENT_OLDEST_H=0"
        fi
    fi

    # ---- what the landing gate is worth ------------------------------------------------
    # THE PANE ALREADY SAYS WHAT THE HARNESS COSTS; this is the one number that says whether
    # the check between work and its landings is buying anything. The metric selection rule
    # is the operator's — instrument the numbers that surprised us — and a gate that ran for
    # weeks, cost seventeen minutes a branch and caught nothing is the largest such surprise
    # this system has produced (law-gate-earns-its-place).
    #
    # yield.sh does the reading and renders `?` for anything it could not read; this passes
    # that through untouched, because a yield meter that reported a broken check as "no
    # faults" is the same failure as reporting a stalled queue as idle. SPIRA_RUN is passed
    # explicitly — conf.sh does not export it, and a child re-deriving it from a config file
    # would read a different directory and report a confident zero.
    # EVERY KEY IS WRITTEN OUT IN FULL rather than renamed by a pattern. The pane reads these
    # by name, and the way a pair like this drifts is that one side is edited and the other
    # is not — which is findable by grep only if both sides spell the key.
    _y_reds="?"; _y_def="?"; _y_fault="?"; _y_unk="?"; _y_solo="?"; _y_conc="?"; _y_worst="?"
    if [ -r "$HERE/yield.sh" ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in
                YIELD_REDS)     _y_reds="$_v" ;;
                YIELD_DEFECT)   _y_def="$_v" ;;
                YIELD_FAULT)    _y_fault="$_v" ;;
                YIELD_UNKNOWN)  _y_unk="$_v" ;;
                YIELD_SOLO_MED) _y_solo="$_v" ;;
                YIELD_CONC_MED) _y_conc="$_v" ;;
                YIELD_TOP_FAULT) _y_worst="$_v" ;;
            esac
        done < <(SPIRA_RUN="$SPIRA_RUN" bash "$HERE/yield.sh" report 2>/dev/null)
    fi
    echo "SP_YIELD_REDS=$_y_reds"
    echo "SP_YIELD_DEFECT=$_y_def"
    echo "SP_YIELD_FAULT=$_y_fault"
    echo "SP_YIELD_UNKNOWN=$_y_unk"
    echo "SP_YIELD_SOLO_MED=$_y_solo"
    echo "SP_YIELD_CONC_MED=$_y_conc"
    echo "SP_YIELD_TOP_FAULT=$_y_worst"

    # ---- the harness itself -----------------------------------------------------------
    # strand.sh names this as its own blind spot: a check cannot observe the failure of the
    # thing running it. The collector is not the sentinel, so it can — and this is what
    # makes every number below interpretable, because a stale graph under a dead sentinel
    # looks exactly like a quiet one under a live sentinel.
    echo "SP_SENTINEL_TIMER=$(unit_active spira-sentinel.timer)"
    echo "SP_SENTINEL_AGE=$(age_of "$SPIRA_RUN/sentinel.log")"
    echo "SP_OPS_TIMER=$(unit_active spira-ops.timer)"
    # SP_OPS_AGE: "ops is inside a session" vs "ops has stopped". ops.log only gets new lines
    # from aeon.sh's own log() calls, which are silent during the 480s claude session itself,
    # so its mtime is frozen while ops is actually working — indistinguishable from a dead
    # collector. A live ops pid file is the authoritative "busy" signal (law-alerts-must-be-actionable).
    _ops_age="$(age_of "$SPIRA_RUN/ops.log")"
    for _ops_pf in "$SPIRA_RUN"/aeon-ops-*.pid; do
        [ -e "$_ops_pf" ] || continue
        if aeon_alive "$_ops_pf"; then _ops_age=0; break; fi
    done
    echo "SP_OPS_AGE=$_ops_age"
    unset _ops_pf _ops_age

    # ---- the sphere grid ---------------------------------------------------------------
    # Scoped by LABEL, not by the goal epic's children: the goal epic is one pilgrimage, and
    # a dashboard that describes exactly one of them describes nothing the moment a second
    # design is in flight. Scoped to `spira,plan` for the reason in
    # law-spira-is-a-replica-until-cutover — imported beads are a snapshot of work another
    # system's workers are still doing, and counting them here would report that system's
    # backlog as this one's.
    bdq list --limit 0 --label spira,plan --json 2>/dev/null | json_only | python3 -c '
import os, sys, json
# The escalation label is one configured key, read from the environment rather than written
# in: five literals in five files is how the panel, the gate and the predicates come to
# disagree about which beads are waiting on anyone.
ASK = os.environ["SPIRA_ASK_LABEL"]
try: d = json.load(sys.stdin)
except Exception:
    for k in ("OPEN", "INPROG", "POISON", "NEEDSOP"): print("SP_%s=?" % k)
    raise SystemExit
d = d if isinstance(d, list) else [d]
def has(i, lab): return lab in (i.get("labels") or [])
# Epics are containers, not work; counting the pilgrimage itself as an open bead makes the
# graph look one item further from done than it is, forever.
work = [i for i in d if i.get("issue_type") != "epic"]
print("SP_OPEN=%d"      % sum(1 for i in work if i.get("status") != "closed"))
print("SP_INPROG=%d"    % sum(1 for i in work if i.get("status") == "in_progress"))
print("SP_POISON=%d"    % sum(1 for i in work if i.get("status") != "closed" and has(i, "spira-poison")))
print("SP_NEEDSOP=%d"  % sum(1 for i in work if i.get("status") != "closed" and has(i, ASK)))
' 2>/dev/null || { echo "SP_OPEN=?"; echo "SP_INPROG=?"; echo "SP_POISON=?"; echo "SP_NEEDSOP=?"; }

    # ---- closed versus landed ----------------------------------------------------------
    # law-closed-is-not-landed as a 24h figure matching the header it sits under. The
    # population is beads an aeon worked AND closed within the last 24 hours, so the row's
    # window agrees with the throughput row above it. Previously this was all-time, which
    # produced nonsense when compared against the 24h closed/opened counts on the same block.
    #
    # A `<id>.log` in the run directory is the evidence that a session ran. The 24h filter
    # uses the bead's closed_at timestamp.
    #
    # THREE STATES, NOT TWO. A closed bead with no commit naming it is not necessarily lost:
    # if its branch still exists it is awaiting landing — a healthy, normally non-zero state.
    # Only a bead with no commit AND no branch is irrecoverable (law-alerts-must-be-actionable).
    #
    # ONE `git log` plus ONE `for-each-ref` per repo, then membership tests per id.
    local closed_ids subjects branches
    # THE BEAD'S REPOSITORY COMES OUT OF THE SAME QUERY AS ITS ID, because reading the wrong
    # repository's commit graph is wrong confidently in both directions: another repository's bead
    # that landed perfectly reads as unlanded in brain, and a panel that reports finished
    # work as lost is the same false alert as one that reports lost work as finished.
    # TAB-SEPARATED: id, repo, priority, closed_at, title. The extra fields feed the PEND
    # section below without a second walk of the database. The first two fields serve the
    # existing landing check; the rest serve the unlanded-queue detail rows.
    closed_pairs="$(bdjson list --status closed --limit 0 --label spira,plan 2>/dev/null | python3 -c '
import sys, json, os, re, datetime
run, home = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
cut = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
def when(v):
    try: return datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception: return None
for i in (d if isinstance(d, list) else [d]):
    if os.path.exists(os.path.join(run, i["id"] + ".log")):
        ts = when(i.get("closed_at") or i.get("updated_at"))
        if ts and ts >= cut:
            repo = next((l[5:] for l in (i.get("labels") or []) if l.startswith("repo:")), home)
            pri = i.get("priority", "")
            cat = i.get("closed_at") or i.get("updated_at") or ""
            title = re.sub(r"[^ A-Za-z0-9._/:,()#+-]", " ", (i.get("title") or ""))[:80]
            print("%s\t%s\t%s\t%s\t%s" % (i["id"], repo, pri, cat, title))' "$SPIRA_RUN" "$(spira_home_repo)" 2>/dev/null)"
    closed_ids="$(printf '%s\n' "$closed_pairs" | awk -F'\t' 'NF{print $1}')"
    if [ -z "$closed_ids" ]; then
        echo "SP_CLOSED=0"; echo "SP_LANDED=0"; echo "SP_AWAITING_LAND=0"; echo "SP_UNLANDED=0"
        echo "SP_PEND_N=0"; echo "SP_PEND_OLDEST=0"
    else
    # ONE FETCH PER REPOSITORY THAT ACTUALLY HAS A CLOSED BEAD IN IT, and none at all for the
    # rest. This runs on the collector loop; fetching every registered repository each pass
    # would be thousands of round trips a day to answer a question about repositories with no
    # Spira work in them.
    #
    # The remote-tracking ref, never the local branch alone: nothing in this harness advances
    # the shared checkout's default branch — the sentinel pushes the landing branch from its
    # own worktree — so the local ref is however stale the last human left it.
    #
    # AND THE REF IS RESOLVED, NOT `main`. This appended a literal `main` to the ref list,
    # which in a `master`-based repository names nothing: `git log <ref> main` fails outright on
    # an unknown revision, so BOTH repositories contributed no subjects at all and every
    # closed bead in them counted as unlanded on the panel the operator reads.
    subjects=""
    branches=""
    for _r in $(printf '%s\n' "$closed_pairs" | awk -F'\t' 'NF{print $2}' | sort -u); do
        _p="$(repo_root "$_r")" || continue
        [ -e "$_p/.git" ] || continue
        _refs="$(spira_landrefs "$_p")" || continue
        if _rem="$(ref_remote "${_refs%% *}")"; then git -C "$_p" fetch -q "$_rem" 2>/dev/null; fi
        # shellcheck disable=SC2086
        subjects="$subjects
$(git -C "$_p" log --format='%s%n%b' -n 2000 $_refs 2>/dev/null)"
        branches="$branches
$(git -C "$_p" for-each-ref --format='%(refname:short)' 'refs/heads/spira/' 'refs/remotes/*/spira/' 2>/dev/null)"
    done
    if [ -z "$subjects" ] && [ -z "$branches" ]; then
        echo "SP_CLOSED=?"; echo "SP_LANDED=?"; echo "SP_AWAITING_LAND=?"; echo "SP_UNLANDED=?"
        echo "SP_PEND_N=?"; echo "SP_PEND_OLDEST=?"
    else
        # Subjects on stdin, branches as argv[2], closed_pairs metadata as argv[3].
        # A `---` line in a commit body would split a stdin separator, and commit messages
        # do contain freeform text.
        #
        # _AWAITING lines carry the metadata the PEND section needs, sorted oldest-first by
        # closed_at so the shell loop below emits rows in age order with no second sort.
        local _land_out
        _land_out="$(printf '%s' "$subjects" | python3 -c '
import sys, re, datetime
ids = [i for i in sys.argv[1].split() if i]
br_lines = sys.argv[2].split("\n") if len(sys.argv) > 2 and sys.argv[2] else []
meta = {}
if len(sys.argv) > 3:
    for line in sys.argv[3].split("\n"):
        parts = line.strip().split("\t")
        if len(parts) >= 5:
            meta[parts[0]] = {"pri": parts[2], "cat": parts[3], "title": parts[4]}
text = sys.stdin.read()
landed_set = set(); awaiting_ids = []; never = 0
for i in ids:
    if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(i), text):
        landed_set.add(i)
    elif any(b.rstrip().endswith("/" + i) for b in br_lines if b.strip()):
        awaiting_ids.append(i)
    else:
        never += 1
def cat_key(bid):
    m = meta.get(bid, {})
    try: return datetime.datetime.fromisoformat(m.get("cat", "").replace("Z", "+00:00"))
    except Exception: return datetime.datetime.max.replace(tzinfo=datetime.timezone.utc)
awaiting_ids.sort(key=cat_key)
print("SP_CLOSED=%d"        % len(ids))
print("SP_LANDED=%d"        % len(landed_set))
print("SP_AWAITING_LAND=%d" % len(awaiting_ids))
print("SP_UNLANDED=%d"      % never)
for i in awaiting_ids:
    m = meta.get(i, {})
    print("_AWAITING=%s\t%s\t%s\t%s" % (i, m.get("pri", ""), m.get("cat", ""), m.get("title", "")))
' "$closed_ids" "$branches" "$closed_pairs" 2>/dev/null)"
        if [ -n "$_land_out" ]; then
            printf '%s\n' "$_land_out" | grep '^SP_'

            # ---- PENDING LANDING: individual beads with a branch, not yet on the base ----
            local _pend_n=0 _pend_oldest_age="" _pend_now
            _pend_now="$(date +%s)"
            while IFS=$'\t' read -r _ul_id _ul_pri _ul_cat _ul_title; do
                [ -n "$_ul_id" ] || continue
                local _ul_age="?"
                if [ -n "$_ul_cat" ]; then
                    local _ul_epoch
                    _ul_epoch="$(date -d "$_ul_cat" +%s 2>/dev/null)" || _ul_epoch=""
                    if [ -n "$_ul_epoch" ]; then
                        local _ul_secs=$(( _pend_now - _ul_epoch ))
                        if [ "$_ul_secs" -lt 90 ]; then _ul_age="${_ul_secs}s"
                        elif [ "$_ul_secs" -lt 5400 ]; then _ul_age="$(( _ul_secs / 60 ))m"
                        elif [ "$_ul_secs" -lt 172800 ]; then _ul_age="$(( _ul_secs / 3600 ))h"
                        else _ul_age="$(( _ul_secs / 86400 ))d"; fi
                        [ -z "$_pend_oldest_age" ] && _pend_oldest_age="$_ul_age"
                    fi
                fi
                printf 'SP_PEND%d=P%s %s %s %s\n' "$_pend_n" "${_ul_pri:-?}" "$_ul_id" "$_ul_age" "${_ul_title:--}"
                _pend_n=$((_pend_n + 1))
                [ "$_pend_n" -ge 20 ] && break
            done < <(printf '%s\n' "$_land_out" | sed -n 's/^_AWAITING=//p')
            echo "SP_PEND_N=$_pend_n"
            echo "SP_PEND_OLDEST=${_pend_oldest_age:-0}"
        else
            echo "SP_CLOSED=?"; echo "SP_LANDED=?"; echo "SP_AWAITING_LAND=?"; echo "SP_UNLANDED=?"
            echo "SP_PEND_N=?"; echo "SP_PEND_OLDEST=?"
        fi
    fi
    fi

    # ---- GATE: what is happening between DONE and LANDED --------------------------------
    # The operator (2026-09-07): "there's currently a lot that happens between 'DONE' and
    # 'LANDED' and the ops dashboard shows none of it."
    #
    # landing.status IS ALREADY SP_ KEY=VALUE FORM, written by the landing pass. Concatenate
    # it into the snapshot rather than recomputing any of it — it is the landing pass's own
    # word, and a collector that re-derived it would disagree exactly when it matters.
    if [ -r "$SPIRA_RUN/landing.status" ]; then
        cat "$SPIRA_RUN/landing.status"
    else
        for _k in SP_LAND_AT SP_LAND_RC SP_LAND_BRANCHES SP_LAND_MOVED; do
            echo "$_k=?"
        done
    fi

    # landing.progress — per-branch outcomes of the pass in flight, e.g.
    #   "landed spira/sp-35pl"
    #   "reopened sp-dvlq -- does not rebase onto origin/main"
    # Sanitised for the snapshot: the content is freeform prose from the sentinel, and the
    # snapshot is a KEY=value file the pane sources.
    local lp_n=0
    if [ -r "$SPIRA_RUN/landing.progress" ]; then
        while IFS= read -r _lp; do
            [ -n "$_lp" ] || continue
            _lp="$(printf '%s' "$_lp" | tr -c 'A-Za-z0-9 ._/:,()#+-' ' ' | tr -s ' ')"
            printf 'SP_LANDPROG%d=%s\n' "$lp_n" "${_lp:0:120}"
            lp_n=$((lp_n+1))
        done < "$SPIRA_RUN/landing.progress"
    fi
    echo "SP_LANDPROG_N=$lp_n"

    # gate-run/ — live gate runs. LIVENESS FROM /proc ON argv, never from directory existence
    # or pgrep -f (law-absence-needs-a-positive-control). Nothing prunes gate-run/, so stale
    # directories are the trap: a pid file that points at a dead process, or one recycled by
    # another program, must never render as a live gate.
    local gate_n=0 gate_live=0
    if [ -d "$SPIRA_RUN/gate-run" ]; then
        for _gd in "$SPIRA_RUN/gate-run"/*/; do
            [ -e "$_gd/pid" ] || continue
            local _g_slug _g_pid _g_started _g_age _g_state _g_cmd _g_phase
            _g_slug="$(basename "$_gd")"
            _g_pid="$(cat "$_gd/pid" 2>/dev/null)"; [ -n "${_g_pid:-}" ] || continue
            _g_started="$(cat "$_gd/started" 2>/dev/null)"

            _g_state=dead
            if [ -d "/proc/$_g_pid" ]; then
                # The same stderr-safe pattern as gate-run.sh itself: the shell's failed
                # redirection to a vanished /proc entry goes to stderr, which pollutes the
                # snapshot if not suppressed.
                { _g_cmd="$(tr '\0' ' ' < "/proc/$_g_pid/cmdline")"; } 2>/dev/null
                # argv decides, not the directory. A recycled pid belongs to a different
                # process whose cmdline will not contain 'gate'.
                [[ "${_g_cmd:-}" == *gate* ]] && _g_state=live
            fi

            [ "$_g_state" = live ] || continue
            gate_live=$((gate_live+1))

            if [ -n "${_g_started:-}" ]; then
                _g_age=$(( $(date +%s) - _g_started ))
            else
                _g_age="?"
            fi

            # Waiting on the tree lock vs running suites: gate.sh produces no output
            # until after flock, so an empty out file means the gate is queued.
            if [ -s "$_gd/out" ]; then
                _g_phase=running
            else
                _g_phase=waiting
            fi

            # Why a run is slow — "selecting all" is the line that explains a 650s run.
            local _g_why=""
            if [ "$_g_phase" = running ] && [ -r "$_gd/out" ]; then
                _g_why="$(grep -m1 'selecting' "$_gd/out" 2>/dev/null)"
                _g_why="$(printf '%s' "${_g_why:-}" | tr -c 'A-Za-z0-9 ._/:,()#+-' ' ' | tr -s ' ')"
                _g_why="${_g_why:0:100}"
            fi

            printf 'SP_GATE%d_SLUG=%s\n' "$gate_n" "$_g_slug"
            printf 'SP_GATE%d_AGE=%s\n' "$gate_n" "${_g_age:-?}"
            printf 'SP_GATE%d_PHASE=%s\n' "$gate_n" "$_g_phase"
            [ -n "$_g_why" ] && printf 'SP_GATE%d_WHY=%s\n' "$gate_n" "$_g_why"
            gate_n=$((gate_n+1))
        done
    fi
    echo "SP_GATE_N=$gate_n"
    echo "SP_GATE_LIVE=$gate_live"

    # ---- live aeons --------------------------------------------------------------------
    # /proc, never a directory count and never `pgrep -f`. `gt polecat list` counting
    # DIRECTORIES is the original scar; `pgrep -f` is the second one, where the pattern
    # matches the searching process's own command line. aeon_alive reads argv of the
    # recorded pid.
    #
    # Read-only: a stale pidfile is left where it is rather than swept, because a collector
    # that mutates the state it reports can race the harness that owns it.
    local n=0 pf
    for pf in "$SPIRA_RUN"/aeon-*.pid; do
        [ -e "$pf" ] || continue
        aeon_alive "$pf" && n=$((n+1))
    done
    echo "SP_AEONS=$n"

    # ---- the account's own capacity -----------------------------------------------------
    # "Nothing is moving" and "nothing is moving because the account is out until 15:00" are
    # the same pixels without this, and the first of those is the reading that prompts
    # somebody to go looking for a fault that does not exist.
    #
    # READ-ONLY, unlike everywhere else this predicate is asked. capacity_paused deletes an
    # expired pause file and announces the reopening; a collector that ran every minute would
    # win that race against the sentinel and swallow the announcement into a snapshot nobody
    # reads. So the epoch is compared here by hand and the file is left for its owner.
    local cap_at cap_now
    cap_at="$(capacity_pause_until)"; cap_now="$(date +%s)"
    if [ "${cap_at:-0}" -gt "$cap_now" ] 2>/dev/null; then
        echo "SP_CAPACITY_PAUSED=1"
        echo "SP_CAPACITY_LEFT=$(( cap_at - cap_now ))"
        echo "SP_CAPACITY_AT=$(date -d "@$cap_at" +%H:%M 2>/dev/null)"
        echo "SP_CAPACITY_WHY=$(capacity_pause_why 2>/dev/null)"
    else
        echo "SP_CAPACITY_PAUSED=0"
        echo "SP_CAPACITY_LEFT=0"
        echo "SP_CAPACITY_AT="
        echo "SP_CAPACITY_WHY="
    fi

    # ---- fiends ------------------------------------------------------------------------
    strand_keys

    # ---- TOKENS: what the account is spending, and which half is spending it ------------
    # The rate limit is the binding constraint on everything else on this pane — when the
    # account is out of capacity no aeon can be summoned, no bead can move, and every other
    # figure here is frozen for reasons nothing else reports. It was also unattributed: the
    # harness and the interactive session were both plausible culprits and optimising the
    # wrong one is the expensive mistake.
    #
    # `tokens.sh env` READS ONLY FILES TOUCHED INSIDE THE WINDOW, which is why it can run on
    # every pass at all. The full corpus is billions of tokens of history and re-reading it
    # here would make the instrument cost more than the thing it measures. Do not "simplify"
    # that away by calling `report`.
    "$HERE/tokens.sh" env 2>/dev/null \
      || { for k in SP_TOK_WINDOW_H SP_TOK_AEON_WIN SP_TOK_SESS_WIN SP_TOK_WIN \
                    SP_TOK_AEON_TURNS SP_TOK_SESS_TURNS SP_TOK_AEON_CTX SP_TOK_SESS_CTX \
                    SP_TOK_AEON_OUT SP_TOK_SESS_OUT SP_TOK_AEON_RECENT SP_TOK_SESS_RECENT; do
               echo "$k=?"
           done; }

    # ---- LIVE CONTEXT: how close the session in front of the operator is to the edge -----
    # A total says what was spent; only the proximity says whether to act now, and acting is
    # what the operator can actually do about it. Measured by ctx-meter.sh — the same program
    # the status line calls, deliberately, so the pane and the status line cannot disagree
    # about how close to a threshold a session is.
    "$HERE/ctx-meter.sh" env 2>/dev/null \
      || { for k in SP_CTX_NOW SP_CTX_TURNS SP_CTX_GROWTH SP_CTX_NEXT SP_CTX_HEADROOM \
                    SP_CTX_TURNS_LEFT SP_CTX_AGE SP_CTX_ARCHIVIST SP_CTX_ARCHIVIST_BEHIND \
                    SP_CTX_SCAN_BYTES SP_CTX_ARCHIVIST_FILED \
                    SP_LIMIT_5H_PCT SP_LIMIT_5H_ETA SP_LIMIT_7D_PCT SP_LIMIT_7D_ETA \
                    SP_LIMIT_AGE; do
               echo "$k=?"
           done; }

    # ---- the four numbers this build got wrong -----------------------------------------
    python3 "$HERE/cockpit-metrics.py" \
        "$SPIRA_RUN/sentinel.log" "$SPIRA_RUN/aeon-ledger.log" "$WINDOW_HOURS" 2>/dev/null \
      || { for k in SP_PASSES SP_ACTS SP_FALSE_ACTS SP_FALSE_PER_PASS SP_SINCE_JUDGEMENT \
                    SP_AEON_BORN SP_AEON_LIVED SP_AEON_STILLBORN SP_AEON_WORKED; do
               echo "$k=?"
           done; }
}

# THE SERIES, because a gauge cannot answer "over time". The question the token meter exists
# for is what has been contributing to the rate limit across a day, and no instant answers it.
#
# ITS OWN FILE, under $SPIRA_RUN, for the same reason the snapshot is: the predecessor
# harness's collector owns the other cockpit-history.csv and is deleted along with it. A
# series appended by a service that is being retired stops without anyone noticing, and a
# flat line reads as calm rather than as absent.
#
# EVERY TOKEN COLUMN IS A ROLLING WINDOW TOTAL, not a counter — successive rows overlap and
# must never be summed. That is what makes it readable against the limit, which is itself a
# rolling window: the column IS the thing the account is judged on.
#
# A `?` OR `-` IS WRITTEN THROUGH VERBATIM. A probe that failed and a probe that measured zero
# are different facts, and collapsing them here would put the difference beyond recovery for
# every reader downstream.
HIST="$SPIRA_RUN/cockpit-history.csv"
HISTORY_MAX="${SPIRA_COCKPIT_HISTORY_MAX:-20160}"   # 14 days at the default 60s cadence
HIST_COLS="ts,tok_win,tok_aeon_win,tok_sess_win,tok_aeon_turns,tok_sess_turns,ctx_now"

append_history() {
    # Read back the file just written rather than the probe's own output: the snapshot is what
    # every other reader sees, so a row disagreeing with it would be a third opinion.
    #
    # IN A SUBSHELL, WHICH IS LOAD-BEARING IN `loop` MODE. Sourcing the snapshot into this
    # process leaves its keys set, so the NEXT pass — with a probe that had failed and written
    # no key at all — would quietly reuse the previous pass's figure instead of `?`. A stale
    # number presented as current is precisely the confident wrong reading the `?` rule exists
    # to prevent, and it would be indistinguishable from a healthy flat line.
    local row
    row="$(
        set +u
        # shellcheck disable=SC1090
        . "$SNAP" 2>/dev/null
        printf '%s,%s,%s,%s,%s,%s,%s' \
            "${SP_AT:-$(date +%s)}" "${SP_TOK_WIN:-?}" "${SP_TOK_AEON_WIN:-?}" \
            "${SP_TOK_SESS_WIN:-?}" "${SP_TOK_AEON_TURNS:-?}" "${SP_TOK_SESS_TURNS:-?}" \
            "${SP_CTX_NOW:-?}"
    )"
    # A CHANGED COLUMN SET ROTATES THE FILE RATHER THAN APPENDING A SECOND HEADER. Every reader
    # takes line one as the header, so a header written into the middle is parsed as data and
    # every column after it is read under the wrong name — a series that is quietly wrong is
    # worse than one that is quietly short. The old rows are moved aside, not deleted: they are
    # the only record of what came before, and nothing here is worth destroying to keep the
    # shape tidy.
    if [ ! -s "$HIST" ]; then
        echo "$HIST_COLS" > "$HIST"
    elif [ "$(head -1 "$HIST")" != "$HIST_COLS" ]; then
        mv -f "$HIST" "$HIST.$(date +%s)" 2>/dev/null
        echo "$HIST_COLS" > "$HIST"
    fi
    printf '%s\n' "$row" >> "$HIST"

    local lines; lines=$(wc -l < "$HIST" 2>/dev/null || echo 0)
    if [ "${lines:-0}" -gt $(( HISTORY_MAX + 1 )) ] 2>/dev/null; then
        { head -1 "$HIST"; tail -n "$HISTORY_MAX" "$HIST"; } > "$HIST.tmp" \
            && mv -f "$HIST.tmp" "$HIST"
    fi
}

# The strand ledger, BROKEN OUT BY KIND. strands.json holds every disposition strand.sh
# classifies — ghost, empty, starved, stuck, cycle and the rest — and only `ghost` is the
# labelled failure of a claimed bead whose holder is gone. Reporting its SIZE under that
# one member's name is law-alerts-must-be-actionable in miniature: a childless epic and a
# dead worker counted identically, so a sweep spent four commands hunting for a holder that
# had never existed.
#
# THE KEY IS SPLIT FROM THE RIGHT. It is `<partition>:<kind>:<id>`, and a partition is a
# label list that may itself contain a colon; an id may not. Splitting from the left reads
# the partition as the kind on exactly the entries that are hardest to reason about.
#
# Emitted as its own seam so a suite can drive the classifier the collector actually runs
# rather than a copy of it, the same way `history` exposes append_history.
strand_keys() {
    local f="$SPIRA_RUN/strands.json"
    # No file is not the same claim as no strands: strand.sh writes it on its first pass,
    # so its absence means the detector has not run, which is a different fault.
    if [ -f "$f" ]; then
        python3 -c '
import sys, json
KEYS = ("SP_STRANDS", "SP_STRANDS_ESCALATED", "SP_STRAND_GHOST", "SP_STRAND_OTHER")
try: d = json.load(open(sys.argv[1]))
except Exception:
    for k in KEYS: print("%s=?" % k)
    raise SystemExit
counts, bad = {}, 0
for k in d:
    part = k.rsplit(":", 2)
    if len(part) != 3 or not part[1]:
        bad += 1
        continue
    counts[part[1]] = counts.get(part[1], 0) + 1
print("SP_STRANDS=%d" % len(d))
print("SP_STRANDS_ESCALATED=%d" % sum(1 for v in d.values() if v.get("escalated")))
# AN UNREADABLE KEY MAKES THE GHOST COUNT UNKNOWN, NEVER ZERO (law-absence-needs-a-positive-
# control). The entry that could not be classified may well be a ghost, and a confident 0
# there is precisely the reading that stops anybody looking.
print("SP_STRAND_GHOST=%s" % ("?" if bad else counts.get("ghost", 0)))
rest = ["%s=%d" % (k, counts[k]) for k in sorted(counts) if k != "ghost"]
if bad: rest.append("unclassified=%d" % bad)
# COMMA-SEPARATED, NEVER SPACES. A renderer `source`s the snapshot, and while write_snapshot
# quotes what it writes, this same function is read directly by the suite and by anything
# that evals a bare line.
print("SP_STRAND_OTHER=%s" % (",".join(rest) or "none"))
' "$f" 2>/dev/null && return 0
    fi
    echo "SP_STRANDS=?"; echo "SP_STRANDS_ESCALATED=?"
    echo "SP_STRAND_GHOST=?"; echo "SP_STRAND_OTHER=?"
}

write_snapshot() {
    local tmp="$SPIRA_RUN/.cockpit.$$"
    local writer_unit="${INVOCATION_ID:+spira-cockpit.service}"
    { probe 2>/dev/null; echo "SP_WRITER=$$:${writer_unit:-force}"; } | python3 -c '
import sys
seen = set()
for line in sys.stdin:
    line = line.rstrip("\n")
    if "=" not in line:
        continue
    k, _, v = line.partition("=")
    k = k.strip()
    if not k or not (k[0].isalpha() or k[0] == "_"):
        continue
    # First wins. A key is emitted twice only when a probe printed rows and its fallback
    # then fired as well, and the first of those two is the one that actually measured
    # something — the fallback is a shape guarantee, not a reading.
    if k in seen:
        continue
    seen.add(k)
    print("%s=%s" % (k, "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27"))
' > "$tmp"
    mv -f "$tmp" "$SNAP"
    append_history
}

case "${1:-once}" in
once)
    if cockpit_may_write; then
        write_snapshot
        echo "spira cockpit: $SNAP ($(wc -l < "$SNAP") keys)"
    else
        probe 2>/dev/null
        echo "spira cockpit: keys printed to stdout (not the supervised process)" >&2
    fi
    ;;
# Appends from the snapshot ALREADY ON DISK, taking no fresh reading. It is how the series is
# repaired without disturbing the live snapshot, and it is the seam the suite drives — the
# same function the loop calls, so what is tested is what runs.
history)
    append_history
    echo "spira cockpit: $HIST ($(( $(wc -l < "$HIST") - 1 )) rows)"
    ;;
loop)
    cockpit_may_write || {
        echo "cockpit.sh loop: write refused — not the supervised process. Set SPIRA_COCKPIT_FORCE=1 to override." >&2
        exit 1
    }
    while :; do write_snapshot; sleep "$INTERVAL"; done
    ;;
# The strand ledger's keys alone, taking no other reading. This is the seam the suite drives:
# it is the same function probe calls, so what is tested is what runs.
strands)
    strand_keys
    ;;
*) echo "usage: cockpit.sh [once|loop|history|strands]" >&2; exit 1 ;;
esac
