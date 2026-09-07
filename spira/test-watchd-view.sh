#!/usr/bin/env bash
#
# test-watchd-view.sh — the health assertion for a view follower, against a real multiplexer.
#
#   ./test-watchd-view.sh
#
# WHAT IT HOLDS. A follower keeps the attention surface pointed at whatever should be visible,
# and it acts on TRANSITIONS — so a follower that has died misses them in silence. A process
# listing, a unit state and an unread count are all identical for a dead one and a healthy idle
# one, which is how one was once found stopped with its state machine perfectly right while a
# review ran its whole length in a window nobody was looking at.
#
#   1. THE ASSERTION COMPARES INTENT AGAINST THE WORLD. The follower says what SHOULD be
#      visible; the multiplexer is asked what IS; DEGRADED is the two disagreeing.
#   2. AND IT DOES SO BY IDENTITY, NOT BY NAME. A window is named for the program running in
#      it, so the wanted window and the shown one can carry the SAME name in both the healthy
#      and the broken case — which is exactly what the original failure looked like. The
#      fixture below names them identically on purpose: an assertion comparing the strings a
#      follower prints passes this suite's negative control, and is useless.
#   3. EVERY WAY OF FAILING TO ANSWER IS DEGRADED OR REFUSED, NEVER OK. A missing multiplexer,
#      an absent session, a follower that prints no `want:` line — none of them PROVED the view
#      is being steered (law-absence-needs-a-positive-control).
#   4. AND THE MANIFEST ACTUALLY WIRES IT. The last block drives the whole thing through
#      `watchd.sh status`, because a correct assertion nothing calls is worth nothing.
#
# AGAINST A REAL MULTIPLEXER, on a private server. TMUX_TMPDIR gives this suite a server of its
# own, so it can neither see nor disturb the operator's — and a model of tmux would reproduce
# the surface remembered rather than the one that exists, which is the failure mode of a stub
# (law-prefer-the-real-dependency).
#
# covers: spira/watchd.sh spira/watchers
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 77; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        got: %s\n' "$1" "$2"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }

TMP="$(mktemp -d)"; mkdir -p "$TMP/home"
export TMUX_TMPDIR="$TMP/sock"; mkdir -p "$TMUX_TMPDIR"
trap 'tmux kill-server >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# A harness tree that is NOT this checkout, so nothing here reads the operator's own config.
CLONE="$TMP/clone"; mkdir -p "$CLONE/spira" "$CLONE/cockpit"
cp "$HERE/conf.sh" "$HERE/watchd.sh" "$CLONE/spira/"
CONF="$TMP/none.conf"

# hv <args...> — the assertion, in a minimal environment. stdout and stderr both captured by
# the caller; the exit code is the verdict.
hv() {
    env -i HOME="$TMP/home" PATH="$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" SPIRA_CONF="$CONF" \
        bash "$CLONE/spira/watchd.sh" health-view "$@"
}

# ---- the fixture: two sessions, both linked into one surface ------------------------------
# This is the follower's own mechanism. A linked window is the SAME window object shown in a
# second session, not a copy, so the two share a window id — which is what makes identity the
# right thing to compare and a name the wrong one.
tmux new-session -d -s home   -c "$TMP" >/dev/null 2>&1
tmux new-session -d -s review -c "$TMP" >/dev/null 2>&1
tmux new-session -d -s surface -c "$TMP" >/dev/null 2>&1
stray="$(tmux display-message -p -t "=surface" '#{window_index}')"
tmux link-window -d -s "=home:0"   -t "=surface:$stray" -a
tmux link-window -d -s "=review:0" -t "=surface:$stray" -a
tmux kill-window -t "=surface:$stray"

# THE NAMES ARE MADE IDENTICAL, DELIBERATELY. Both windows run the same shell, so in the real
# case both were called the same thing and the follower's own report read `showing: <that>`
# whether the right window or the wrong one was up. Anything here that passes by comparing
# printed names is passing on a coincidence.
for w in "=home:0" "=review:0"; do
    tmux set-window-option -t "$w" automatic-rename off >/dev/null 2>&1
    tmux rename-window -t "$w" samename
done

idx_for() {              # idx_for <window-id> -> its index within the surface
    tmux list-windows -t "=surface" -F '#{window_index} #{window_id}' \
        | awk -v w="$1" '$2==w {print $1; exit}'
}
show() {                 # show <session> -> make that session's window the visible one
    tmux select-window -t "=surface:$(idx_for "$(tmux list-windows -t "=$1" -F '#{window_id}' -f '#{==:#{window_index},0}')")"
}

# A stub follower. Its `want:` is whatever is in a file, so the state machine can be moved
# without moving the surface — which is the whole failure being reproduced.
WANT="$TMP/want"
FOLLOWER="$TMP/follower"
cat > "$FOLLOWER" <<EOF
#!/bin/sh
[ "\$1" = status ] || exit 2
echo "review:   ACTIVE"
echo "want:     \$(cat "$WANT")"
echo "surface:  present  (showing: samename)"
EOF
chmod +x "$FOLLOWER"

echo "the view agrees with what the follower wants"
# THE POSITIVE CONTROL. Every DEGRADED below is believable only because this passes: the
# assertion can say OK, so a failure later is about the view and not about the check.
printf 'home\n' > "$WANT"; show home
out="$(hv "$FOLLOWER" surface 2>&1)"; rc=$?
is "an agreeing view is OK"          "0" "$rc"
is "and says nothing"                "" "$out"

echo
echo "and DEGRADES when it does not"
# THE FAILURE THIS EXISTS FOR: the state machine is right — a review is live and the follower
# knows the review window is wanted — and the surface is showing the other one. Nothing else
# about the process is wrong, which is why nothing else can see it.
printf 'review\n' > "$WANT"
out="$(hv "$FOLLOWER" surface 2>&1)"; rc=$?
is "a view that has not followed is not OK" "1" "$rc"
has "and the reason names what was wanted"  "$out" "want: review"
has "and says what the state means"         "$out" "nothing is enacting it"
# AND IT WAS NOT THE NAMES THAT DECIDED. Both windows are called the same thing, so a check
# comparing the strings a follower prints would have called this healthy.
is "the two windows are indistinguishable by name" "samename samename" \
   "$(tmux display-message -p -t '=home:0' '#{window_name}') $(tmux display-message -p -t '=review:0' '#{window_name}')"
# Moving the surface, and nothing else, clears it — so the assertion is measuring the view.
show review
is "and following clears it"         "0" "$(hv "$FOLLOWER" surface >/dev/null 2>&1; echo $?)"

echo
echo "every way of failing to answer is DEGRADED or refused, never OK"
printf 'nosuchsession\n' > "$WANT"
out="$(hv "$FOLLOWER" surface 2>&1)"; rc=$?
is "a wanted session that does not exist"  "1" "$rc"
has "and says which"                       "$out" "no 'nosuchsession' session to show"
printf 'home\n' > "$WANT"
out="$(hv "$FOLLOWER" nosuchsurface 2>&1)"; rc=$?
is "a surface that is not there"           "1" "$rc"
has "and says so"                          "$out" "surface this steers is not there"
# A `want:` line is the whole contract. Without it there is nothing to compare, and the honest
# answer is that this watcher cannot be judged — not that it is well.
printf '#!/bin/sh\necho hello\n' > "$TMP/mute"; chmod +x "$TMP/mute"
out="$(hv "$TMP/mute" surface 2>&1)"; rc=$?
is "a follower that says nothing usable"   "1" "$rc"
has "and the exit code it gave is kept"    "$out" "no 'want:' line (exit 0)"
# A line that is not a session name is refused rather than used as a target: a `status` that
# printed a sentence there would otherwise be spliced into the query.
printf '#!/bin/sh\necho "want:     the review window"\n' > "$TMP/prose"; chmod +x "$TMP/prose"
is "a want: that is not a session name"    "1" "$(hv "$TMP/prose" surface >/dev/null 2>&1; echo $?)"

echo
echo "the check being unable to run is not the same fact as the view being wrong"
# Exit 2, not 1. One of the two is about the watcher and the other is about this assertion, and
# a probe that reported its own breakage as a finding about the watcher would send the next
# reader to the wrong place.
out="$(hv "$TMP/nothing-here" surface 2>&1)"; rc=$?
is "a follower that is not there is refused" "2" "$rc"
has "and says why"                           "$out" "not executable"
is "so are missing arguments"                "2" "$(hv "$FOLLOWER" >/dev/null 2>&1; echo $?)"

echo
echo "and the manifest actually wires it"
# A correct assertion nothing calls is worth nothing, so this drives the whole thing through
# `status` — the one command that runs a health probe — using the harness's own shipped row.
M="$TMP/manifest"
printf '?view|daemon|@SPIRA_VIEW@ watch|@SPIRA_HOME@/watchd.sh health-view @SPIRA_VIEW@ @SPIRA_VIEW_SESSION@\n' > "$M"
st() {
    env -i HOME="$TMP/home" PATH="$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" SPIRA_CONF="$CONF" \
        SPIRA_WATCHERS="$M" SPIRA_VIEW="$FOLLOWER" SPIRA_VIEW_SESSION=surface \
        bash "$CLONE/spira/watchd.sh" status 2>&1
}
printf 'home\n' > "$WANT"; show home
out="$(st)"
is "a followed view renders OK"  "OK" "$(printf '%s\n' "$out" | awk '$1=="view"{print $3}')"
printf 'review\n' > "$WANT"
out="$(st)"
is "and one that is not renders DEGRADED" "DEGRADED" "$(printf '%s\n' "$out" | awk '$1=="view"{print $3}')"
has "with the reason beside it"  "$out" "nothing is enacting it"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
