#!/usr/bin/env bash
#
# literal-lint.sh — refuse configured-name literals outside the files that declare them.
#
#   literal-lint.sh              scan every tracked source file; exit 1 naming each offender
#   literal-lint.sh --scan FILE  scan one file; print line:text per hit; exit 0 either way
#   literal-lint.sh --names      print the configured-name list and exit
#
# THE PROPERTY. schema.sh is the one file that declares configured label, status and type
# names. A name that appears as a literal in any other source file is a name that can
# disagree with the declaration when an operator changes the default — silently, and at read
# time rather than write time. lib.sh:117 grepped for "needs-ryan" while lib.sh:221 read
# ${SPIRA_ASK_LABEL:-needs-ryan}, and the code default is needs-operator, so on a default
# install the destructive-procedure fence had no bypass at all and every legitimate halting
# bead was refused. One accessor per name makes that class unwritable, because there is no
# literal left to write.
#
# WHICH NAMES. Every value schema_name() returns that is specific enough to be unambiguous:
# compound tokens unlikely to appear as coincidental prose. Short single-word names (plan,
# spike, groom, insight) are excluded because they appear legitimately as English words and
# a fence with a high false-positive rate is a fence everybody learns to ignore.
#
# WHAT IS EXEMPT.
#   schema.sh            — the one file allowed to contain these as literals (the declaration)
#   conf.sh              — operator-facing default assignments (:=) for the env variables
#   literal-lint.sh      — this file; its CONFIGURED_NAMES array IS the pattern list
#   test-literal-lint.sh — its test plants examples for the positive control
#   spira/test-*.sh      — test suites seed fixture databases with specific label values and
#                          must control the schema vocabulary they test against; fixture data
#                          is data, not code
#
# THE ESCAPE. A line or its immediately preceding non-empty line carrying `# literal-ok:
# <reason>` is stood down. The marker belongs beside the code, where the next reader of a
# violation message will look; a config file of exemptions is one that nobody reads when it
# matters. Rewriting the literal to slip past the matcher is the one response that leaves
# neither the literal nor the reason.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$(cd "$HERE/.." && pwd -P)"

# THE CONFIGURED NAMES — must match schema.sh schema_name() defaults. Short single-word
# names omitted (plan, incident, spike, groom, insight, scope) because they appear as
# ordinary English words and would produce excessive false positives.
CONFIGURED_NAMES=(
    "needs-operator"
    "awaiting-ci"
    "maechen-sweep"
    "maechen-remedy"
    "review-finding"
    "spira-waiting-operator"
    "world-stop"
)

OVERRIDE_MARKER="literal-ok"

pat() {
    # Build an alternation for awk/grep; names contain only safe regex chars.
    local p="" n
    for n in "${CONFIGURED_NAMES[@]}"; do
        p="${p:+$p|}$n"
    done
    printf '%s' "$p"
}

# scan <file> -> line:text per hit; exit 0 either way.
# Skips: lines that are purely comments (only whitespace before the #);
#        lines carrying the override marker;
#        lines immediately following a line that carries the override marker.
scan() {
    local f="$1"
    local pattern; pattern="$(pat)"
    [ -n "$pattern" ] || return 0
    # Fast path: skip files that contain nothing to match
    grep -qE "$pattern" "$f" 2>/dev/null || return 0
    awk -v PAT="$pattern" -v MARK="$OVERRIDE_MARKER" '
    { L[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            line = L[i]
            # A pure comment line carries no executable literal
            stripped = line; sub(/^[[:space:]]*/, "", stripped)
            if (stripped ~ /^#/) continue
            # The escape hatch: this line or the one directly above carries the marker
            if (line ~ MARK) continue
            if (i > 1 && L[i-1] ~ MARK) continue
            if (line ~ PAT) printf "%d:%s\n", i, line
        }
    }' "$f"
}

case "${1:-}" in
--names)   printf '%s\n' "${CONFIGURED_NAMES[@]}"; exit 0 ;;
--scan)    scan "${2:?--scan needs a file}"; exit 0 ;;
esac

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'literal-lint: %s is not a git repository — nothing to scan\n' "$ROOT" >&2; exit 3; }

# THE INDEX, not the worktree: what the next commit ships is what matters.
mapfile -t files < <(git -C "$ROOT" ls-files)
[ "${#files[@]}" -gt 0 ] || {
    printf 'literal-lint: nothing is tracked — refusing to report clean\n' >&2; exit 3; }

bad=0
for f in "${files[@]}"; do
    case "$f" in
        # DECLARED IN: the canonical declaration and the operator env-var setter
        */schema.sh|schema.sh)                           continue ;;
        */conf.sh|conf.sh)                               continue ;;
        # THIS TOOL AND ITS TEST (content IS the pattern and the planted example)
        */literal-lint.sh|literal-lint.sh)               continue ;;
        */test-literal-lint.sh|test-literal-lint.sh)     continue ;;
        # TEST SUITES — fixture data legitimately carries specific label values; a test that
        # overrides SPIRA_CI_LABEL=awaiting-ci is controlling a fixture, not hardcoding logic
        */test-*.sh|test-*.sh)                           continue ;;
        # JSON — no comment syntax; fixture data in JSON cannot carry literal-ok annotations
        *.json)                                          continue ;;
    esac
    [ -f "$ROOT/$f" ] || continue
    hits="$(scan "$ROOT/$f")"
    [ -n "$hits" ] || continue
    bad=1
    rel="${f#"$ROOT"/}"
    while IFS=: read -r ln text; do
        printf '%s:%s: %s\n' "$rel" "$ln" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
    done <<< "$hits"
done

if [ "$bad" = 0 ]; then
    printf 'literal-lint: clean — %d tracked file(s) contain no configured-name literals\n' "${#files[@]}"
    exit 0
fi
cat >&2 <<'WHY'

REFUSED by literal-lint.sh — the lines above contain a configured label name as a literal.

The names declared in schema.sh must be read through their accessors everywhere else:

  bash spira/schema.sh name <key>    e.g. schema.sh name ci -> awaiting-ci
  $SPIRA_CI_LABEL                    (set by conf.sh; safe after conf.sh is sourced)

A literal that bypasses these accessors can disagree when an operator changes the default:
lib.sh:117 grepped "needs-ryan" while the code default was needs-operator, so the
destructive-procedure fence never matched on a default install and every legitimate halting
bead was refused.

If the use is genuinely correct — a test seeding a fixture, a Python fallback — say so:

    # literal-ok: <why this line has to>

The annotation must be on the offending line or immediately above it.
WHY
exit 1
