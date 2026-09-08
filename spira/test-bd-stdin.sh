#!/usr/bin/env bash
#
# test-bd-stdin.sh — bd note and bd create must use --stdin / --body-file for prose on stdin.
#
# WHAT THIS SUITE IS GUARDING
# ----------------------------
# `bd note <id> - <<'EOF'` records the literal "-" and discards the heredoc body:
# bd note takes prose as positional arguments, so "-" is stored verbatim and exits 0.
# Likewise `bd create ... -d - <<'EOF'` — -d/--description is a plain string flag.
#
# The correct forms:
#   bd note  <id>    --stdin       <<'EOF'
#   bd create <title> --body-file - <<'EOF'
#
# This defect produced six beads with a dash where their body or notes should be (sp-j5z3).
#
# THE POSITIVE CONTROL IS FIRST. We plant a synthetic file containing the bad pattern and
# confirm the check catches it. Only after that do we run the check over the real sources.
# A check that finds nothing is indistinguishable from one pointed at the wrong place.
#
# defect: sp-j5z3
# covers: spira/chamber/archivist.md spira/chamber/builder.md spira/chamber/spike.md
# covers: spira/chamber/ops.md spira/*.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "${2:-}"; }
want(){ case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "wanted [$2] in [$3]"; esac; }

echo "test-bd-stdin.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# --------------------------------------------------------------------------
# Helpers: scan a file or directory for the two bad patterns.
# Returns lines matching the pattern, empty string if none found.
# --------------------------------------------------------------------------

# Bad pattern 1: `bd note <id> - <<`  (bare dash as body, heredoc discarded).
# Skips comment lines (leading #) so documentation in this file does not self-report.
scan_note_dash() {
    grep -rnE 'bd[[:space:]].*note[[:space:]].*[[:space:]]-[[:space:]]<<' "$@" 2>/dev/null \
        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true
}

# Bad pattern 2: `bd create ... -d - ` or `bd create ... --description -`.
# Same comment-line exclusion.
scan_create_dash() {
    grep -rnE 'bd[[:space:]].*create[[:space:]].*(-d[[:space:]]+-|-d-|--description[[:space:]]+-)[[:space:]]*(<|$|[^-])' "$@" 2>/dev/null \
        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true
}

# ==========================================================================
echo
echo "positive control — the scanner detects the bad patterns in synthetic files:"
# ==========================================================================

# Plant bad note pattern.
BAD_NOTE="$TMP/bad-note.sh"
cat > "$BAD_NOTE" <<'EOF'
#!/usr/bin/env bash
bd -C /db note sp-abc - <<'NOTE'
some text
NOTE
EOF

# Plant bad create pattern.
BAD_CREATE="$TMP/bad-create.md"
cat > "$BAD_CREATE" <<'EOF'
bd -C {{DB}} create "title" -d - -l plan <<'BODY'
prose here
BODY
EOF

# Plant a clean file that uses --stdin / --body-file correctly.
CLEAN="$TMP/clean.sh"
cat > "$CLEAN" <<'EOF'
#!/usr/bin/env bash
bd -C /db note sp-abc --stdin <<'NOTE'
some text
NOTE
bd -C /db create "title" --body-file - -l plan <<'BODY'
prose here
BODY
EOF

hit_note="$(scan_note_dash "$BAD_NOTE")"
[ -n "$hit_note" ] && ok "scanner catches bare-dash note in synthetic file" \
    || bad "scanner catches bare-dash note in synthetic file" "no match returned"

hit_create="$(scan_create_dash "$BAD_CREATE")"
[ -n "$hit_create" ] && ok "scanner catches bare-dash create in synthetic file" \
    || bad "scanner catches bare-dash create in synthetic file" "no match returned"

# Confirm the scanner is silent on clean usage — a scanner that fires on --stdin is broken.
clean_note="$(scan_note_dash "$CLEAN")"
[ -z "$clean_note" ] && ok "scanner is silent on --stdin usage" \
    || bad "scanner is silent on --stdin usage" "false positive: $clean_note"

clean_create="$(scan_create_dash "$CLEAN")"
[ -z "$clean_create" ] && ok "scanner is silent on --body-file usage" \
    || bad "scanner is silent on --body-file usage" "false positive: $clean_create"

# ==========================================================================
echo
echo "real sources — no bare-dash bd note or bd create in chamber or scripts:"
# ==========================================================================

SOURCES=("$HERE" "$HERE/chamber")
THIS="$(basename "$0")"   # exclude this file — it embeds the bad patterns as positive-control fixtures

found_note="$(scan_note_dash "${SOURCES[@]}" | grep -v "/$THIS:")"
[ -z "$found_note" ] && ok "no bare-dash bd note in sources" \
    || bad "no bare-dash bd note in sources" "$(printf '\n%s' "$found_note")"

found_create="$(scan_create_dash "${SOURCES[@]}" | grep -v "/$THIS:")"
[ -z "$found_create" ] && ok "no bare-dash bd create in sources" \
    || bad "no bare-dash bd create in sources" "$(printf '\n%s' "$found_create")"

# ==========================================================================
echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
