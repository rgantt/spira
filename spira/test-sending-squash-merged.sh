#!/usr/bin/env bash
#
# test-sending-squash-merged.sh — sending.sh reaps a closed bead's branch when
#   the PR was squash-merged and the branch tip equals the PR's headRefOid.
#
#   ./test-sending-squash-merged.sh
#
# THE CASE (sp-3gih). A squash-merge lands the branch's diff as one new commit
# the branch is not an ancestor of. content_landed then returns false about a
# finished branch when the base has since moved past the squash point and touches
# the same files. The sending therefore KEEPs the branch forever, even though the
# PR captured every commit on it. This is the "SEND block persistent floor" shape.
#
# THE GUARD. A merged PR whose headRefOid equals the current branch tip is proof
# that (a) the PR captured every commit and (b) no commits were added after the
# merge. Combined with a CLOSED bead, the three facts together justify reaping.
#
# POSITIVE CONTROL is a genuinely unlanded branch (content not on base) whose
# bead is also CLOSED — it must NOT be reaped, to distinguish from the squash case.
#
# NEGATIVE CONTROL is a squash-merged branch where a new commit was added after
# the PR merged (tip ≠ PR headRefOid) — must NOT be reaped.
#
# covers: spira/sending.sh spira/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-sending-squash-merged
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up squash-merged || { echo "test-sending-squash-merged: could not build fixture database"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

REPO="$TMP/repo"; RUN="$TMP/run"; REMOTE="$TMP/remote.git"; SH="$TMP/spira"
REPONAME=fixture-repo
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
mkdir -p "$RUN/worktree" "$SH"

cp "$HERE/sending.sh" "$HERE/lib.sh" "$HERE/conf.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub confine.sh 'exit 0'

sending() {
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_HOME_REPO="$REPONAME" SPIRA_GH="$SH/gh" \
    SPIRA_REPO_MAP="$SH/repo-map" \
        bash "$SH/sending.sh" 2>&1
}

seed() {
    testdb_reset
    testdb_seed <<'JSONL'
{"id":"sp-sq","title":"squash bead","status":"closed","issue_type":"task","labels":[],"updated_at":"2026-09-05T00:00:00Z","closed_at":"2026-09-05T00:00:00Z","dependencies":[]}
{"id":"sp-post","title":"post-squash new commit","status":"closed","issue_type":"task","labels":[],"updated_at":"2026-09-05T00:00:00Z","closed_at":"2026-09-05T00:00:00Z","dependencies":[]}
{"id":"sp-unland","title":"genuinely unlanded","status":"closed","issue_type":"task","labels":[],"updated_at":"2026-09-05T00:00:00Z","closed_at":"2026-09-05T00:00:00Z","dependencies":[]}
JSONL
}

# ---------------------------------------------------------------------------
# Build repo state:
#
#   main: base <- squash (squashes sp-sq's changes) <- extra (touches same file)
#   spira/sp-sq:    base <- A (adds shared.txt=original) <- B (updates shared.txt)
#   spira/sp-post:  base <- A' (same as sp-sq's A) <- B' (same as sp-sq's B) <- C (new)
#   spira/sp-unland: base <- X (unique content not on main)
#
# sp-sq:    content_landed=false (squash on main, extra then conflicts on same file)
#           pr view returns MERGED with tip=B  → should be REAPED
# sp-post:  content_landed=false, pr view returns MERGED with headRefOid=B'≠C → KEEP
# sp-unland: content_landed=false (unique content not on main), bead closed,
#            pr view returns nothing (no PR) → KEEP
# ---------------------------------------------------------------------------

# sp-sq branch: two commits
git -C "$REPO" worktree add -q -b spira/sp-sq "$RUN/worktree/sp-sq" main
printf 'line1\nline2\n' > "$RUN/worktree/sp-sq/shared.txt"
git -C "$RUN/worktree/sp-sq" add shared.txt
git -C "$RUN/worktree/sp-sq" commit -q -m "sp-sq — commit A"
printf 'line1\nline2\nline3\n' > "$RUN/worktree/sp-sq/shared.txt"
git -C "$RUN/worktree/sp-sq" add shared.txt
git -C "$RUN/worktree/sp-sq" commit -q -m "sp-sq — commit B"
SQ_TIP="$(git -C "$REPO" rev-parse spira/sp-sq)"

# squash-merge sp-sq's changes onto main (simulating GitHub's squash-merge)
# result: main has shared.txt with same content but new SHA
git -C "$REPO" checkout -q main
printf 'line1\nline2\nline3\n' > "$REPO/shared.txt"
git -C "$REPO" add shared.txt
git -C "$REPO" commit -q -m "sp-sq: squash-merge (#99)"
# post-squash commit: touch the same file (creates a conflict for content_landed)
printf 'line1\nline2\nline3\nextra\n' > "$REPO/shared.txt"
git -C "$REPO" add shared.txt
git -C "$REPO" commit -q -m "sp-other: extra change on main"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

# sp-post branch: same commits as sp-sq PLUS one new commit after squash
git -C "$REPO" worktree add -q -b spira/sp-post "$RUN/worktree/sp-post" "$(git -C "$REPO" rev-parse spira/sp-sq~2)"
printf 'line1\nline2\n' > "$RUN/worktree/sp-post/shared.txt"
git -C "$RUN/worktree/sp-post" add shared.txt
git -C "$RUN/worktree/sp-post" commit -q -m "sp-post — commit A'"
printf 'line1\nline2\nline3\n' > "$RUN/worktree/sp-post/shared.txt"
git -C "$RUN/worktree/sp-post" add shared.txt
git -C "$RUN/worktree/sp-post" commit -q -m "sp-post — commit B' (was PR head)"
POST_PR_TIP="$(git -C "$REPO" rev-parse spira/sp-post)"
# new commit added AFTER the PR was merged (tip now ≠ PR headRefOid)
printf 'post-squash addition\n' > "$RUN/worktree/sp-post/extra.txt"
git -C "$RUN/worktree/sp-post" add extra.txt
git -C "$RUN/worktree/sp-post" commit -q -m "sp-post — extra commit after squash"

# sp-unland branch: genuinely unlanded unique content
git -C "$REPO" worktree add -q -b spira/sp-unland "$RUN/worktree/sp-unland" main
printf 'truly unique content\n' > "$RUN/worktree/sp-unland/unique.txt"
git -C "$RUN/worktree/sp-unland" add unique.txt
git -C "$RUN/worktree/sp-unland" commit -q -m "sp-unland — work"

# write repo-map
printf 'fixture-repo %s\n' "$REPO" > "$SH/repo-map"

# gh stub: the sending calls `gh pr view <branch> --json state,headRefOid -q '...'`
# which produces only the headRefOid string (via jq -q select). The stub mimics that:
# for a MERGED PR it outputs the headRefOid directly; for anything else it exits 1.
# $1=pr $2=view $3=branch-name; remaining are --json/flags the stub ignores.
stub gh "$(cat <<GHSTUB
case "\$3" in
  spira/sp-sq)   printf '%s\n' "$SQ_TIP"; exit 0 ;;
  spira/sp-post) printf '%s\n' "$POST_PR_TIP"; exit 0 ;;
  *)             exit 1 ;;
esac
GHSTUB
)"

# ---------------------------------------------------------------------------
printf '\nsquash-merged — branch reaped when PR tip matches current tip:\n'
seed
out="$(sending)"
printf '%s\n' "$out"
want "sp-sq was reaped"          "REAPED sp-sq"   "$out"
nowant "sp-sq was not kept"      "KEEP   sp-sq"   "$out"
[ ! -e "$REPO/.git/refs/heads/spira/sp-sq" ]  && \
    ok  "sp-sq branch is gone" || bad "sp-sq branch is gone" "ref still exists"

printf '\npost-squash new commit — branch kept when tip moved past PR head:\n'
want "sp-post was kept (tip moved after PR)" "KEEP   sp-post" "$out"
nowant "sp-post was not reaped"              "REAPED sp-post"  "$out"
[ -e "$REPO/.git/refs/heads/spira/sp-post" ] && \
    ok  "sp-post branch still exists" || bad "sp-post branch still exists" "ref is gone"

printf '\ngenuinely unlanded — unique content still kept:\n'
want "sp-unland was kept"        "KEEP   sp-unland" "$out"
nowant "sp-unland was not reaped" "REAPED sp-unland" "$out"
[ -e "$REPO/.git/refs/heads/spira/sp-unland" ] && \
    ok  "sp-unland branch still exists" || bad "sp-unland branch still exists" "ref is gone"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
