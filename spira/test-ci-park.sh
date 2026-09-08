#!/usr/bin/env bash
#
# test-ci-park.sh — a park is only a park where a run can end it.
#
#   ./test-ci-park.sh
#
# THE FAILURE THIS SUITE EXISTS FOR. `$SPIRA_CI_LABEL` means "parked on a run somebody else
# is watching". It is excluded from every persona's predicate AND from the stalled-work
# report, which is the point of it — parked work must not look abandoned — and is exactly
# what makes a park nothing can end strictly worse than a stall: not claimable, not
# reported, and rendered to the operator as "in CI", the one description that stops anybody
# looking for the real cause. One bead reached 22 reclaims that way, not one of them a work
# failure, while the board said it was in CI and the repository it named opens no pull
# requests at all.
#
# Only `pr` mode opens one. `push` merges the branch itself and `hold` leaves it for a
# human, so for both of those the landing gate IS the gate and there is nothing further to
# wait for. Two ways to get it wrong, and the harness closes both: parking such a bead at
# all, and leaving a park standing when the bead MOVED repository afterwards — which no
# check made at the moment of parking could have seen.
#
# WHY EVERY CASE HERE IS A PAIR. Each of these mechanisms fails by doing nothing, and doing
# nothing is what a healthy pipeline also looks like: a sweep whose classifier answered
# `no-ci` to everything would strip every park and pass a suite that only ever asserted
# "the label is gone", and one that answered `watch` to everything would pass a suite that
# only asserted "a real park survives". So the same input is driven both ways round wherever
# a verdict is asserted (law-absence-needs-a-positive-control).
#
# THE DEADLINE IS PINNED TO A NON-DEFAULT, 600 rather than the shipped 5400. Asserting
# against the shipped value passes just as well if the number is written into the code,
# which is the thing the configuration key exists to stop.
#
# covers: spira/lib.sh spira/sentinel.sh spira/cockpit.sh spira/aeon.sh spira/strand.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

BASE_PATH="$PATH"
TMP="$(mktemp -d)"
mkdir -p "$TMP/home"

# ======================================================================================
# spira_ci_park_state — the whole rule, as a decision table.
#
# Pure: no database, no network, no writes. That is what lets the sweep and the ops pane
# share ONE answer rather than two that can disagree, and it is what lets every branch of
# it be driven here directly instead of inferred from a pass's output.
#
# AN EXPLICIT, MINIMAL ENVIRONMENT. `env -i` with SPIRA_CONF aimed at a file that is not
# there, because a suite that inherits the operator's real spira.conf is asserting about one
# box: this deadline, this repo-map, this set of repositories. Ambient configuration decides
# verdicts silently (law-gates-run-in-a-clean-environment).
# ======================================================================================
MAP="$TMP/repo-map"
cat > "$MAP" <<MAP
# name | path | land | base | format | gate
alpha | $TMP/alpha | pr   | origin/main | |
beta  | $TMP/beta  | push | origin/main | |
gamma | $TMP/gamma | hold | origin/main | |
MAP

# park <repo> <updated-at> [max] -> "<state> <rc>", both halves, because the rc is half the
# contract: `watch` returned with rc 2 means "could not age this", and a caller that reads
# only the word treats an unreadable clock as a healthy park.
park() {
    env -i PATH="$BASE_PATH" HOME="$TMP/home" LC_ALL=C.UTF-8 \
        SPIRA_CONF="$TMP/no.conf" SPIRA_HOME="$TMP/home" SPIRA_REPO="$TMP/home" \
        SPIRA_RUN="$TMP/home/run" SPIRA_DB="$TMP/home/nodb" \
        SPIRA_REPO_MAP="$MAP" SPIRA_CI_PARK_MAX="${3-600}" \
        bash -c '. "$0"; spira_ci_park_state "$1" "$2"; printf " %s" "$?"' \
        "$HERE/lib.sh" "$1" "$2"
}
ago() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

echo "spira_ci_park_state:"

# THE PAIR THAT MAKES EVERY OTHER ASSERTION MEAN SOMETHING: one repository, one deadline,
# two ages, two different answers. A classifier stuck on either verdict fails here.
is "a fresh park in a pr repo is watched"       "watch 0"   "$(park alpha "$(ago 60)")"
is "the same park past the deadline is expired" "expired 0" "$(park alpha "$(ago 900)")"

# NO RUN EXISTS AND NONE WILL. The age is identical to the expired case above, so what is
# being read here is the land mode and nothing else.
is "a push repo has no run to wait for"    "no-ci 0" "$(park beta  "$(ago 900)")"
is "nor does a hold repo"                  "no-ci 0" "$(park gamma "$(ago 900)")"
# And a fresh one, so `no-ci` is not the deadline arriving by another name.
is "a push repo has none when fresh either" "no-ci 0" "$(park beta "$(ago 60)")"

# AN UNMAPPED REPOSITORY ANSWERS HERE TOO, AND SHOULD. A repository the map cannot resolve
# cannot land through a pull request this harness knows how to watch, so a park on it is
# waiting for something nothing will ever report. This is also the bead that MOVED
# repository while parked — the case no check made at the moment of parking could see.
is "an unmapped repo has no run to wait for" "no-ci 0" "$(park nowhere "$(ago 60)")"
is "and neither does a nameless one"         "no-ci 0" "$(park "" "$(ago 60)")"

# THE EMPTY TIMESTAMP. `date -d ""` does not fail — it answers midnight today — so a park
# with no updated_at at all would age itself against a clock the caller never supplied and
# expire silently on a field that was never there. The hazard is asserted directly, so the
# guard below is a rule somebody can see fire rather than a line nobody can account for.
hz="$(date -u -d "" +%s 2>/dev/null)"; hz_rc=$?
is "the empty date is accepted by date(1)"  0 "$hz_rc"
is "and answers midnight today"             "$(date -u -d "$(date -u +%Y-%m-%d)" +%s)" "$hz"
# So the guard must refuse it BEFORE date sees it, and reach the caller as "could not age
# this" — rc 2 — never as a verdict.
is "an absent timestamp is refused, not aged" "watch 2" "$(park alpha "")"
is "and so is one that cannot be parsed"      "watch 2" "$(park alpha "the day before")"
# A repository with no run to wait for is decided before the clock is consulted at all, so
# an unreadable timestamp cannot turn a no-ci verdict into a park.
is "an unreadable clock does not save a push park" "no-ci 0" "$(park beta "")"

# THE DEADLINE IS A KEY, AND ZERO DISABLES IT DELIBERATELY. The pair is the point: the same
# ancient park reads expired at 600 and watch at 0, so this cannot pass against a deadline
# that was never applied.
is "zero disables the deadline"       "watch 0"   "$(park alpha "$(ago 900)" 0)"
is "and 600 is what expired it"       "expired 0" "$(park alpha "$(ago 900)" 600)"

# A DEADLINE THAT IS NOT A NUMBER FALLS BACK TO THE SHIPPED ONE, and must not reach `[ -gt ]`
# as a word — that is a shell error, and an errored classifier is a park left standing with
# no reason recorded anywhere. Both sides of the fallback are asserted, so "fell back" cannot
# be satisfied by disabling the deadline.
is "a non-numeric deadline still watches inside 5400" "watch 0"   "$(park alpha "$(ago 900)"  soon)"
is "and still expires outside it"                     "expired 0" "$(park alpha "$(ago 10800)" soon)"


# ======================================================================================
# THE SWEEP, against a real bd and the real sentinel.
#
# What the classifier decides is only half of it; the other half is that the sweep ACTS on
# both verdicts at the TOP of its loop, above every `continue`. That ordering is the fix.
# Everything below it asks `gh` a question, and every one of those questions can give up
# quietly — an unmapped repository, a path that is not a checkout, a pull request that does
# not exist — and each of those exits used to leave the label standing. So the push and hold
# repositories here are deliberately given paths that are NOT checkouts, and `gh` is stubbed
# to fail outright: if the verdict moved back below the `continue`s, every case below would
# go green on the classifier and red here, which is exactly the seam that broke.
#
# A REAL bd, because what is asserted is what a label sweep does to a database — a stub
# would be a second implementation of the one thing in question (law-prefer-the-real-dependency).
# ======================================================================================
# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-ci-park
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up cipark || { echo "test-ci-park: could not build a fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

SH="$TMP/spira"; RUN="$TMP/run"; ALPHA="$TMP/alpha"
mkdir -p "$SH/chamber" "$RUN/worktree"
cp "$HERE/sentinel.sh" "$HERE/lib.sh" "$HERE/landing.sh" "$HERE/conf.sh" "$SH/"
# `alpha` is a real checkout so the pr path can be reached at all; `beta` and `gamma` are
# the paths the map already names and nothing created them. That absence is the assertion.
git init -q -b main "$ALPHA"
git -C "$ALPHA" commit -q --allow-empty -m base

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub pilgrimage.sh 'exit 0'
stub strand.sh     'exit 0'
stub sending.sh    'exit 0'
stub governor.sh   'exit 0'
stub gate.sh       'exit 0'
stub reflect.sh    'exit 0'
stub ask.sh        'printf "%s\n" "$*" >> "${ASK_LOG:-/dev/null}"; exit 0'
export ASK_LOG="$TMP/ask.log"; : > "$ASK_LOG"
# THE PULL-REQUEST PROBE IS THE SEAM, injected through SPIRA_GH rather than by PATH: conf.sh
# replaces $PATH, so a shim placed there would be stepped over and the real `gh` would answer
# from the operator's account. GH_STATE empty means the probe fails, which is the state every
# repository with no pull request is actually in.
GH="$TMP/bin/gh"; mkdir -p "$TMP/bin"
cat > "$GH" <<'GH'
#!/usr/bin/env bash
[ -n "${GH_STATE:-}" ] || exit 1
printf '%s\n' "$GH_STATE"
GH
chmod +x "$GH"
grep -q 'SPIRA_GH' "$HERE/lib.sh" \
    || { echo "test-ci-park: lib.sh has no SPIRA_GH injection point — refusing to run the real gh" >&2; exit 1; }

printf 'FAYTH_NAME=t\nFAYTH_LABELS="spira,plan"\nFAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL,$SPIRA_CI_LABEL"\nFAYTH_MAX_CONCURRENT=0\n' \
    > "$SH/chamber/t.fayth"

B() { bd -C "$SPIRA_DB" "$@"; }
labels_of() { B show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(" ".join(d[0].get("labels") or []))' 2>/dev/null; }
parked() { case " $(labels_of "$1") " in *" awaiting-ci "*) echo parked ;; *) echo unparked ;; esac; }
# THE NOTE IS RE-WRAPPED BY `bd show`, so it is squeezed before it is matched. Asserting
# against the raw output would make every phrase here hostage to a terminal width.
notes()  { B show "$1" 2>/dev/null | tr -s '[:space:]' ' '; }

sweep() {   # sweep [max] -> one sentinel pass under the fixture
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$ALPHA" \
    SPIRA_REPO_MAP="$MAP" SPIRA_CI_PARK_MAX="${1-600}" SPIRA_CI_LABEL=awaiting-ci \
    SPIRA_GOAL=sp-goal SPIRA_FAYTHS=t SPIRA_INFERENCE_EVERY=999999 \
    SPIRA_NOTIFY="$SH/ask.sh" SPIRA_GH="$GH" GH_STATE="${GH_STATE:-}" \
    SPIRA_LAUNCH="/bin/true" SPIRA_SYSTEMCTL="/bin/true" \
        bash "$SH/sentinel.sh" 2>&1
}
seed_parks() {
    testdb_reset
    testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":["spira","plan"]}
{"id":"sp-pk-push","title":"parked in a push repo","status":"open","issue_type":"task","labels":["spira","plan","repo:beta","awaiting-ci"]}
{"id":"sp-pk-hold","title":"parked in a hold repo","status":"open","issue_type":"task","labels":["spira","plan","repo:gamma","awaiting-ci"]}
{"id":"sp-pk-gone","title":"parked in an unmapped repo","status":"open","issue_type":"task","labels":["spira","plan","repo:nowhere","awaiting-ci"]}
{"id":"sp-pk-live","title":"parked on a real run","status":"open","issue_type":"task","labels":["spira","plan","repo:alpha","awaiting-ci"]}
JSONL
}

echo
echo "the sweep (real bd, real sentinel):"

GH_STATE="OPEN MERGEABLE PENDING"
seed_parks
# THE POSITIVE CONTROL COMES FIRST. Every assertion after this one says "the label is gone";
# read alone they would all pass against a sweep that stripped every park it saw, which is
# the same defect wearing the other face — an aeon summoned for work that is genuinely in CI.
out="$(sweep 600)"
is "a live pr park survives the sweep"        parked   "$(parked sp-pk-live)"
is "a push repo's park is stripped"           unparked "$(parked sp-pk-push)"
is "a hold repo's park is stripped"           unparked "$(parked sp-pk-hold)"
is "an unmapped repo's park is stripped"      unparked "$(parked sp-pk-gone)"
# THE BEAD CARRIES ITS OWN REASON. A label that vanishes with nothing recorded is
# indistinguishable from one an operator removed by hand, and the next reader has no way to
# tell which — nor what the harness thinks the repository does instead of opening a run.
want "and says why, on the bead"  "nothing opens a pull request" "$(notes sp-pk-push)"
want "naming the land mode"       "lands by push"   "$(notes sp-pk-push)"
want "and the pass says so too"   "sp-pk-push: unparked" "$out"
nowant "while the live park is not mentioned" "sp-pk-live: unparked" "$out"

# THE ORDERING, STATED AS ITS OWN CASE. `beta` names a path that does not exist and `gh` is
# refusing every call, so this passes only while the no-ci verdict is taken above the
# `continue`s that give up on both.
is "the checkout need not exist for the strip" unparked "$(parked sp-pk-push)"
GH_STATE=""
seed_parks
sweep 600 >/dev/null
is "and neither need gh answer at all"         unparked "$(parked sp-pk-push)"
is "while a pr park gh cannot answer for is left alone" parked "$(parked sp-pk-live)"

# A PARK THAT OUTLIVED THE LONGEST PLAUSIBLE RUN is not parked, it is lost, and the label is
# the one thing keeping it out of the report that would have found it. Zero and one second
# are the pair: the same bead, the same instant, the deadline the only thing that moved.
GH_STATE="OPEN MERGEABLE PENDING"
seed_parks
sweep 0 >/dev/null
is "a park survives a disabled deadline"   parked "$(parked sp-pk-live)"
out="$(sweep 1)"
is "and is stripped once it outlives one"  unparked "$(parked sp-pk-live)"
want "the bead names the deadline that ended it" "SPIRA_CI_PARK_MAX" "$(notes sp-pk-live)"
want "and the pass says which bead"              "sp-pk-live: unparked" "$out"

# NOT `--status open`. A parked bead may still be in_progress: the aeon that applied the
# label has not necessarily exited yet. Filtering on open alone reported zero parked beads
# while one sat labelled and plainly visible in `bd show`.
GH_STATE="OPEN MERGEABLE PENDING"
seed_parks
B update sp-pk-push --claim >/dev/null 2>&1
is "the bead is held"                       in_progress \
   "$(B show sp-pk-push --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(d[0].get("status") or "")' 2>/dev/null)"
sweep 600 >/dev/null
is "an in_progress park is swept as well"   unparked "$(parked sp-pk-push)"

# AND A CLOSED BEAD IS NOT. Its park cannot strand anything, and rewriting closed beads every
# two minutes is a write the pass has no reason to make.
seed_parks
B close sp-pk-push --reason done >/dev/null 2>&1
sweep 600 >/dev/null
is "a closed bead's park is left where it is" parked "$(parked sp-pk-push)"

# ======================================================================================
# RED CI RESULT. When a PR's CI comes back red, the bead must be claimable again —
# that is what the sweep is FOR — but its priority must be left alone. Priority
# expresses how much the work MATTERS; CI failure expresses how loudly it is FAILING.
# Those are unrelated. A trivial bead that fails repeatedly must not outrank genuine
# high-priority work just because it is noisy.
#
# THE PAIR. A P2 bead; CI red. Assert the park is stripped AND the priority is
# unchanged. Without the priority half, a sweep that still promoted to P0 would pass
# on the unparked assertion alone. Without the unparked half, the priority assertion
# would pass against a sweep that simply did nothing at all
# (law-absence-needs-a-positive-control).
# ======================================================================================
echo
echo "CI red — bead returns at its own priority:"

priority_of() {
    B show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]
p=d[0].get("priority"); print(p if p is not None else "")' 2>/dev/null
}

GH_STATE="OPEN MERGEABLE FAILURE"
testdb_reset
testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":["spira","plan"]}
{"id":"sp-pk-red","title":"parked on a red run","status":"open","issue_type":"task","priority":2,"labels":["spira","plan","repo:alpha","awaiting-ci"]}
JSONL
is "the bead starts at P2"             2      "$(priority_of sp-pk-red)"
is "and is parked"                     parked "$(parked sp-pk-red)"
out="$(sweep 600)"
is "a red CI result unparks the bead"  unparked "$(parked sp-pk-red)"
is "and the priority is unchanged at P2" 2     "$(priority_of sp-pk-red)"
want   "the pass mentions the bead"                 "sp-pk-red" "$out"
want   "the bead note records the sweep acted"      "Cleared awaiting-ci" "$(notes sp-pk-red)"
nowant "and the note makes no claim about priority" "P0" "$(notes sp-pk-red)"

# ======================================================================================
# THE OUTCOME STREAM: a red run records an event, a run still in progress is silent.
#
# ci.failed fires inside the FAILURE branch of the state switch and only there. A run still
# in progress is a steady state on a two-minute timer — one event per pass would bury every
# other outcome in the same view, which is the failure the stream was built to prevent.
# ======================================================================================
echo
echo "CI outcome events:"

GH_STATE="OPEN MERGEABLE FAILURE"
seed_parks
: > "$ASK_LOG"
out="$(sweep 600)"
want "a red run hands sp-pk-live back to the queue"  "CI red on sp-pk-live" "$out"
want "and the verdict is recorded as an event"        "--kind ci.failed"    "$(cat "$ASK_LOG")"
want "against the bead that was parked"               "--target sp-pk-live" "$(cat "$ASK_LOG")"

# THE NEGATIVE THAT MATTERS MOST: a run still going is a steady state, and a steady state on
# a two-minute timer is what buries every other outcome in the same view.
GH_STATE="OPEN MERGEABLE PENDING"
seed_parks
: > "$ASK_LOG"
out="$(sweep 600)"
nowant "a run still in progress says nothing about sp-pk-live" "sp-pk-live" "$out"
is     "and emits no event for it"                             ""            "$(cat "$ASK_LOG")"


# ======================================================================================
# THE BRIEF, generated per land mode.
#
# The sweep is the mechanism and this is what stops it having to fire. They exist together
# because they fail differently: prose alone is a resolution, and a sweep alone means every
# push-mode bead is parked and unparked once per lifetime, which reads to anybody watching
# the pane as a harness arguing with itself.
#
# Driven through the REAL aeon.sh with a shim standing where the model would be, capturing
# the prompt it was actually handed. A structural grep over aeon.sh would assert that both
# branches are written; only running it asserts that the right one is reached, which is the
# half that can break — REPO_LAND comes from the bead's `repo:` label through the map, and a
# lookup that answered nothing would silently give every aeon the `push` brief.
# ======================================================================================
echo
echo "the brief an aeon is handed:"

AH="$TMP/aeonhome"; mkdir -p "$AH/chamber"
cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/aeon.sh" "$AH/"
cp -r "$HERE/actors" "$AH/" 2>/dev/null || true
AORIGIN="$TMP/aorigin.git"; git init -q --bare -b main "$AORIGIN"
AREPO="$TMP/arepo"; git clone -q "$AORIGIN" "$AREPO" 2>/dev/null
git -C "$AREPO" config user.email t@t; git -C "$AREPO" config user.name t
printf 'seed\n' > "$AREPO/f"
git -C "$AREPO" add f; git -C "$AREPO" commit -qm seed; git -C "$AREPO" push -q origin main 2>/dev/null
printf 'FAYTH_NAME=builder\nFAYTH_LABELS="spira,plan"\nFAYTH_EXCLUDE_LABELS="spira-poison"\nFAYTH_MAX_CONCURRENT=1\nFAYTH_HEARTBEAT_SECONDS=600\n' \
    > "$AH/chamber/builder.fayth"
printf 'work {{BEAD_ID}} in {{REPO}} on {{BRANCH}}\n{{PARK}}\n' > "$AH/chamber/builder.md"

ABIN="$TMP/abin"; mkdir -p "$ABIN"
grep -q 'SPIRA_CLAUDE' "$HERE/aeon.sh" \
    || { echo "test-ci-park: aeon.sh has no SPIRA_CLAUDE injection point — refusing to run the real model" >&2; exit 1; }
cat > "$ABIN/claude" <<'SHIM'
#!/usr/bin/env bash
cat /dev/stdin > "$PROMPT_OUT"
printf '{"type":"result","subtype":"success","is_error":false,"result":"read","num_turns":1}\n'
SHIM
chmod +x "$ABIN/claude"

brief_for() {   # brief_for <land> -> the PARK section of the brief an aeon was handed
    local land="$1" map="$TMP/aeon-map-$1"
    printf 'arepo | %s | %s | origin/main | |\n' "$AREPO" "$land" > "$map"
    testdb_reset
    printf '{"id":"sp-br-1","title":"t","status":"open","issue_type":"task","labels":["spira","plan","repo:arepo"],"updated_at":"2026-09-04T00:00:00Z"}\n' \
        | testdb_seed
    rm -rf "$TMP/arun"; mkdir -p "$TMP/arun"
    : > "$TMP/prompt"
    SPIRA_HOME="$AH" SPIRA_RUN="$TMP/arun" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$AREPO" \
    SPIRA_REPO_MAP="$map" SPIRA_CI_PARK_MAX=600 \
    SPIRA_CLAUDE="$ABIN/claude" PROMPT_OUT="$TMP/prompt" \
        "$AH/aeon.sh" builder >/dev/null 2>&1
    cat "$TMP/prompt"
}

# A repository that DOES open pull requests: the aeon is told to park, and told what ends the
# park. Without this pair, every assertion below would pass against a harness that had simply
# stopped mentioning CI to anyone.
pr_brief="$(brief_for pr)"
want "the prompt was rendered at all"        "work sp-br-1"          "$pr_brief"
nowant "with no placeholder left standing"   "{{PARK}}"              "$pr_brief"
# THE BULLET, not the bare phrase. The push brief says "do NOT label the bead
# \`awaiting-ci\`", which contains the phrase — a looser match here would be satisfied by the
# instruction's own negation and the pair below would assert nothing.
want "a pr repo's aeon is told to park"      "- label the bead \`awaiting-ci\`" "$pr_brief"
want "and told the park has a deadline"      "SPIRA_CI_PARK_MAX"     "$pr_brief"
want "rendered as the configured number"     "(600s)"                "$pr_brief"

# And the other side: the same aeon, the same bead, one column of the map different.
push_brief="$(brief_for push)"
want "a push repo's aeon is told there is no run" "no CI run to wait for" "$push_brief"
want "and told not to apply the label"            "do not label the bead" "$push_brief"
want "naming the land mode it read"               "lands by \`push\`"     "$push_brief"
nowant "and is never told to park"                "- label the bead \`awaiting-ci\`" "$push_brief"

# `hold` is the third mode and it takes the same side of the branch. It is asserted because
# the condition is `= pr`, not `!= push`, and those differ on exactly this value.
hold_brief="$(brief_for hold)"
want "a hold repo's aeon is told the same"  "do not label the bead" "$hold_brief"
want "naming its own land mode"             "lands by \`hold\`"     "$hold_brief"

# ======================================================================================
# THE OPS PANE. Waiting on a run is routine; parked with no run to wait for is a fault, and
# for as long as one line said both, the pane rendered the fault as the routine case under
# the word "CI" — which is the description that stops anybody looking.
#
# It reads spira_ci_park_state, the SAME function the sweep acts on, so the pane cannot
# disagree with the harness about what is parked on nothing.
# ======================================================================================
echo
echo "the ops pane:"

CRUN="$TMP/crun"; mkdir -p "$CRUN"
cp "$HERE/cockpit.sh" "$HERE/cockpit-metrics.py" "$SH/" 2>/dev/null || true
snapshot() {   # snapshot [max] -> the CI keys of one collector pass
    SPIRA_HOME="$SH" SPIRA_RUN="$CRUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$ALPHA" \
    SPIRA_REPO_MAP="$MAP" SPIRA_CI_PARK_MAX="${1-600}" SPIRA_GOAL=sp-goal SPIRA_FAYTHS=t \
    SPIRA_COCKPIT_FORCE=1 \
        bash "$SH/cockpit.sh" once >/dev/null 2>&1
    grep '^SP_AWAITING' "$CRUN/cockpit.env" 2>/dev/null
}
key() { sed -n "s/^$1='\(.*\)'$/\1/p" <<< "$2"; }

# THE ZERO CASE TESTS BOTH COUNTS. Testing the watched population alone would render
# "nothing parked on CI" over a queue of parks nothing can end — the exact reading this
# section exists to stop.
testdb_reset
printf '{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":["spira","plan"]}\n' | testdb_seed
snap="$(snapshot 600)"
is "with nothing parked, nothing is watched" 0 "$(key SP_AWAITING_N "$snap")"
is "and nothing is stuck"                    0 "$(key SP_AWAITING_STUCK "$snap")"

seed_parks
snap="$(snapshot 600)"
# One alpha park inside its deadline; three that no run will ever end.
is "the watched population is counted"       1 "$(key SP_AWAITING_N "$snap")"
is "and the stuck one separately"            3 "$(key SP_AWAITING_STUCK "$snap")"
# THE SUMMARY SAYS HOW MANY; ONLY THE ROW SAYS WHICH. A reader looking at one bead should
# not have to work out which population it fell into.
want "a stuck bead's own row carries its reason" "no run to wait for" "$snap"
nowant "and the watched bead's row does not"     "sp-pk-live no run"  "$snap"
want "the stuck one is named for the summary"    "SP_AWAITING_STUCK_ID='sp-pk-" "$snap"

# The deadline moves beads between the two populations and nothing else does: same database,
# same instant, one key different.
snap="$(snapshot 1)"
is "past the deadline the watched count falls" 0 "$(key SP_AWAITING_N "$snap")"
is "and every park is reported stuck"          4 "$(key SP_AWAITING_STUCK "$snap")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
