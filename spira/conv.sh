#!/usr/bin/env bash
#
# conv.sh — launch an interactive Claude session that can be metered.
#
#   conv.sh [options] [-- <claude args>...]
#
#     --account <name>     label these readings; default: the account's own email
#     --config-dir <dir>   which account to run as; default: $CLAUDE_CONFIG_DIR or ~/.claude
#     --every <seconds>    resample while the session runs (default 300, 0 disables)
#     --no-sample          take no readings at all; just launch
#     --read               take one reading, print it, and exit (no session)
#
# WHY THIS EXISTS
# ---------------
# The harness can see how full an aeon's account is and cannot see how full the OPERATOR's
# is, which is exactly backwards: an aeon that runs out is a retry, and an operator who runs
# out is a person who cannot work.
#
# The asymmetry is structural, not an oversight. Utilization arrives in a `rate_limit_event`
# record, and that record exists only in the stream-json output of a `-p` run. Interactive
# transcripts under `projects/` do not carry it — checked directly on 2026-09-09: the two
# newest held 512 `assistant` records and zero rate-limit events. Nothing on disk carries it
# either; `stats-cache.json` is token counts, and on this box it had not been recomputed
# since February.
#
# So the reading has to be ASKED FOR. One `claude -p` call on the smallest model returns both
# windows for the account that made it:
#
#     "unifiedWindows": {"five_hour":  {"utilization": 0.07, "resetsAt": ...},
#                        "seven_day":  {"utilization": 0.01, "resetsAt": ...}}
#
# That is the whole mechanism. This wrapper runs the session you asked for and takes that
# reading around it — before, optionally during, and after — so the account you actually work
# on becomes as visible as the ones the aeons use.
#
# THE PROBE IS NOT FREE, AND SAYS SO. It spends a few hundred tokens of the window it is
# measuring, and it writes a small transcript into that account's `projects/` tree, which the
# token accounting in tokens.sh will see. Both are negligible against sessions that read
# millions of cached tokens per turn — but "negligible" is a judgement, so `--every 0` and
# `--no-sample` exist and the cost is stated rather than hidden.
#
# WHAT IT NEVER DOES: change your session. argv passes through untouched, the terminal is
# yours, and the exit code is Claude's. If the probe fails, the session still runs — an
# instrument that can prevent you working is worse than no instrument.
set -uo pipefail

# ---- where readings go ---------------------------------------------------------------
# Through the harness when it is here, so the cockpit reads what this writes from one agreed
# path; a plain state directory otherwise, because this must work on a box with no harness.
STATE=""
if [ -r "$HOME/.config/spira/harness" ]; then
    _h="$(cat "$HOME/.config/spira/harness" 2>/dev/null)"
    if [ -r "$_h/conf.sh" ]; then
        # shellcheck disable=SC1090
        . "$_h/conf.sh" >/dev/null 2>&1 && STATE="${SPIRA_RUN:-}/accounts"
    fi
fi
[ -n "$STATE" ] || STATE="${XDG_STATE_HOME:-$HOME/.local/state}/spira/accounts"

ACCOUNT="" CONFIG_DIR="" EVERY=300 SAMPLE=1 READ_ONLY=0
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --account)    ACCOUNT="${2:-}"; shift 2 ;;
        --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
        --every)      EVERY="${2:-300}"; shift 2 ;;
        --no-sample)  SAMPLE=0; shift ;;
        --read)       READ_ONLY=1; shift ;;
        -h|--help)    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)           shift; ARGS=("$@"); break ;;
        *)            ARGS+=("$1"); shift ;;
    esac
done

CONFIG_DIR="${CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
[ -d "$CONFIG_DIR" ] || { printf 'conv.sh: no such config dir: %s\n' "$CONFIG_DIR" >&2; exit 1; }

# ---- who this account actually is ------------------------------------------------------
# IDENTITY IS READ, NEVER ASSUMED FROM THE DIRECTORY NAME. `~/.claude` held a Pro account and
# then a Max 5x account within four hours on 2026-09-09, and a stale pause written under the
# first froze the harness under the second — twice. A reading labelled by directory would
# have recorded both under one name and made that invisible. The email and the tier come out
# of the credential store itself, so a reading always says which account it is really about.
identity() {
    python3 - "$CONFIG_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
email = tier = sub = ""
try:
    with open(os.path.join(d, ".credentials.json")) as fh:
        o = json.load(fh).get("claudeAiOauth", {})
    tier, sub = o.get("rateLimitTier", ""), o.get("subscriptionType", "")
except Exception:
    pass
# IDENTITY COMES FROM THIS DIRECTORY AND NOWHERE ELSE. A custom config dir keeps its
# .claude.json inside itself; only the DEFAULT dir keeps it at ~/.claude.json, one level
# up. Trying both in order looks harmless and is not: an unauthenticated directory then
# inherits the default account's email and files its readings under another account's
# name — the exact misattribution this instrument exists to prevent. Caught on the first
# failure-path test, where a fresh mktemp dir reported itself as the live account.
home_default = os.path.realpath(os.path.expanduser("~/.claude"))
p = os.path.expanduser("~/.claude.json") if os.path.realpath(d) == home_default \
    else os.path.join(d, ".claude.json")
try:
    with open(p) as fh:
        email = (json.load(fh).get("oauthAccount") or {}).get("emailAddress", "")
except Exception:
    pass
print("\t".join((email, sub, tier)))
PY
}
IFS=$'\t' read -r EMAIL SUBSCRIPTION TIER <<< "$(identity)"
[ -n "$ACCOUNT" ] || ACCOUNT="${EMAIL:-$(basename "$CONFIG_DIR")}"
SAFE="$(printf '%s' "$ACCOUNT" | tr -c 'A-Za-z0-9_.@-' '_')"
OUT="$STATE/$SAFE.json"

# ---- one reading -----------------------------------------------------------------------
# THE SMALLEST MODEL, DELIBERATELY: this call exists to be answered, not to think. Haiku
# keeps the observer effect at a few hundred tokens of the window being observed.
#
# A FAILED PROBE WRITES NOTHING. It must never be able to report an account as empty, because
# 0% is the best possible news and a broken instrument must not be able to deliver it
# (law-absence-needs-a-positive-control). The previous file stays, and its timestamp ages —
# which is how a reader learns the reading is stale instead of learning a lie.
reading() {
    local raw rc
    raw="$(CLAUDE_CONFIG_DIR="$CONFIG_DIR" timeout 90 claude -p "hi" \
             --output-format stream-json --verbose \
             --model claude-haiku-4-5-20251001 2>/dev/null)"; rc=$?
    [ $rc -eq 0 ] && [ -n "$raw" ] || return 1
    # THE PROGRAM ARRIVES ON FD 3, NOT ON STDIN, because stdin is the trace. `python3 -
    # <<PY` looks right and silently reads the HEREDOC as the program while DISCARDING the
    # pipe, so the parser sees no data and reports "no rate-limit event" about every trace
    # ever handed to it. lib.sh carries this exact scar in capacity_reset_at; this function
    # rediscovered it on its first run.
    printf '%s' "$raw" | python3 /dev/fd/3 "$ACCOUNT" "$EMAIL" "$SUBSCRIPTION" "$TIER" "$CONFIG_DIR" 3<<'PY'
import json, sys, time
acct, email, sub, tier, cdir = sys.argv[1:6]
five = seven = None
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") != "rate_limit_event":
        continue
    w = (d.get("rate_limit_info") or {}).get("unifiedWindows") or {}
    # Structure, never substring: the payload also carries a top-level `resetsAt` for
    # whichever window is nearest, and reading THAT as the five-hour figure is how one
    # window's number ends up printed under the other one's label.
    five = w.get("five_hour") or five
    seven = w.get("seven_day") or seven
if not five and not seven:
    raise SystemExit(1)
def pct(x):
    try:
        return round(float(x.get("utilization", 0)) * 100)
    except Exception:
        return None
out = {
    "account": acct, "email": email, "subscription": sub, "tier": tier,
    "config_dir": cdir, "read_at": int(time.time()), "source": "conv.sh",
    "five_hour":  {"pct": pct(five or {}),  "resets_at": (five or {}).get("resetsAt")},
    "seven_day":  {"pct": pct(seven or {}), "resets_at": (seven or {}).get("resetsAt")},
}
print(json.dumps(out))
PY
}

# WRITTEN BESIDE AND MOVED. The cockpit reads this file on a repaint timer; a reader that
# catches a half-written file gets a parse error where it expected a number, and the pane
# would render that as unknown at exactly the moment the number changed.
write_reading() {
    local json="$1" tmp
    mkdir -p "$STATE" 2>/dev/null || return 1
    tmp="$(mktemp "$OUT.XXXXXX")" || return 1
    printf '%s\n' "$json" > "$tmp" && mv -f "$tmp" "$OUT" || { rm -f "$tmp"; return 1; }
}

say_reading() {
    printf '%s' "$1" | python3 -c '
import json, sys, time
d = json.load(sys.stdin)
def fmt(w, label):
    p, r = w.get("pct"), w.get("resets_at")
    if p is None:
        return "%s ?" % label
    left = ""
    if r:
        m = int((r - time.time()) // 60)
        left = " (resets %dh%02dm)" % (m // 60, m % 60) if m > 0 else " (resetting)"
    return "%s %d%%%s" % (label, p, left)
print("  %s  %s   %s   %s" % (d.get("account", "?"), d.get("tier", "?"),
                              fmt(d.get("five_hour", {}), "5h"),
                              fmt(d.get("seven_day", {}), "7d")))'
}

take() {  # take [--quiet]
    local j
    if j="$(reading)"; then
        write_reading "$j"
        [ "${1:-}" = --quiet ] || say_reading "$j"
        return 0
    fi
    [ "${1:-}" = --quiet ] || printf '  %s  reading unavailable — previous reading left in place\n' "$ACCOUNT" >&2
    return 1
}

if [ "$READ_ONLY" = 1 ]; then
    take; exit $?
fi

# ---- before ----------------------------------------------------------------------------
if [ "$SAMPLE" = 1 ]; then take || true; fi

# ---- during ----------------------------------------------------------------------------
# ADDRESSED BY PID, NEVER BY PATTERN. `pkill -f conv.sh` would match this very script's own
# command line and kill the session it is wrapping; that scar is already in the operating
# manual and it is cheaper to honour it than to rediscover it.
SAMPLER=""
if [ "$SAMPLE" = 1 ] && [ "${EVERY:-0}" -gt 0 ] 2>/dev/null; then
    ( while :; do sleep "$EVERY"; take --quiet || true; done ) >/dev/null 2>&1 &
    SAMPLER=$!
fi
cleanup() {
    [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null
    [ -n "$SAMPLER" ] && wait "$SAMPLER" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

# ---- the session ------------------------------------------------------------------------
# EXEC-LIKE PASSTHROUGH, but not a literal exec: the after-reading has to happen, and exec
# would replace this process before it could. The exit code is carried out by hand instead,
# because a wrapper that eats a non-zero status makes every script above it wrong.
CLAUDE_CONFIG_DIR="$CONFIG_DIR" claude "${ARGS[@]}"
RC=$?

# ---- after -------------------------------------------------------------------------------
cleanup; trap - EXIT INT TERM
if [ "$SAMPLE" = 1 ]; then
    printf '\n'
    take || true
    printf '  readings: %s\n' "$OUT"
fi
exit $RC
