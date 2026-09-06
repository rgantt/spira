#!/usr/bin/env bash
#
# install-intake.sh — wire the systemd failure alerts into Spira's incident intake.
#
#   install-intake.sh install     add the drop-in to every alert template
#   install-intake.sh status      which templates are wired, which are not
#   install-intake.sh uninstall   remove every drop-in this installed
#
# WHAT IT WIRES
# -------------
# An alert unit fired from `OnFailure=` on every unit worth hearing about typically pushes
# the journal tail somewhere a human will see it. This adds a second ExecStart that files the
# same event as an incident bead, so the event becomes work with an identity rather than a
# notification that scrolls past.
#
# WHY A DROP-IN AND NOT AN EDIT
# -----------------------------
# The alert templates may be RENDERED per store by a repository's own deploy, so anything written
# into the unit file is overwritten by the next deploy — silently, which is the worst
# version. A drop-in lives in a sibling `.d/` directory the renderer does not touch, so the
# wiring survives a redeploy. It is also the only form that can be removed cleanly, because
# it is the only form whose contents this program owns.
#
# WHY IT REPAIRS RATHER THAN CREATES
# ----------------------------------
# A new store gets a new alert template and would not be wired by an install that ran once,
# months ago. This is idempotent and cheap, and `spira-ops.service` runs it as ExecStartPre
# on every pass — the cockpit-ensure lesson: a repair loop hung off a session cannot repair
# the case where the session died.
#
# WHY ExecStart= IS PREFIXED WITH '-'
# -----------------------------------
# So a failure to file the bead cannot fail the ALERT unit. The alert is the path that
# already works and reaches the operator's phone; intake is the addition. An addition that can
# break the thing it was added to is not an improvement. incident.sh spools the payload to
# disk before it touches the database, so a failure here loses a log line and not an event.
set -uo pipefail

# The glob is a configuration key, so it reaches this from spira.conf as well as from the
# environment — it runs as an ExecStartPre, where a login shell's environment does not exist.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/conf.sh"
SPIRA_HOME="${SPIRA_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
UNITDIR="${SPIRA_UNITDIR:-$HOME/.config/systemd/user}"
# WHICH TEMPLATES, AND THERE IS NO DEFAULT. `SPIRA_ALERT_GLOB` names your own alert units and
# nothing here can guess it; unset, this refuses with a sentence rather than wiring whatever
# happens to match. A default would be one operator's inventory, and the wrong one silently
# wires nothing while reporting success.
#
# NAME ONLY THE UNITS WHOSE FAILURE IS ACTIONABLE. Where alert templates are rendered per
# environment, most of them usually belong to development instances that fail routinely and by
# design; wiring those fills the Ops queue with events that have no action, which is the
# definition of a false alert. Widening the glob is a deliberate act, one at a time.
#
# The value is a `find -name` pattern, so `*` `?` and `[...]` work and brace expansion does not:
#     SPIRA_ALERT_GLOB='alert-prod@.service' install-intake.sh install
PATTERN="${SPIRA_ALERT_GLOB:-}"
if [ -z "$PATTERN" ]; then
    echo "install-intake: SPIRA_ALERT_GLOB is unset — nothing to wire." >&2
    echo "  Set it to a find(1) name pattern matching the alert units whose failure you want" >&2
    echo "  filed as incident beads, e.g. SPIRA_ALERT_GLOB='alert-prod@.service'." >&2
    exit 0
fi
DROPIN=50-spira-intake.conf
RELOAD="${SPIRA_SYSTEMCTL_RELOAD:-1}"

conf_body() {
cat <<CONF
# Installed by $SPIRA_HOME/install-intake.sh — do not edit; it is overwritten.
#
# A second ExecStart on a Type=oneshot unit runs after the first, so the Pushover alert
# still goes out first and this cannot delay it. The leading '-' makes the failure of
# intake a non-failure of the alert.
[Service]
ExecStart=-$SPIRA_HOME/incident.sh systemd %i
CONF
}

templates() { find "$UNITDIR" -maxdepth 1 -name "$PATTERN" 2>/dev/null | sort; }

case "${1:-status}" in

install)
    [ -d "$UNITDIR" ] || { echo "install-intake: no $UNITDIR" >&2; exit 1; }
    [ -x "$SPIRA_HOME/incident.sh" ] || {
        echo "install-intake: refusing — $SPIRA_HOME/incident.sh is not executable." >&2
        echo "  A drop-in pointing at a script that cannot run is a wire that reports" >&2
        echo "  installed and delivers nothing." >&2; exit 1; }
    n=0; changed=0
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        n=$((n+1))
        d="$t.d"; mkdir -p "$d"
        if [ -f "$d/$DROPIN" ] && diff -q <(conf_body) "$d/$DROPIN" >/dev/null 2>&1; then
            continue
        fi
        conf_body > "$d/$DROPIN"; chmod 0644 "$d/$DROPIN"
        echo "wired    $(basename "$t")"; changed=$((changed+1))
    done < <(templates)
    [ "$n" -eq 0 ] && { echo "install-intake: no templates match $PATTERN in $UNITDIR" >&2; exit 1; }
    [ "$changed" -gt 0 ] && [ "$RELOAD" = 1 ] && systemctl --user daemon-reload 2>/dev/null

    # VERIFY THE EFFECT, never the attempt. `sending.sh` was written because a cleanup step
    # reported success on the strength of having tried; a drop-in that systemd has not
    # actually loaded is the same defect wearing a config file.
    bad=0
    if [ "$RELOAD" = 1 ] && command -v systemctl >/dev/null 2>&1; then
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            u="$(basename "$t")"
            if ! systemctl --user cat "${u%@.service}@probe.service" 2>/dev/null \
                 | grep -qF 'incident.sh systemd'; then
                echo "FAILED   $u — drop-in written but systemd does not show it" >&2
                bad=$((bad+1))
            fi
        done < <(templates)
    fi
    echo "install-intake: $n template(s), $changed changed, $bad unverified"
    [ "$bad" -eq 0 ]
    ;;

status)
    n=0; wired=0
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        n=$((n+1))
        if [ -f "$t.d/$DROPIN" ]; then wired=$((wired+1)); echo "wired    $(basename "$t")"
        else echo "UNWIRED  $(basename "$t")"; fi
    done < <(templates)
    echo "$wired of $n alert template(s) wired to incident.sh"
    [ "$n" -gt 0 ] && [ "$wired" -eq "$n" ]
    ;;

uninstall)
    n=0
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        if [ -f "$t.d/$DROPIN" ]; then
            rm -f "$t.d/$DROPIN"; rmdir "$t.d" 2>/dev/null
            echo "unwired  $(basename "$t")"; n=$((n+1))
        fi
    done < <(templates)
    [ "$n" -gt 0 ] && [ "$RELOAD" = 1 ] && systemctl --user daemon-reload 2>/dev/null
    echo "install-intake: removed $n drop-in(s)"
    ;;

*) sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
