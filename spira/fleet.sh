#!/usr/bin/env bash
#
# fleet.sh — how many aeons may work at once.
#
#   fleet.sh              what the fleet is set to now
#   fleet.sh <n>          set the fleet to n concurrent aeons
#
# WHY THIS EXISTS AS A PROGRAM AND NOT A LINE IN A CONFIG FILE.
# ------------------------------------------------------------
# "Three aeons" is one intention and it is spelled across TWO keys that do not mean the
# same thing. SPIRA_MAX_AEONS is the task pool — builders and other task fayths. Lanes
# (ops, qa, groomer) draw OUTSIDE that pool, so a pool of 3 permits six aeons, and a pool
# of 1 still ran a builder and an ops aeon in the same second. SPIRA_MAX_LIVE_AEONS is the
# ceiling that counts every aeon regardless of how it was drawn.
#
# Setting one and not the other is how "bump it to 3" produces something that is not 3:
# ceiling 3 with pool 1 is one builder and two lanes, which starves the pool while lane
# slots sit idle, and pool 3 with ceiling 1 is three permitted builders of which one may
# ever run. Both readings are defensible and neither is what was asked for, so this writes
# both from a single number and the ambiguity has nowhere left to live.
#
# THREE IS WHAT THIS BOX CARRIES. Four was tried on 2026-09-07 and returned to three in 46
# minutes: 22 aeons summoned, 10 exited with beads still in_progress, nothing landed, load
# 5.04 on 4 cores. Above three this refuses rather than obeys — a fence is a polite refusal
# and not a wall, so it names its own override.
#
# THE WRITE IS ATOMIC. Live aeons, the sentinel and every hook read this file continuously;
# a config caught half-written is read as a config with keys missing, and a missing ceiling
# is an unbounded fleet. Written beside and moved into place, so a reader sees one version
# or the other and never a partial one.
set -uo pipefail

CONF="${SPIRA_CONF:-$HOME/.config/spira/spira.conf}"
CEILING_KEY="SPIRA_MAX_LIVE_AEONS"
POOL_KEY="SPIRA_MAX_AEONS"
MAX_SANE="${SPIRA_FLEET_MAX_SANE:-3}"

[ -r "$CONF" ] || { printf 'fleet: no readable config at %s\n' "$CONF" >&2; exit 1; }

# Read a key's value as the config actually spells it: `KEY = value`, with whatever
# alignment padding it carries. Comment lines mentioning the key must not match, so the
# key is anchored to the start of the line.
conf_value() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$CONF" | tail -1; }

show() {
    printf 'fleet    %s concurrent aeon(s)\n' "$(conf_value "$CEILING_KEY")"
    printf '  %-22s %s   (the ceiling — counts every aeon)\n' "$CEILING_KEY" "$(conf_value "$CEILING_KEY")"
    printf '  %-22s %s   (the task pool — lanes draw outside it)\n' "$POOL_KEY" "$(conf_value "$POOL_KEY")"
    printf '  config                 %s\n' "$CONF"
}

[ $# -eq 0 ] && { show; exit 0; }

N="$1"
case "$N" in
    ''|*[!0-9]*) printf 'fleet: "%s" is not a whole number\n' "$N" >&2; exit 1 ;;
esac
[ "$N" -ge 1 ] || { printf 'fleet: a fleet of %s runs nothing; use spira-world to stop the loop\n' "$N" >&2; exit 1; }
if [ "$N" -gt "$MAX_SANE" ] && [ -z "${SPIRA_FLEET_CONSIDERED:-}" ]; then
    printf 'fleet: REFUSED — %s exceeds the %s this box is known to carry.\n' "$N" "$MAX_SANE" >&2
    printf '  Four was tried on 2026-09-07 and returned to three in 46 minutes: 22 summoned,\n' >&2
    printf '  10 exited with beads still in_progress, nothing landed, load 5.04 on 4 cores.\n' >&2
    printf '  Override: SPIRA_FLEET_CONSIDERED=1 %s %s\n' "$0" "$N" >&2
    exit 1
fi

# BOTH KEYS OR NEITHER. The temp file is written from the original in one pass and moved
# over it, so a failed edit leaves the config exactly as it was.
TMP="$(mktemp "${CONF}.XXXXXX")" || exit 1
trap 'rm -f "$TMP"' EXIT
sed -e "s/^\($CEILING_KEY[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\1$N/" \
    -e "s/^\($POOL_KEY[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\1$N/" \
    "$CONF" > "$TMP" || exit 1

# THE EDIT IS CHECKED BEFORE IT IS INSTALLED. A sed that matched nothing exits 0 and
# prints the file back unchanged, which would report success over a config that never
# moved (law-absence-needs-a-positive-control).
for k in "$CEILING_KEY" "$POOL_KEY"; do
    got="$(sed -n "s/^$k[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$TMP" | tail -1)"
    [ "$got" = "$N" ] || { printf 'fleet: %s did not take (still %s) — nothing written\n' "$k" "${got:-absent}" >&2; exit 1; }
done

chmod --reference="$CONF" "$TMP" 2>/dev/null || true
mv -f "$TMP" "$CONF" || exit 1
trap - EXIT

show
