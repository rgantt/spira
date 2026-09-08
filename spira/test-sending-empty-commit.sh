#!/usr/bin/env bash
#
# test-sending-empty-commit.sh — an empty-commit branch (no file changes vs. the base) is
# reaped by sending.sh, not permanently refused by an ancestry check.
#
#   ./test-sending-empty-commit.sh
#
# THE DEFECT (sp-kq8l). spira_destroy_branch had an ancestry fence that checked
# `merge-base --is-ancestor "$br" "$base"`. A review-only bead's commit names the bead in
# its subject (law-aeon-commits-name-their-bead) but changes no files. That commit is NOT
# an ancestor of the base after a squash merge, so the ancestry fence refused it — even
# though content_landed returned true, because merging the branch into the base would change
# nothing. sending.sh selected the branch (content_landed), spira_destroy_branch refused it
# (ancestry), and the branch accumulated refusals until a human noticed.
#
# THE POSITIVE CONTROL is a branch with real file changes that IS unlanded. sending.sh must
# keep it. Without the control, a version that reaped everything would pass the first case.
#
# covers: spira/lib.sh spira/sending.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

# shellcheck disable=SC1090
. "$HERE/testdb.sh"
testdb_require test-sending-empty-commit
TMP="$(mktemp -d)"; trap 'testdb_drop; rm -rf "$TMP"' EXIT INT TERM
testdb_up empty-commit || { echo "test-sending-empty-commit: could not build a fixture database"; exit 1; }
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

cp "$HERE/lib.sh" "$HERE/conf.sh" "$HERE/sending.sh" "$SH/"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SH/$1"; chmod +x "$SH/$1"; }
stub confine.sh 'exit 0'
stub gh 'exit 1'

sending() {
    SPIRA_HOME="$SH" SPIRA_RUN="$RUN" SPIRA_DB="$SPIRA_DB" SPIRA_REPO="$REPO" \
    SPIRA_HOME_REPO="$REPONAME" \
    SPIRA_REPO_MAP="$SH/repo-map" \
        bash "$SH/sending.sh" 2>&1
}

# seed: a closed parent epic and a closed child bead
seed() {
    testdb_reset
    testdb_seed <<'JSONL'
{"id":"sp-goal","title":"goal","status":"open","issue_type":"epic","labels":[],"updated_at":"2026-09-04T00:00:00Z"}
{"id":"sp-empty","title":"review only","status":"closed","issue_type":"task","labels":[],"updated_at":"2026-09-04T00:00:00Z","closed_at":"2026-09-04T00:00:00Z","dependencies":[{"issue_id":"sp-empty","depends_on_id":"sp-goal","type":"parent-child"}]}
{"id":"sp-real","title":"real work","status":"closed","issue_type":"task","labels":[],"updated_at":"2026-09-04T00:00:00Z","closed_at":"2026-09-04T00:00:00Z","dependencies":[{"issue_id":"sp-real","depends_on_id":"sp-goal","type":"parent-child"}]}
JSONL
}

# empty_branch <id> — a closed bead branch with an empty commit (names the bead, no file changes)
empty_branch() {
    local id="$1"
    git -C "$REPO" worktree add -q -b "spira/$id" "$RUN/worktree/$id" main
    git -C "$RUN/worktree/$id" commit -q --allow-empty -m "sp-kq8l: review-only bead $id"
    git -C "$REPO" worktree remove "$RUN/worktree/$id" 2>/dev/null || true
}

# real_branch <id> — a closed bead branch with an actual file change that has NOT landed
real_branch() {
    local id="$1"
    git -C "$REPO" worktree add -q -b "spira/$id" "$RUN/worktree/$id" main
    printf '%s\n' "$id" > "$RUN/worktree/$id/$id.txt"
    git -C "$RUN/worktree/$id" add -A
    git -C "$RUN/worktree/$id" commit -q -m "sp-kq8l: real work $id"
    git -C "$REPO" worktree remove "$RUN/worktree/$id" 2>/dev/null || true
}

echo "test-sending-empty-commit.sh"

# --------------------------------------------------------------------------------------
# SETUP: base is on origin/main; the empty-commit branch changes nothing vs. the base;
# the real-work branch changes a file that is not yet on origin/main.
# --------------------------------------------------------------------------------------
seed
empty_branch sp-empty
real_branch  sp-real
git -C "$REPO" fetch -q origin

# --------------------------------------------------------------------------------------
# POSITIVE CONTROL: content_landed must agree the empty branch carries nothing new.
# Plant a failure first (ancestry-only test) to prove we would catch a regression.
# --------------------------------------------------------------------------------------
. "$SH/lib.sh"
if git -C "$REPO" merge-base --is-ancestor "spira/sp-empty" "origin/main" 2>/dev/null; then
    bad "ancestry alone would NOT have caught the defect" "branch is an ancestor — test fixture is wrong"
else
    ok "ancestry alone refuses the empty-commit branch (this is the defect being fixed)"
fi

if content_landed "$REPO" "spira/sp-empty" "origin/main"; then
    ok "content_landed correctly approves the empty-commit branch"
else
    bad "content_landed should approve an empty-commit branch" "it returned non-zero"
fi

if content_landed "$REPO" "spira/sp-real" "origin/main"; then
    bad "content_landed should NOT approve the real-work branch" "it returned 0"
else
    ok "content_landed correctly refuses the real-work branch (unlanded)"
fi

# --------------------------------------------------------------------------------------
# THE MAIN ASSERTION: sending.sh reaps the empty-commit branch, keeps the real one.
# --------------------------------------------------------------------------------------
out="$(sending)"
printf '%s\n' "$out" | head -20 >&2

want   "sending reaps the empty-commit branch"            "SENT sp-empty"          "$out"
nowant "sending does not keep the empty-commit branch"    "KEEP   sp-empty"        "$out"
nowant "sending does not report it as failed"             "FAILED sp-empty"        "$out"

want   "sending keeps the real-work branch (unlanded)"    "KEEP   sp-real"         "$out"
nowant "sending does not reap unlanded real work"         "REAPED sp-real"         "$out"

# Verify the git refs directly.
if git -C "$REPO" show-ref --verify --quiet "refs/heads/spira/sp-empty" 2>/dev/null; then
    bad "the empty-commit branch is actually gone" "spira/sp-empty still exists after reap"
else
    ok "the empty-commit branch is actually gone"
fi
if git -C "$REPO" show-ref --verify --quiet "refs/heads/spira/sp-real" 2>/dev/null; then
    ok "the real-work branch still exists (correctly kept)"
else
    bad "the real-work branch still exists" "spira/sp-real was deleted — unlanded work lost"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
