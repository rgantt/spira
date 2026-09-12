#!/usr/bin/env bash
#
# census.sh — Maechen census: failure classes ranked by frequency, with open-remedy suppression.
#
#   census.sh [--with-suppressed]
#
# Output: one line per class, "<count> <class>", ranked by frequency, highest first.
# A class with an open remedy bead (carrying labels "$SPIRA_MAECHEN_REMEDY_LABEL" AND
# "covers:<class>") is suppressed: omitted by default, annotated "[suppressed]" when
# --with-suppressed is given.
#
# WHAT COUNTS AS A FAILURE LABEL
#   sp-recur-N-<cause>    an incident bead recurred N times with <cause>
#   sp-requeue-N-<cause>  a bead was requeued N times with <cause>
#   sp-reclaim-N          a bead was reclaimed N times (no cause by design)
#   sp-reclaim-N-<cause>  reclaim with cause (forward-compatible)
#
# CLASS EXTRACTION — the monotonic N is stripped; prefix and cause are kept.
#   sp-recur-3-suite-red     → sp-recur-suite-red
#   sp-recur-1-unrecorded    → sp-recur-unrecorded
#   sp-requeue-4-prod-dirty  → sp-requeue-prod-dirty
#   sp-reclaim-2             → sp-reclaim
#
# Each sp-recur-N-<cause> label IS one occurrence. A bead with three such labels
# (sp-recur-1-*, sp-recur-2-*, sp-recur-3-*) contributes three to the class count —
# that is three recurrences of the same cause, not one bead counted once.
#
# REMEDY SUPPRESSION — a remedy bead carries "covers:<class>" alongside
# "$SPIRA_MAECHEN_REMEDY_LABEL". census.sh suppresses any class whose covers-label
# appears on an open remedy bead. Closing or deleting the remedy bead lifts the
# suppression immediately on the next census run.
#
# WHY THE COVERS LABEL, NOT THE TITLE OR DESCRIPTION
# A label is a machine-readable primary key. A title is human prose and may drift from
# the class name over the bead's lifetime. Grepping a description field requires parsing
# a structured text format that can change. The covers: label is exact, short, and
# queryable without JSON parsing on the receiving side.
#
# WHY PYTHON TEMP FILES INSTEAD OF python3 - <<'PY'
# A pipe sets up stdin for the reader before the process starts. `python3 - <<'PY'`
# has the heredoc override stdin so Python reads its SCRIPT from the heredoc, not from
# the pipe — leaving the pipe writer with no reader (SIGPIPE). Writing the script to a
# temp file and invoking `python3 "$script"` keeps stdin available for the pipe.
#
# covers: spira/census.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib.sh"

WITH_SUPPRESSED=0
case "${1:-}" in --with-suppressed) WITH_SUPPRESSED=1 ;; esac

REMEDY_LABEL="$SPIRA_MAECHEN_REMEDY_LABEL"

_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR"' EXIT INT TERM

# Python: aggregate failure labels → <count> <class> lines, ranked highest first.
cat > "$_TMPDIR/count.py" <<'EOF'
import sys, json, re, collections
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    data = [data]
pat = re.compile(r'^(sp-(?:recur|requeue|reclaim))-(\d+)(.*)$')
c = collections.Counter()
for b in data:
    for lbl in (b.get("labels") or []):
        m = pat.match(lbl)
        if not m:
            continue
        prefix = m.group(1)    # sp-recur / sp-requeue / sp-reclaim
        cause  = m.group(3)    # empty, or "-<cause-with-hyphens>"
        if cause:
            cls = prefix + cause          # sp-recur-suite-red
        elif prefix in ('sp-recur', 'sp-requeue'):
            cls = prefix + '-unrecorded'  # bare label before sp-ycvpd typed it
        else:
            cls = prefix                  # sp-reclaim (no cause by design)
        c[cls] += 1
for cls, n in c.most_common():
    print(n, cls)
EOF

# Python: extract covered classes from open remedy beads → one class per line.
cat > "$_TMPDIR/covers.py" <<'EOF'
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    data = [data]
for b in data:
    for lbl in (b.get("labels") or []):
        if lbl.startswith("covers:"):
            print(lbl[len("covers:"):])
EOF

# Aggregate all failure labels across the whole graph, output <count> <class> ranked.
_census_raw() {
    bdq list --all --json 2>/dev/null | python3 "$_TMPDIR/count.py"
}

# Collect classes already covered by an open remedy bead.
_suppressed_classes() {
    bdq list --status open --label "$REMEDY_LABEL" --json 2>/dev/null \
        | python3 "$_TMPDIR/covers.py"
}

# Build suppressed set as a newline-delimited file for grep -xF membership tests.
_suppressed_classes > "$_TMPDIR/suppressed.txt"

# Emit the ranked census, suppressing (or annotating) remedy-covered classes.
while IFS=' ' read -r count class; do
    if grep -qxF "$class" "$_TMPDIR/suppressed.txt" 2>/dev/null; then
        [ "$WITH_SUPPRESSED" -eq 1 ] && printf '%s %s [suppressed]\n' "$count" "$class"
    else
        printf '%s %s\n' "$count" "$class"
    fi
done < <(_census_raw)
