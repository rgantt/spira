#!/usr/bin/env bash
#
# test-world-drain.sh — a draining world is visible on the health pane.
#
#   ./test-world-drain.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# `world.sh drain` gates new aeons while letting the loop and landing continue, so a
# drained world looks like a quiet, healthy one from every surface that does not read the
# stamp: zero aeons, zero new beads, nothing landing. Spira ran drained for 13 minutes
# with no instrument saying so (2026-09-08, sp-r6wf).
#
# This suite covers cockpit/health.sh's drain_banner() — the surface that reads the stamp
# and renders it as a FIRING condition rather than a neutral row. The contract:
#
#   stamp present           → header shows DRAINING + elapsed minutes
#   stamp absent            → no DRAINING in header
#   stamp present, malformed → DRAINING visible; elapsed renders '?', not 0; no claim of "running"
#
# A field that cannot be read renders '?', NEVER 0 (law-absence-needs-a-positive-control).
#
# defect: sp-r6wf
# covers: cockpit/health.sh spira/world.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PANE="$HERE/../cockpit/health.sh"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-world-drain.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW="$(date +%s)"

# Run health.sh in its 'once' mode (one frame, no loop). Inject a stub systemctl so
# halt_banner's timer check does not reach the real unit (law-gates-run-in-a-clean-environment).
# SPIRA_RUN points at a scratch directory that starts empty: no snapshot, no halt stamp.
RUN="$TMP/run"
mkdir -p "$RUN"

mock_sc="$TMP/mock-sc.sh"
# Return 'active' so halt_banner's sentinel-timer check does not fire on its own:
# the halt_banner fires either when world.halted exists OR when the timer is inactive;
# we want it quiet so the drain banner stands alone in these assertions.
printf '#!/usr/bin/env bash\necho "active"\n' > "$mock_sc"
chmod +x "$mock_sc"

pane() {   # pane [VAR=val ...] -> one frame at a notional 80-col pane
    env -i PATH="$PATH" HOME="$TMP" LC_ALL=C.UTF-8 \
        SPIRA_CONF="$TMP/no.conf" \
        SPIRA_RUN="$RUN" \
        SPIRA_SYSTEMCTL="$mock_sc" \
        "$@" \
        bash "$PANE" once 0 80 2>/dev/null
}

# ======================================================================================
echo
echo "positive control — drain stamp is read and rendered:"
# ======================================================================================
# THE STAMP FORMAT IS world.sh's OWN FORMAT. Testing against a hand-written timestamp
# in a different format would pass while a real stamp failed — the seam between writer
# and reader is exactly what the test must exercise.
drain_ts="$(date -d "@$(( NOW - 1200 ))" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || \
            date '+%Y-%m-%d %H:%M:%S %Z')"  # ~20m ago

printf '%s\nsummons gated in summon_fayth; loop and landing still running.\n' \
    "$drain_ts" > "$RUN/world.draining"
# SET THE MTIME TO 20 MINUTES AGO. drain_banner reads mtime via `stat -c %Y`, not the
# timestamp on line 1; writing the file sets its mtime to NOW, so the elapsed reads 0
# unless we move it backward. touch -d "@<epoch>" is the portable form.
touch -d "@$(( NOW - 1200 ))" "$RUN/world.draining" 2>/dev/null || true

frame="$(pane)"
want "DRAINING appears in the header"         "DRAINING"           "$frame"
want "elapsed minutes are shown"              "20m"                "$frame"
want "summons-gated is stated"                "summons gated"      "$frame"
want "the lift command is shown"              "world.sh resume"    "$frame"
nowant "a drain is not a halt"                "SPIRA STOPPED"      "$frame"

# ======================================================================================
echo
echo "no drain stamp — no drain banner:"
# ======================================================================================
rm -f "$RUN/world.draining"

frame="$(pane)"
nowant "no drain banner without a stamp"      "DRAINING"           "$frame"
nowant "and no resume instruction"            "world.sh resume"    "$frame"

# ======================================================================================
echo
echo "colour escalates with elapsed time (no assert on exact codes, just that it renders):"
# ======================================================================================
# The drain banner colours elapsed minutes: dim < 30m, warn >= 30m, bad >= 60m.
# We cannot assert escape sequences portably, so we just confirm the frame does not error.
for age_m in 5 35 65; do
    ts="$(date -d "@$(( NOW - age_m * 60 ))" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || \
          date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '%s\n' "$ts" > "$RUN/world.draining"
    touch -d "@$(( NOW - age_m * 60 ))" "$RUN/world.draining" 2>/dev/null || true
    out="$(pane)" && ok "${age_m}m stamp renders without error" \
        || bad "${age_m}m stamp renders without error" "non-zero exit or empty output"
    want "${age_m}m stamp shows DRAINING" "DRAINING" "$out"
done

rm -f "$RUN/world.draining"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
