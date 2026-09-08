#!/usr/bin/env bash
#
# test-check5-nopayload.sh — CHECK 5 skips beads carrying no-payload; ordinary
#   closed beads with no commit naming them are still reopened.
#
#   ./test-check5-nopayload.sh
#
# WHY THIS EXISTS. A bead whose deliverable is the bead itself — a report, a test
# result, a diagnosis — carries no repository commit. The landing pass rebases before
# merging, so a rebase drops any empty commit, and nothing on the base will ever name
# the bead. Before this fix, CHECK 5's only guard against reopening such a bead was
# the presence of its branch — which the reaper correctly removes after the bead
# closes. When the reaper was fixed, the only suppressor of the loop was removed, and
# the bead cycled every ~4 minutes.
#
# The fix: the aeon sets the `no-payload` label on close; CHECK 5 reads it from the
# same bulk query as `spira-dropped` and skips the bead.
#
# TWO CASES, each asserted (law-absence-needs-a-positive-control):
#
#   1. POSITIVE CONTROL — a closed bead with no commit naming it IS reopened. Without
#      this, the no-payload exemption is indistinguishable from a check that never
#      fires at all.
#
#   2. NO-PAYLOAD EXEMPTION — a closed bead carrying `no-payload` is NOT reopened,
#      even though no commit names it and no branch exists.
#
# A REAL bd ON A FIXTURE DATABASE (law-prefer-the-real-dependency). The exemption
# reads a label off `bd list --status closed`, exactly the seam that broke the
# supersession exemption; a stub would drift silently.
#
# defect: sp-olxc
# covers: spira/sentinel.sh spira/lib.sh
# hermetic-ok: uses a fixture database and a local git repo, no systemd or gh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2] got [$3]"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-check5-nopayload
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up check5nopayload || { echo "test-check5-nopayload: could not build a fixture database"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" remote set-head origin main
mkdir -p "$RUN/worktree" "$SH/chamber"

cp "$HERE/sentinel.sh" "$HERE/lib.sh" "$HERE/landing.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub pilgrimage.sh 'exit 0'
stub strand.sh     'exit 0'
stub sending.sh    'exit 0'
stub governor.sh   'exit 0'
stub reflect.sh    'exit 0'
stub ask.sh        'true'

printf 'FAYTH_LABELS="spira,plan"\nFAYTH_EXCLUDE_LABELS="spira-poison,$SPIRA_ASK_LABEL,$SPIRA_CI_LABEL"\nFAYTH_MAX_CONCURRENT=0\n' > "$SH/chamber/t.fayth"

B() { bd -C "$SPIRA_DB" "$@"; }
cat > "$TMP/launch" <<'L'
#!/usr/bin/env bash
exit 0
L
cat > "$TMP/systemctl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "inactive"
S
chmod +x "$TMP/launch" "$TMP/systemctl"

HOME_REPO="$(basename "$REPO")"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$HOME_REPO" "$REPO" pr main '' '' > "$TMP/repo-map"

sentinel() {
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" \
    SPIRA_REPO="$REPO" SPIRA_HOME_REPO="$HOME_REPO" \
    SPIRA_GOAL=sp-goal SPIRA_FAYTHS="t" SPIRA_INFERENCE_EVERY=999999 \
    SPIRA_NOTIFY="$SH/ask.sh" SPIRA_REPO_MAP="$TMP/repo-map" \
    SPIRA_LAUNCH="$TMP/launch" SPIRA_SYSTEMCTL="$TMP/systemctl" \
    SPIRA_CONF="$TMP/no-such-conf" \
        bash "$SH/sentinel.sh" 2>&1
}

status_of() { B show "$1" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
print(d[0].get("status") or "")'; }

echo "test-check5-nopayload.sh"

seed() {
    testdb_reset
    testdb_seed <<JSONL
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":["spira"],"updated_at":"2026-09-08T00:00:00Z"}
{"id":"sp-bare","title":"bare closed — no commit, no no-payload","status":"closed","issue_type":"task","labels":["spira","plan","repo:$HOME_REPO"],"updated_at":"2026-09-08T00:00:00Z","dependencies":[{"issue_id":"sp-bare","depends_on_id":"sp-goal","type":"parent-child"}]}
{"id":"sp-nop","title":"no-payload closed","status":"closed","issue_type":"task","labels":["spira","plan","no-payload","repo:$HOME_REPO"],"updated_at":"2026-09-08T00:00:00Z","dependencies":[{"issue_id":"sp-nop","depends_on_id":"sp-goal","type":"parent-child"}]}
JSONL
    # CHECK 5 only examines beads that have a session log.
    touch "$RUN/sp-bare.log" "$RUN/sp-nop.log"
}

# ======================================================================================
echo
echo "positive control — an ordinary closed bead with no commit IS reopened:"
# ======================================================================================
seed
is "sp-bare starts closed" closed "$(status_of sp-bare)"
out="$(sentinel)"
is "sp-bare is reopened" open "$(status_of sp-bare)"
want "the pass says so" "reopened sp-bare" "$out"

# ======================================================================================
echo
echo "no-payload exemption — a no-payload bead is NOT reopened:"
# ======================================================================================
seed
is "sp-nop starts closed" closed "$(status_of sp-nop)"
out="$(sentinel)"
is "sp-nop stays closed" closed "$(status_of sp-nop)"
nowant "the pass does not reopen it" "reopened sp-nop" "$out"

# ======================================================================================
# VERIFY THE LABEL IS PRESENT IN THE BULK QUERY. The supersession exemption shipped
# broken because the label field was absent from the bulk listing. Check the same seam
# for no-payload so the exemption cannot silently fail to read its own signal.
# ======================================================================================
echo
echo "bulk listing carries the no-payload label:"
seed
bulk="$(B list --status closed --limit 0 --label spira,plan --json 2>/dev/null)"
has_nop="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
d = d if isinstance(d, list) else [d]
for i in d:
    if i["id"] == "sp-nop" and "no-payload" in (i.get("labels") or []):
        print("yes"); break
else:
    print("no")
' "$bulk" 2>/dev/null)"
is "sp-nop's no-payload label is in the bulk listing" "yes" "$has_nop"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
