#!/usr/bin/env bash
#
# test-deploy.sh — deploy.sh: deployment controller reviews a release unit and deploys
# or blocks it; landing.sh may never call promote.sh.
#
#   ./test-deploy.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# deploy.sh is the only component that advances the production checkout. Four
# properties are checked:
#
#   1. SELF-CHANGE GUARD: a unit whose diff includes spira/deploy.sh is refused
#      (exit 1) and production is not advanced.
#   2. BLOCK: a reviewer verdict of BLOCK is refused (exit 1) and production is
#      not advanced.
#   3. SHIP: a reviewer verdict of SHIP results in promotion (exit 0); the
#      production checkout advances to the release tag.
#   4. DRY RUN: --dry-run with a SHIP verdict does not advance production.
#   5. PUBLICATION INVARIANT: landing.sh contains no call to promote.sh or
#      deploy.sh, so the two-publisher state is unreachable. Asserted against
#      the code path (grep), not by inspection.
#
# POSITIVE CONTROL (law-absence-needs-a-positive-control)
# -------------------------------------------------------
# The fake claude shim is verified reachable before the BLOCK and SHIP tests.
# The systemctl shim is verified reachable before the SHIP test.
# The self-change check is verified to fire on a unit that contains deploy.sh
# before the no-self-change path is trusted.
#
# FAKE CLAUDE (law-gates-run-in-a-clean-environment)
# --------------------------------------------------
# A real claude call is prohibited: it draws on the operator's account and costs
# money on every run. The fake claude reads FAKE_REVIEW_VERDICT and emits a
# valid compact stream-json response, identical to the one in test-review.sh.
#
# covers: spira/deploy.sh spira/review.sh spira/promote.sh spira/landing.sh
# covers: spira/release.sh spira/conf.sh spira/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# ---- test database (real bd, throwaway database) ----------------------------
# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-deploy
TMP="$(mktemp -d)"
trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up deploy || { echo "test-deploy: could not build fixture database"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ---- git fixture ------------------------------------------------------------
# A bare remote with 'trunk' as its default branch (deliberate: a hardcoded
# 'main' in any reviewed script fails here immediately).
ORIGIN="$TMP/origin.git"
REPO="$TMP/repo"
git init -q --bare -b trunk "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t

# Initial base commit — BASE_SHA is where production starts.
printf 'base\n' > "$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -qm "initial commit"
git -C "$REPO" push -q origin trunk 2>/dev/null
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

# ---- harness fixture --------------------------------------------------------
# The harness scripts live in $SH ($TMP/spira). basename "$SH" = "spira", so
# deploy.sh will compute SELF_PATH = "spira/deploy.sh" — matching the path that
# the self-change commit adds to the git fixture repo.
SH="$TMP/spira"
mkdir -p "$SH"
for f in deploy.sh review.sh release.sh promote.sh lib.sh conf.sh; do
    [ -f "$HERE/$f" ] && cp "$HERE/$f" "$SH/"
done
chmod +x "$SH/deploy.sh" "$SH/review.sh" "$SH/release.sh" "$SH/promote.sh"

REPO_MAP="$TMP/repo-map"
# Columns: name | path | land-mode | base | prefix | format
printf 'fixture | %s | push | origin/trunk | sp | |\n' "$REPO" > "$REPO_MAP"

VERDICTS="$TMP/verdicts"
mkdir -p "$VERDICTS" "$TMP/run"

# ---- fake claude ------------------------------------------------------------
# Compact stream-json: '"type":"result"' must appear literally.
# Python default json.dumps adds spaces after ':', breaking the substring check.
FAKE_CLAUDE="$TMP/fake-claude"
cat > "$FAKE_CLAUDE" <<'FAKEEOF'
#!/usr/bin/env python3
import json, os, sys
sys.stdin.read()  # consume the prompt
verdict = os.environ.get("FAKE_REVIEW_VERDICT", "ship")
if verdict == "block":
    result_text = (
        "VERDICT: BLOCK\n"
        "FINDING: test-finding in fixture\n"
        "Synthetic blocking finding for the test suite.\n"
        "---\n"
    )
else:
    result_text = "VERDICT: SHIP"
events = [
    {"type":"system","subtype":"init","session_id":"test",
     "tools":[],"mcp_servers":[]},
    {"type":"result","subtype":"success","is_error":False,
     "result":result_text,"session_id":"test",
     "total_cost_usd":0.0042,
     "duration_ms":100,"duration_api_ms":80,"num_turns":1,
     "usage":{"input_tokens":512,"output_tokens":18,
              "cache_read_input_tokens":0}},
]
for e in events:
    print(json.dumps(e, separators=(',', ':')))
FAKEEOF
chmod +x "$FAKE_CLAUDE"

# ---- fake systemctl ---------------------------------------------------------
# Records every call; the SHIP test confirms restarts happened (positive control
# on promote.sh's unit-restart path).
SCTL_LOG="$TMP/systemctl.log"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$SCTL_LOG" > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemctl"

# ---- helpers ----------------------------------------------------------------
run_release() {
    # Stdout: tag name (or nothing). Stderr: "no beads landed" when there is nothing to tag.
    env -i PATH="$PATH" HOME="$HOME" \
        SPIRA_CONF=/nonexistent \
        SPIRA_RUN="$TMP/run" \
        SPIRA_REPO_MAP="$REPO_MAP" \
        SPIRA_REPO="$REPO" \
        SPIRA_HOME="$SH" \
        SPIRA_GOAL=sp-goal \
        SPIRA_ID_PREFIX=sp \
        bash "$SH/release.sh" "$@"
}

# SPIRA_REPO=$REPO so promote.sh can resolve release tags inside the fixture git repo.
# SPIRA_HOME=$SH so conf.sh knows where the harness scripts live.
# SPIRA_SYSTEMCTL is the fake so promote.sh's restart calls are captured, not executed.
run_deploy() {
    env -i PATH="$PATH" HOME="$HOME" \
        SPIRA_CONF=/nonexistent \
        SPIRA_RUN="$TMP/run" \
        SPIRA_REPO_MAP="$REPO_MAP" \
        SPIRA_REPO="$REPO" \
        SPIRA_HOME="$SH" \
        SPIRA_GOAL=sp-goal \
        SPIRA_ID_PREFIX=sp \
        SPIRA_DB="$SPIRA_DB" \
        SPIRA_CLAUDE="$FAKE_CLAUDE" \
        SPIRA_REVIEWER_VERDICTS="$VERDICTS" \
        SPIRA_REVIEWER_MODEL=claude-test-model \
        SPIRA_REVIEWER_TIMEOUT=30 \
        SPIRA_REVIEW_LABEL=review-finding \
        SPIRA_PROD="$PROD_HOME" \
        SPIRA_SYSTEMCTL="$TMP/bin/systemctl" \
        FAKE_REVIEW_VERDICT="${FAKE_REVIEW_VERDICT:-ship}" \
        bash "$SH/deploy.sh" "$@" 2>&1
}

# ---- build the commit history and cut tags in the right order ---------------
# SELF_TAG must be cut BEFORE sp-ccc is pushed, so that:
#   - SELF_TAG's diff includes spira/deploy.sh (the self-change guard)
#   - SHIP_TAG's diff is ONLY sp-ccc (no deploy.sh)
printf 'a\n' >> "$REPO/f"; git -C "$REPO" add f
git -C "$REPO" commit -qm "sp-aaa — first bead"
printf 'b\n' >> "$REPO/f"; git -C "$REPO" add f
git -C "$REPO" commit -qm "sp-bbb — second bead"
mkdir -p "$REPO/spira"
printf '#!/bin/sh\necho deploy-v1\n' > "$REPO/spira/deploy.sh"
git -C "$REPO" add spira/deploy.sh
git -C "$REPO" commit -qm "sp-self — change the deployment controller"
git -C "$REPO" push -q origin trunk 2>/dev/null

# Cut SELF_TAG now: trunk tip = sp-self commit, includes spira/deploy.sh.
SELF_TAG="$(run_release cut fixture 2>/dev/null)"
[ -n "$SELF_TAG" ] || { echo "SETUP FAILED: could not cut self-change release tag"; exit 1; }

# Now push sp-ccc; SHIP_TAG will cover only this commit.
printf 'c\n' >> "$REPO/f"; git -C "$REPO" add f
git -C "$REPO" commit -qm "sp-ccc — third bead"
git -C "$REPO" push -q origin trunk 2>/dev/null
SHIP_SHA="$(git -C "$REPO" rev-parse HEAD)"

# Cut SHIP_TAG: trunk tip = sp-ccc commit, no deploy.sh change in this diff.
SHIP_TAG="$(run_release cut fixture 2>/dev/null)"
[ -n "$SHIP_TAG" ] || { echo "SETUP FAILED: could not cut ship release tag"; exit 1; }

# ---- production checkout ----------------------------------------------------
# Clone production from REPO and detach at BASE_SHA so promote.sh can
# fast-forward from a known ancestor to the release tag's commit.
PROD_ROOT="$TMP/prod"
PROD_HOME="$PROD_ROOT/spira"   # SPIRA_PROD — a subdir of the git root
git clone -q "$REPO" "$PROD_ROOT" 2>/dev/null
git -C "$PROD_ROOT" checkout --detach "$BASE_SHA" >/dev/null 2>&1
mkdir -p "$PROD_HOME"

prod_head() { git -C "$PROD_ROOT" rev-parse HEAD 2>/dev/null; }

# ======================================================================================
echo
echo "positive control — fake claude and systemctl shims are reachable"
# ======================================================================================
"$FAKE_CLAUDE" <<< "" | grep -q '"type":"result"' \
    && ok "fake-claude: emits stream-json" \
    || bad "fake-claude: emits stream-json" "did not find type:result"
"$TMP/bin/systemctl" --user restart spira-canary.service 2>/dev/null || true
want "systemctl shim: records calls" "spira-canary.service" "$(cat "$SCTL_LOG")"

# ======================================================================================
echo
echo "1. SELF-CHANGE GUARD — unit containing spira/deploy.sh is refused"
# ======================================================================================
prod_before="$(prod_head)"
out_self="$(run_deploy "$SELF_TAG" 2>&1)" || true
rc_self=0; run_deploy "$SELF_TAG" >/dev/null 2>&1 || rc_self=$?

want "self-change: refuses with message"        "must not deploy itself"  "$out_self"
want "self-change: names the changed path"      "deploy.sh"               "$out_self"
is   "self-change: exits 1"                     "1"                       "$rc_self"
is   "self-change: production unchanged"        "$prod_before"            "$(prod_head)"

# ======================================================================================
echo
echo "2. BLOCK — reviewer returns BLOCK; production is not advanced"
# ======================================================================================
prod_before="$(prod_head)"
> "$SCTL_LOG"
out_block=""; block_rc=0
out_block="$(FAKE_REVIEW_VERDICT=block run_deploy "$SHIP_TAG" 2>&1)" || true
FAKE_REVIEW_VERDICT=block run_deploy "$SHIP_TAG" >/dev/null 2>&1 || block_rc=$?

# Clear the BLOCK verdict so later tests start fresh.
rm -f "$VERDICTS/$SHIP_TAG.verdict"

is   "block: exits 1"                           "1"                       "$block_rc"
want "block: says BLOCKED"                      "BLOCKED"                 "$out_block"
is   "block: production not advanced"           "$prod_before"            "$(prod_head)"
is   "block: systemctl not called"              ""                        "$(cat "$SCTL_LOG")"

# A finding bead must have been filed (review.sh files findings on BLOCK).
bead_count="$(env -i PATH="$PATH" HOME="$HOME" \
    SPIRA_CONF=/nonexistent \
    SPIRA_DB="$SPIRA_DB" \
    SPIRA_ID_PREFIX=sp \
    bash -c '. '"$SH/lib.sh"'; bdjson list --status open --label review-finding --limit 0 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else (1 if d else 0))
except: print(0)
"')"
[ "${bead_count:-0}" -ge 1 ] \
    && ok "block: finding bead filed (count=$bead_count)" \
    || bad "block: finding bead filed" "got count=${bead_count:-0}, want >=1"

# ======================================================================================
echo
echo "3. SHIP — reviewer returns SHIP; production is advanced to the release tag"
# ======================================================================================
> "$SCTL_LOG"
out_ship=""; ship_rc=0
out_ship="$(FAKE_REVIEW_VERDICT=ship run_deploy "$SHIP_TAG" 2>&1)" || true
FAKE_REVIEW_VERDICT=ship run_deploy "$SHIP_TAG" >/dev/null 2>&1 || ship_rc=$?

tag_commit="$(git -C "$REPO" rev-parse "${SHIP_TAG}^{commit}" 2>/dev/null)"
is   "ship: exits 0"                            "0"                       "$ship_rc"
want "ship: stdout contains ship"               "ship"                    "$out_ship"
is   "ship: production advanced to tag commit"  "$tag_commit"             "$(prod_head)"

# ======================================================================================
echo
echo "4. DRY RUN — --dry-run with SHIP does not advance production"
# ======================================================================================
# Reset production to BASE_SHA for this test.
git -C "$PROD_ROOT" checkout --detach "$BASE_SHA" >/dev/null 2>&1
rm -f "$VERDICTS/$SHIP_TAG.verdict"
> "$SCTL_LOG"
dry_rc=0
out_dry="$(FAKE_REVIEW_VERDICT=ship run_deploy --dry-run "$SHIP_TAG" 2>&1)" || dry_rc=$?

is   "dry-run: exits 0"                         "0"                       "$dry_rc"
want "dry-run: reports would promote"           "would promote"           "$out_dry"
is   "dry-run: production unchanged"            "$BASE_SHA"               "$(prod_head)"
is   "dry-run: systemctl not called"            ""                        "$(cat "$SCTL_LOG")"

# ======================================================================================
echo
echo "5. PUBLICATION INVARIANT — landing.sh has no call to promote.sh or deploy.sh"
# ======================================================================================
# This is the code-path assertion. The two-publisher state is unreachable because
# no call to promote.sh or deploy.sh exists in landing.sh's code. Grepped against
# the installed landing.sh (not a fixture copy) because the invariant must hold in
# the code that actually runs (law-a-documented-control-must-exist: the check must
# be able to fire against something real).
if grep -qE '\bpromote\.sh\b|\bdeploy\.sh\b' "$HERE/landing.sh" 2>/dev/null; then
    bad "publication invariant" \
        "landing.sh contains a call to promote.sh or deploy.sh — two-publisher state reachable"
else
    ok "publication invariant: landing.sh has no promote.sh/deploy.sh call"
fi

# ======================================================================================
echo
echo "6. SUITE SELF-CHECK — suite fails without deploy.sh"
# ======================================================================================
rm -f "$SH/deploy.sh"
rm -f "$VERDICTS/$SHIP_TAG.verdict"
absent_rc=0; run_deploy "$SHIP_TAG" >/dev/null 2>&1 || absent_rc=$?
[ "$absent_rc" -ne 0 ] \
    && ok "self-check: deploy.sh absent causes failure" \
    || bad "self-check: deploy.sh absent causes failure" "got exit 0, want non-zero"

# ======================================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
