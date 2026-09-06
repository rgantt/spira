#!/usr/bin/env bash
#
# test-ci-park.sh — a park must end, and the two ways it never did.
#
#   ./test-ci-park.sh
#
# A bead carrying the CI-park label is excluded from every persona's predicate AND from the
# stranded-work report. That is the point of it — parked work must not look abandoned — and it
# is also what makes a park that nothing will ever end strictly worse than a stall: not
# claimable, not reported, and rendered as "in CI", which is the one description that stops
# anybody looking for the real cause. A bead reached 22 reclaims in that state, not one of them
# a work failure.
#
# Two ways a park becomes a lie, and both are under test:
#
#   no-ci     the repository does not land through pull requests, so no run exists to end it.
#             Includes the case no check made at parking time could catch — a bead that MOVED
#             repository while parked — and an unmapped repository, which cannot land at all.
#   expired   a park that has outlived the longest plausible run is not parked, it is lost.
#
# THE NEGATIVE CASES CARRY THE SUITE. A sweep that stripped every park would satisfy every
# positive assertion here and destroy the mechanism, so each of them is paired: a `pr` park
# inside the deadline must still be holding its label after a full pass, and a closed bead's
# park must be left alone. The positive control comes first — the matcher is shown finding an
# offender before its silence on a clean case is believed (law-absence-needs-a-positive-control).
#
# THE LABEL IS PINNED TO A NON-DEFAULT VALUE THROUGHOUT. Asserting against the shipped
# `awaiting-ci` would pass just as well if the sweep had the literal written in, which is the
# thing SPIRA_CI_LABEL exists to stop.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

TMP="$(mktemp -d)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The park label, pinned away from the default for the whole suite.
CI_LABEL=parked-on-a-run
export SPIRA_CI_LABEL="$CI_LABEL"

echo "test-ci-park.sh"
echo
echo "spira_ci_park_state — the decision, with no database and no network"

# Six columns, always: a row written in an older, narrower form reads its gate as a formatter.
mkdir -p "$TMP/pr" "$TMP/push" "$TMP/hold"
cat > "$TMP/repo-map" <<MAP
reviewed  | $TMP/pr   | pr   | origin/main   | |
direct    | $TMP/push | push | origin/main   | |
manual    | $TMP/hold | hold | origin/master | |
blank     | $TMP/push |      | origin/main   | |
MAP

# An explicit, minimal environment: a suite that inherits a real spira.conf is asserting
# against one box (law-gates-run-in-a-clean-environment).
state() {   # state <repo-name> <updated-at> -> "<verdict> rc=<n>"
    local out rc
    out="$(env -i HOME="$TMP" PATH="$PATH" TZ=UTC \
              SPIRA_REPO_MAP="$TMP/repo-map" SPIRA_CI_LABEL="$CI_LABEL" \
              SPIRA_CI_PARK_MAX="${MAX:-5400}" \
              bash -c ". '$HERE/conf.sh'; . '$HERE/lib.sh'; spira_ci_park_state \"\$1\" \"\$2\"; printf ' rc=%s' \$?" \
              _ "$1" "$2" 2>/dev/null)"
    printf '%s' "$out"
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

# THE POSITIVE CONTROL FIRST. Every `no-ci` assertion below is a claim that the matcher said
# something; this is the proof it can also stay silent, so silence means something.
is "a pull-request repo inside the deadline is watched" "watch rc=0"   "$(state reviewed "$NOW")"
is "a push repo has no run to wait for"                 "no-ci rc=0"   "$(state direct   "$NOW")"
is "nor does a hold repo — no PR is opened for one"     "no-ci rc=0"   "$(state manual   "$NOW")"
# An empty land column defaults to push, so it must answer like one rather than fall through.
is "an unset land mode answers as push"                 "no-ci rc=0"   "$(state blank    "$NOW")"
# An unmapped repository cannot land at all, so a park on it waits for something with no
# mechanism behind it. This is also the shape of a bead that MOVED repository while parked.
is "an unmapped repository is not something to wait on" "no-ci rc=0"   "$(state elsewhere "$NOW")"
is "a park past the deadline is expired, not parked"    "expired rc=0" "$(state reviewed "$OLD")"

# The deadline is a configured value, and this proves the code reads it rather than a literal.
is "the deadline is read from SPIRA_CI_PARK_MAX" "watch rc=0"   "$(MAX=86400 state reviewed "$OLD")"
is "and 0 disables it, deliberately"             "watch rc=0"   "$(MAX=0     state reviewed "$OLD")"
# A park the clock cannot age is NOT expired. Stripping a label on the strength of a timestamp
# we could not read would summon an aeon for nothing; rc 2 is how the caller is told to say so
# rather than act.
is "an unreadable timestamp reports rc 2, not a verdict" "watch rc=2" "$(state reviewed "not-a-date")"
is "and so does a missing one"                           "watch rc=2" "$(state reviewed "")"

# ======================================================================================
# THE SWEEP, against a real bd on a throwaway fixture. A model of the dependency is a second
# implementation of it, and the two disagreeing is a bug in neither and a failure in both:
# what `bd label remove` does to a bead is bd's to decide.
# ======================================================================================
echo
echo "the sweep — what a full sentinel pass does to each kind of park"

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-ci-park
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up cipark || { echo "test-ci-park: could not build a fixture database"; exit 1; }

REPO="$TMP/repo"; RUN="$TMP/run"; SH="$TMP/spira"
git init -q -b main "$REPO"; git -C "$REPO" commit -q --allow-empty -m base
PRREPO="$TMP/prrepo"
git init -q -b main "$PRREPO"; git -C "$PRREPO" commit -q --allow-empty -m base
mkdir -p "$RUN/worktree" "$SH/chamber"
cp "$HERE/sentinel.sh" "$HERE/lib.sh" "$HERE/landing.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub pilgrimage.sh 'exit 0'
stub strand.sh     'exit 0'
stub sending.sh    'exit 0'
stub gate.sh       'exit 0'
stub reflect.sh    'exit 0'
stub ask.sh        'exit 0'
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/launch";    chmod +x "$TMP/launch"
printf '#!/usr/bin/env bash\necho inactive\n' > "$TMP/systemctl"; chmod +x "$TMP/systemctl"
# THE PULL REQUEST IS STUBBED AS STILL RUNNING, so the `watch` case reaches the end of the
# loop and keeps its label for the RIGHT reason. Left unstubbed, `gh` would fail, the loop
# would `continue`, and the label would survive by accident — a positive control that proves
# nothing is worse than none, because it is believed.
printf '#!/usr/bin/env bash\necho "OPEN MERGEABLE PENDING"\n' > "$TMP/gh"; chmod +x "$TMP/gh"
# Concurrency 0, so no pass here ever reaches systemd-run with a real aeon.
echo 'FAYTH_MAX_CONCURRENT=0' > "$SH/chamber/t.fayth"

cat > "$TMP/map" <<MAP
$(basename "$REPO") | $REPO   | push | origin/main | |
reviewed            | $PRREPO | pr   | origin/main | |
MAP

B() { bd -C "$SPIRA_DB" "$@"; }
labels_of() { B show "$1" --json 2>/dev/null | sed -n '/^[[{]/,$p' | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(",".join(sorted(d[0].get("labels") or [])))'; }
parked() { case ",$(labels_of "$1")," in *",$CI_LABEL,"*) echo yes ;; *) echo no ;; esac; }
notes_of() { B show "$1" 2>/dev/null; }

sentinel() {
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_REPO_MAP="$TMP/map" SPIRA_CI_LABEL="$CI_LABEL" SPIRA_CI_PARK_MAX="${MAX:-5400}" \
    SPIRA_GOAL=sp-goal SPIRA_FAYTHS=t SPIRA_INFERENCE_EVERY=0 SPIRA_NOTIFY="$SH/ask.sh" \
    SPIRA_GH="$TMP/gh" SPIRA_LAUNCH="$TMP/launch" SPIRA_SYSTEMCTL="$TMP/systemctl" \
        bash "$SH/sentinel.sh" 2>&1
}

testdb_reset
testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[]}
{"id":"sp-watch","title":"parked on a real run","status":"open","issue_type":"task","labels":["spira","plan","repo:reviewed","$CI_LABEL","branch:spira/sp-watch"]}
{"id":"sp-nocirun","title":"parked where nothing opens a PR","status":"open","issue_type":"task","labels":["spira","plan","repo:$(basename "$REPO")","$CI_LABEL"]}
{"id":"sp-working","title":"parked and still in progress","status":"in_progress","issue_type":"task","labels":["spira","plan","repo:$(basename "$REPO")","$CI_LABEL"]}
{"id":"sp-lost","title":"parked longer than any run takes","status":"open","issue_type":"task","labels":["spira","plan","repo:reviewed","$CI_LABEL"]}
{"id":"sp-done","title":"closed while parked","status":"closed","issue_type":"task","labels":["spira","plan","repo:$(basename "$REPO")","$CI_LABEL"]}
JSONL
# updated_at is written straight into the store rather than seeded, because an importer is
# entitled to stamp its own — and a fixture whose ages the import quietly reset would test the
# deadline against zero seconds and pass every time.
testdb_sql "$TESTDB_NAME" \
    "update issues set updated_at = timestampadd(HOUR, -3, utc_timestamp()) where id='sp-lost'; \
     call dolt_commit('-A','-m','age the park','--skip-empty');" >/dev/null 2>&1

out="$(sentinel)"

is "a park with a run still going keeps its label"   "yes" "$(parked sp-watch)"
nowant "and the pass says nothing about it"          "sp-watch: unparked" "$out"
is "a park in a repo that opens no PR is stripped"   "no"  "$(parked sp-nocirun)"
want   "and the pass says why"                       "sp-nocirun: unparked — repo:$(basename "$REPO") has no CI to wait for" "$out"
# A SHORT PHRASE, because `bd show` hard-wraps its notes and a longer one would straddle a
# line break and never match however right the note was.
want   "and the bead carries the reason"             "no CI run exists" "$(notes_of sp-nocirun)"
# `--status open` hid this one: an aeon parks and has not necessarily exited, so the bead is
# still in_progress and the sweep that was meant to end its park never saw it.
is "an in_progress park is swept too"                "no"  "$(parked sp-working)"
is "a park past the deadline is stripped"            "no"  "$(parked sp-lost)"
want   "and says the park outlived the deadline"     "sp-lost: unparked — the park outlived SPIRA_CI_PARK_MAX" "$out"
# The bead must land in the report the label was keeping it out of, which means it has to be
# visible to the predicate again. Nothing else in the graph should have moved.
nowant "a closed bead's park is not the sweep's business" "sp-done: unparked" "$out"
is    "so it keeps its label"                        "yes" "$(parked sp-done)"

# THE OTHER HALF OF THE CONFIGURED LABEL. Everything above proves the sweep acts on
# $SPIRA_CI_LABEL; this proves it does not ALSO act on the shipped default, which is what a
# leftover literal would look like.
testdb_reset
testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[]}
{"id":"sp-other","title":"carries the default label, not the configured one","status":"open","issue_type":"task","labels":["spira","plan","repo:$(basename "$REPO")","awaiting-ci"]}
JSONL
out="$(sentinel)"
want "a bead carrying the shipped default is untouched" "awaiting-ci" "$(labels_of sp-other)"
nowant "and no park is reported for it"                 "sp-other: unparked" "$out"

# ======================================================================================
# THE OPS PANE. The sweep is the mechanism; the pane is how the operator finds out. It read
# "N bead(s) awaiting CI" for both populations, and for a park no run can end that sentence
# is not merely incomplete — it is the description that stops the question being asked. So
# the two figures are separate, and they are asserted through the pane's own renderer rather
# than through the collector alone: the number being right in a file nobody reads is the half
# of this that was never broken.
# ======================================================================================
echo
echo "the ops pane — waiting on a run, and parked with no run to wait for"

testdb_reset
testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[]}
{"id":"sp-real","title":"waiting on an actual run","status":"open","issue_type":"task","labels":["spira","plan","repo:reviewed","$CI_LABEL"]}
{"id":"sp-void","title":"parked where no run exists","status":"open","issue_type":"task","labels":["spira","plan","repo:$(basename "$REPO")","$CI_LABEL"]}
JSONL

env_of() {   # env_of <KEY> -> its value in the snapshot the pane reads
    sed -n "s/^$1='\(.*\)'$/\1/p" "$RUN/cockpit.env" | head -1
}
COCK_ENV=(SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" COCKPIT_DB="$SPIRA_DB"
          SPIRA_REPO="$REPO" SPIRA_REPO_MAP="$TMP/map" SPIRA_CI_LABEL="$CI_LABEL"
          SPIRA_CI_PARK_MAX=5400 SPIRA_GOAL=sp-goal SPIRA_FAYTHS=t)
env "${COCK_ENV[@]}" bash "$HERE/cockpit.sh" once >/dev/null 2>&1

is "one bead is genuinely waiting on a run"  "1"       "$(env_of SP_AWAITING_N)"
is "and one is parked with nothing to wait for" "1"    "$(env_of SP_AWAITING_STUCK)"
is "the stuck one is named, so it can be looked at" "sp-void" "$(env_of SP_AWAITING_STUCK_ID)"

# THE RENDERER, not just the numbers. TERM is pinned to something with no colour so the
# assertions match text rather than escape sequences.
pane="$(env "${COCK_ENV[@]}" TERM=dumb NO_COLOR=1 bash "$HERE/../cockpit/health.sh" once 2>/dev/null)"
want "the pane says what is waiting on a run"    "1 bead(s) waiting on a run" "$pane"
want "and says the other kind separately"        "1 parked with no run to wait for" "$pane"
want "naming it, so the next step is obvious"    "sp-void" "$pane"

# THE NEGATIVE, which is the one that keeps the line from becoming wallpaper: with nothing
# stuck, the pane must not carry the phrase at all.
testdb_reset
testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[]}
{"id":"sp-real","title":"waiting on an actual run","status":"open","issue_type":"task","labels":["spira","plan","repo:reviewed","$CI_LABEL"]}
JSONL
env "${COCK_ENV[@]}" bash "$HERE/cockpit.sh" once >/dev/null 2>&1
is "nothing is stuck" "0" "$(env_of SP_AWAITING_STUCK)"
pane="$(env "${COCK_ENV[@]}" TERM=dumb NO_COLOR=1 bash "$HERE/../cockpit/health.sh" once 2>/dev/null)"
nowant "so the pane does not mention the second kind" "parked with no run" "$pane"
want   "but still reports the first"                  "waiting on a run"   "$pane"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
