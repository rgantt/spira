#!/usr/bin/env bash
#
# slay.sh — stop one aeon cleanly and make its bead say what is true.
#
#   slay.sh <bead-id>                      stop it, release the bead (open, unassigned), nuke its work
#   slay.sh <bead-id> --close "<reason>"   ...and close the bead with that reason instead of reopening
#   slay.sh <bead-id> --keep-work          ...but leave its branch and worktree in place
#   slay.sh <bead-id> --why "<text>"       what the note on the bead says the operator's reason was
#
# WHAT "CLEANLY" MEANS, in order, because each step is the one the next depends on:
#   1. A MARKER FIRST, so the aeon's own exit path knows it was slain. aeon.sh charges an
#      attempt on any non-zero exit — a kill is 143 — and three attempts poison a bead. An
#      operator stopping an aeon is not evidence the bead is hard, so the marker makes the
#      exit path release the bead with no attempt charged, the way a spent capacity window
#      already does.
#   2. THE UNIT, NOT THE PID. An aeon is a transient systemd unit with KillMode=control-group,
#      so stopping the unit takes the session, its heartbeat and every child with it. A bare
#      kill of the runner leaves the model session running headless. The pid is the fallback
#      for an aeon that has no unit (a fixture, a hand-run one), and it is matched from the
#      unit's MainPID — never `pkill -f`, which nominates the caller too (law-pgrep-nominates).
#   3. WAIT FOR THE EXIT PATH TO FINISH. The pid file is removed by aeon.sh's own cleanup,
#      after it has released the bead; the pid file going away is the signal that the bead is
#      now ours to set, not a hint that the process is dead.
#   4. THE BEAD SAYS WHAT IS TRUE. Unassigned always — `bd ready --claim` skips an assigned
#      bead while `bd ready` still lists it, which left seven reopened beads unclaimable for
#      hours. Open by default; closed with a reason on request; the `branch:` label comes
#      off with the branch.
#   5. THE WORK. Salvage first — a patch of anything uncommitted lands in $SPIRA_RUN/reaped,
#      the same insurance the reaper carries — then the rebase in progress is aborted, the
#      worktree removed, the branch deleted with its tip sha written into the bead's note.
#      Deleted is recoverable from the reflog for a month; a note without the sha is not.
#   6. SAY WHAT WAS DONE, with the evidence, and exit non-zero on anything it could not do.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ID=""; MODE=reopen; REASON=""; KEEP=0; WHY="slain by the operator"
while [ $# -gt 0 ]; do
    case "$1" in
        --close)     MODE=close; REASON="${2:?--close needs a reason}"; shift ;;
        --reopen)    MODE=reopen ;;
        --keep-work) KEEP=1 ;;
        --why)       WHY="${2:?--why needs text}"; shift ;;
        -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
        -*)          echo "slay.sh: unknown flag $1" >&2; exit 2 ;;
        *)           ID="$1" ;;
    esac
    shift
done
[ -n "$ID" ] || { echo "usage: slay.sh <bead-id> [--close \"<reason>\"] [--keep-work] [--why \"<text>\"]" >&2; exit 2; }
fail=0
say() { printf '%s\n' "$*"; }

# ---- 1. the marker ---------------------------------------------------------------------
printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WHY" > "$SPIRA_RUN/$ID.slain"

# ---- 2. the aeon -----------------------------------------------------------------------
pf="$(ls "$SPIRA_RUN"/aeon-*-"$ID".pid 2>/dev/null | head -1)"
pid=""; [ -n "$pf" ] && pid="$(cat "$pf" 2>/dev/null)"
name=""; [ -n "$pf" ] && name="$(cat "${pf%.pid}.name" 2>/dev/null)"
unit=""
if [ -n "$pid" ] && command -v systemctl >/dev/null 2>&1; then
    for u in $(systemctl --user list-units 'spira-aeon-*' --no-legend 2>/dev/null | awk '{print $1}'); do
        [ "$(systemctl --user show -p MainPID --value "$u" 2>/dev/null)" = "$pid" ] && { unit="$u"; break; }
    done
fi
if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
    say "aeon: none running for $ID (no live pid file) — setting the bead and the work only"
    rm -f "$SPIRA_RUN/$ID.slain"
    # A pid file whose process is gone is litter from an aeon that died without its cleanup;
    # aeon_count removes the same litter, and leaving it here fails the verify below.
    [ -n "$pf" ] && rm -f "$pf" "${pf%.pid}.name"
else
    if [ -n "$unit" ]; then
        say "aeon: ${name:-?} pid $pid is $unit — stopping the unit"
        systemctl --user stop "$unit" 2>/dev/null || { say "aeon: systemctl stop failed — sending TERM to $pid"; kill -TERM "$pid" 2>/dev/null; }
    else
        say "aeon: ${name:-?} pid $pid has no unit — sending TERM"
        kill -TERM "$pid" 2>/dev/null
    fi
    # ---- 3. wait for aeon.sh's own cleanup: it removes the pid file last -------------------
    t0=$(date +%s)
    while [ -e "$pf" ] || [ -d "/proc/$pid" ]; do
        sleep 1
        if [ $(( $(date +%s) - t0 )) -ge 60 ]; then
            say "aeon: still alive after 60s — KILL"
            kill -KILL "$pid" 2>/dev/null; sleep 1
            rm -f "$pf" "${pf%.pid}.name"
            break
        fi
    done
    [ -d "/proc/$pid" ] && { say "aeon: pid $pid SURVIVED a KILL — investigate by hand"; fail=1; } \
                        || say "aeon: stopped ($(( $(date +%s) - t0 ))s)"
fi
rm -f "$SPIRA_RUN/$ID.slain"

# ---- 5. the work (before the bead, so the note can carry the sha) ---------------------
repo_name="$(bead_repo "$ID" 2>/dev/null)"; repo=""
[ -n "$repo_name" ] && repo="$(repo_root "$repo_name" 2>/dev/null)"
br="spira/$ID"; wt="$SPIRA_RUN/worktree/$ID"; tip=""; nuked=""
if [ -n "$repo" ] && git -C "$repo" show-ref --verify -q "refs/heads/$br"; then
    tip="$(git -C "$repo" rev-parse --short "$br")"
fi
if [ "$KEEP" = 1 ]; then
    say "work: kept — branch $br${tip:+ at $tip}, worktree $wt"
elif [ -n "$repo" ]; then
    if [ -d "$wt" ]; then
        git -C "$wt" rebase --abort >/dev/null 2>&1 || true
        git -C "$wt" merge --abort  >/dev/null 2>&1 || true
        if salvage "$ID" "$wt"; then
            [ -n "${SALVAGED:-}" ] && say "work: uncommitted changes salvaged to $SALVAGED"
        else
            say "work: could not salvage $wt — leaving it in place"; fail=1
        fi
        if [ "$fail" = 0 ]; then
            git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
            spira_prune_worktrees "$repo" >/dev/null 2>&1
            say "work: worktree $wt removed"
        fi
    fi
    if [ -n "$tip" ] && [ "$fail" = 0 ]; then
        if git -C "$repo" branch -D "$br" >/dev/null 2>&1; then
            nuked="branch $br deleted at $tip (reflog keeps it ~30 days)"; say "work: $nuked"
        else
            say "work: could not delete $br"; fail=1
        fi
    fi
else
    say "work: bead names no resolvable repository — nothing to remove"
fi

# ---- 4. the bead -----------------------------------------------------------------------
# A LIVE CLAIM IS ANOTHER ACTOR'S, and bd refuses to overwrite one without being told the
# claim is abandoned — which is exactly what this script has just made true. unclaim is the
# release the aeon itself would have performed; --force on update is the fallback for a bead
# whose claim survived its own exit path.
status_of() { bdjson show "$ID" | python3 -c 'import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("status","") if d else "")' 2>/dev/null; }
st="$(status_of)"
if [ "$st" = in_progress ]; then
    bdq unclaim "$ID" --force >/dev/null 2>&1 || bdq unclaim "$ID" >/dev/null 2>&1 || true
fi
bdq update "$ID" --assignee "" --force >/dev/null 2>&1 || bdq update "$ID" --assignee "" >/dev/null 2>&1
if [ -n "$nuked" ]; then bdq label remove "$ID" "branch:$br" >/dev/null 2>&1 || true; fi
note="Slain by the operator: $WHY. Aeon ${name:-?}${pid:+ (pid $pid)} stopped${unit:+ via $unit}. ${nuked:-work kept}${SALVAGED:+; uncommitted changes salvaged to $SALVAGED}. No attempt charged."
st="$(status_of)"
case "$MODE" in
    close)  if [ "$st" = closed ]; then
                # Already closed — by the aeon before it was stopped, or by hand. The reason
                # still belongs on the record; re-closing would fail and say nothing.
                bdq note "$ID" "$REASON — $note" >/dev/null 2>&1
            else
                bdq close "$ID" --reason "$REASON — $note" >/dev/null 2>&1 || { say "bead: close failed"; fail=1; }
            fi ;;
    reopen) [ "$st" = open ] || bdq reopen "$ID" >/dev/null 2>&1
            bdq note "$ID" "$note" >/dev/null 2>&1 ;;
esac
bdjson show "$ID" | python3 -c '
import sys,json
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; b=d[0] if d else {}
print("bead: %s status=%s assignee=%s labels=%s" % (b.get("id"), b.get("status"), b.get("assignee") or "-", ",".join(b.get("labels") or [])))' 2>/dev/null

# ---- 6. verify -------------------------------------------------------------------------
[ -z "$pid" ] || [ ! -d "/proc/$pid" ] || fail=1
ls "$SPIRA_RUN"/aeon-*-"$ID".pid >/dev/null 2>&1 && { say "verify: a pid file for $ID remains"; fail=1; }
[ "$KEEP" = 1 ] || [ -z "$repo" ] || ! git -C "$repo" show-ref --verify -q "refs/heads/$br" || { say "verify: $br still exists"; fail=1; }
[ "$fail" = 0 ] && say "slain: $ID" || say "slay: INCOMPLETE for $ID — see above"
exit "$fail"
