#!/usr/bin/env bash
#
# test-cutover.sh — the Step 3 measurement, against real git repositories and real fixtures.
#
#   ./test-cutover.sh
#
# This number decides whether Gas Town gets switched off, so the assertions that matter are the
# ones about being WRONG rather than about being right:
#
#   - a probe that could not run must render `?`, never 0, and must make the verdict undecided;
#     "nothing landed" and "I could not look" license opposite decisions
#   - a Gas Town polecat commit that landed in Spira's own repository is Gas Town's
#   - a commit the operator authored naming a Gas Town bead is HIS, not the harness's — that is the
#     attribution rule that would most flatter the system being measured if it were wrong
#   - an author nobody recognises is named, never folded into a side
#
# Part A is the classifier alone: pure, no git, no database. Part B drives cutover.sh against
# real repositories with real remotes, because every claim it makes about landing refs is a
# claim about git's behaviour and a mocked git would only assert that the author agrees with
# himself.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()   { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }
eq()     { [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted [$2], got [$3]"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ======================================================================================
echo "part A — the classifier"
# ======================================================================================
classify() {   # classify <roster-csv> <known-bead-ids-csv> <<< tsv-lines
    local roster="$1" ids="$2"
    ROSTER="$(tr ',' '\n' <<< "$roster")" \
    ACTORS="$FIXTURE_ACTORS" \
    BEAD_IDS="$(tr ',' '\n' <<< "$ids")" python3 "$HERE/cutover-classify.py"
}
# The report's columns are width-fitted to the longest repo name, so an assertion written with
# literal padding breaks whenever a fixture is renamed. Compare on squeezed whitespace.
sq() { tr -s ' ' <<< "$1"; }
wantr() { want "$1" "$(sq "$2")" "$(sq "$3")"; }
nowantr() { nowant "$1" "$(sq "$2")" "$(sq "$3")"; }
jget() { python3 -c 'import sys,json;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k] if not k.isdigit() else d[int(k)]
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$1"; }

# THE ROSTER IS THE FIXTURE'S OWN. The shipped file is an example whose rows name nobody in
# particular, and a suite that read it would be asserting against documentation.
FIXTURE_ACTORS=$'the operator=human\nmayor=gastown\ndeacon=gastown\n'

A_TSV=$(cat <<'EOF'
brain	aeon-builder	aeon-builder@spira.local	feat: sp-stranded — stranded detection
brain	ruby	dev@example.invalid	note: measured token cost of the AGENT_INFO surface (hh-6xk)
brain	the operator	dev@example.invalid	chore: statute book synthesis
pd	the operator	dev@example.invalid	M-fix: the cards sweep never landed (pd-2cpx)
pd	pipboy	dev@example.invalid	M-fix: the provisional badge is only shown where it can come true (pd-mt57)
pd	smoothhorse7055	bot@example.invalid	WIP: checkpoint (auto)
pd	smoothhorse7055	bot@example.invalid	M-fix: a replica has THREE states (pd-reyy)
de	mayor	dev@example.invalid	fix(ui): guard renderPriceChart against a stale fetch
EOF
)
J="$(classify 'ruby,pipboy' 'hh-6xk,pd-2cpx,pd-mt57,pd-reyy' <<< "$A_TSV")"

eq  "an aeon address is spira"            1 "$(jget totals.spira    <<< "$J")"
eq  "a polecat is gastown"                3 "$(jget totals.gastown  <<< "$J")"
eq  "the operator is human, from the actors file" 2 "$(jget totals.human    <<< "$J")"
eq  "an unrecognised author is other"     2 "$(jget totals.other    <<< "$J")"

# The two scars. Each of these is an attribution rule that a reasonable first implementation
# gets wrong, and each gets it wrong in the direction that flatters the wrong system.
eq  "a polecat commit in Spira's OWN repo counts as gastown" \
    1 "$(python3 -c 'import sys,json;print(json.load(sys.stdin)["repos"]["brain"]["gastown"])' <<< "$J")"
eq  "the operator naming a pd- bead is HUMAN, not gastown throughput" \
    1 "$(python3 -c 'import sys,json;print(json.load(sys.stdin)["repos"]["pd"]["human"])' <<< "$J")"

want "an unclassified author is NAMED with a count" '"smoothhorse7055": 2' "$(jget unclassified <<< "$J")"
want "mayor is gastown by the actors file"          '"de": {"gastown": 1' "$(jget repos <<< "$J")"

# Bead ids: the secondary count, and the one place a loose match quietly invents work. `co` and
# `de` really are live prefixes, so prose is only kept out by checking the id set.
B="$(classify '' 'co-locate,de-dupe' <<'EOF'
r	the operator	r@r	a pre-flight check of the co-located de-duplication path
EOF
)"
eq  "English that merely LOOKS like a bead id is not one" '[]' "$(jget beads.human <<< "$B")"
B2="$(classify '' 'sp-branch-cleanup' <<'EOF'
r	aeon-builder	a@spira.local	feat: sp-branch-cleanup — the Sending
r	aeon-builder	a@spira.local	docs: sp-branch-cleanup — again, same bead
EOF
)"
eq  "two commits naming one bead are one bead" '["sp-branch-cleanup"]' "$(jget beads.spira <<< "$B2")"
B3="$(classify '' '' <<'EOF'
r	aeon-builder	a@spira.local	feat: sp-branch-cleanup
EOF
)"
eq  "a failed id probe claims no beads, never a guess" '[]' "$(jget beads.spira <<< "$B3")"

# A subject containing a tab must not cost the commit. Dropping rows is the one failure this
# whole program cannot tolerate, and a split on tab is exactly how it would happen.
B4="$(printf 'r\taeon-builder\ta@spira.local\tfeat:\tsp-x tabbed subject\n' | classify '' 'sp-x')"
eq  "a tab in the subject does not drop the commit" 1 "$(jget totals.spira <<< "$B4")"

# ======================================================================================
echo "part B — cutover.sh against real repositories"
# ======================================================================================
# The fixtures' own base commits are authored as the operator so they land in `human` — a bucket that
# does not enter the comparison. Left as an unknown name they would have shown up as three
# `other` commits and flipped two verdict assertions, which is a fair demonstration of how much
# the `other` bucket weighs.
export GIT_AUTHOR_NAME=the operator GIT_AUTHOR_EMAIL=dev@example.invalid
export GIT_COMMITTER_NAME=the operator GIT_COMMITTER_EMAIL=dev@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

WS="$TMP/ws"; TOWN="$TMP/town"; REM="$TMP/remotes"; CHAMBER="$TMP/home"
mkdir -p "$WS" "$TOWN" "$REM" "$CHAMBER/chamber" "$TMP/run"

# A `bd` that answers only the one question cutover.sh asks it: which bead ids exist.
cat > "$TMP/bd" <<'EOF'
#!/bin/sh
[ -f "$SPIRA_STUB_PREFIX_FAIL" ] 2>/dev/null && exit 1
echo '[{"id":"sp-one"},{"id":"sp-two"},{"id":"sp-three"},{"id":"sp-four"},{"id":"pd-mt57"},{"id":"pd-zzz"}]'
EOF
chmod +x "$TMP/bd"

mkrepo() {   # mkrepo <name> <default-branch> <remote-name> [set-head]
    local n="$1" br="$2" rn="$3" head="${4:-}"
    git init -q --bare "$REM/$n.git"
    git init -q -b "$br" "$WS/$n"
    git -C "$WS/$n" commit -q --allow-empty -m "base"
    git -C "$WS/$n" remote add "$rn" "$REM/$n.git"
    git -C "$WS/$n" push -q "$rn" "$br"
    git -C "$WS/$n" fetch -q "$rn"
    [ -n "$head" ] && git -C "$WS/$n" remote set-head "$rn" "$br"
    return 0
}
commit() {   # commit <name> <branch> <author> <email> <subject> [iso-date]
    local n="$1" br="$2" an="$3" ae="$4" s="$5" dt="${6:-}"
    echo "$RANDOM$RANDOM" >> "$WS/$n/f"
    git -C "$WS/$n" add -A
    GIT_AUTHOR_DATE="$dt" GIT_COMMITTER_DATE="$dt" \
        git -C "$WS/$n" -c "user.name=$an" -c "user.email=$ae" commit -q --author="$an <$ae>" -m "$s"
    git -C "$WS/$n" push -q "$(git -C "$WS/$n" remote | head -n1)" "$br"
    git -C "$WS/$n" fetch -q --prune
}
mkrig() {    # mkrig <rig> <remote-url>
    git init -q --bare "$TOWN/$1/.repo.git"
    git -C "$TOWN/$1/.repo.git" remote add origin "$2"
}

# alpha — Spira's repository: origin/HEAD set, so the HEAD branch is what resolves.
mkrepo alpha main origin set-head
# beta — a rig with NO origin/HEAD and no `main`: the master fallback must find it.
mkrepo beta master origin
# gamma — a rig whose remote is not called origin. Assuming `origin` reported zero landed
# commits for a repository with real work in it, which is why this case is here.
mkrepo gamma master gitea
# delta — a checkout that exists but has no landing ref at all under its remote.
git init -q --bare "$REM/delta.git"
git init -q -b sideshow "$WS/delta"
git -C "$WS/delta" commit -q --allow-empty -m base
git -C "$WS/delta" remote add origin "$REM/delta.git"

mkrig beta "$REM/beta.git"
mkrig gamma "$REM/gamma.git"
mkrig delta "$REM/delta.git"
mkrig ghost "$REM/nowhere.git"     # a rig whose repository is not checked out here at all

cat > "$CHAMBER/chamber/builder.fayth" <<EOF
FAYTH_NAME=builder
FAYTH_LABELS="spira,plan"
EOF
# SPIRA'S REPOSITORIES COME FROM repo-map, not from the chamber. A fayth pinned one
# repository per persona, which is what made the harness single-repo; the bead names its own
# now, so the roster of repositories Spira can land in is this file.
cat > "$CHAMBER/repo-map" <<EOF
alpha | $WS/alpha | push | |
EOF

cut() {   # cut <args...> — one run, with the fixture world in place of the real one
    SPIRA_HOME="$CHAMBER" SPIRA_RUN="$TMP/run" SPIRA_DB=/nonexistent \
    SPIRA_HOME_REPO=alpha \
    SPIRA_BD="$TMP/bd" GT_TOWN="$TOWN" SPIRA_WORKSPACES="$WS" \
    SPIRA_STUB_PREFIX_FAIL="${PFAIL:-/nonexistent}" \
        bash "$HERE/cutover.sh" "$@" --no-fetch 2>&1
}

R="$(cut repos)"
want "origin/HEAD resolves the landing ref"        $'alpha\t'"$WS/alpha"$'\torigin\torigin/main' "$R"
want "master is found when there is no HEAD"       $'beta\t'"$WS/beta"$'\torigin\torigin/master' "$R"
want "a remote that is not called origin resolves" $'gamma\t'"$WS/gamma"$'\tgitea\tgitea/master' "$R"
want "no landing ref is an ERROR, not a default"   'delta	-	-	ERROR:no landing ref' "$R"
want "a rig with no checkout is an ERROR"          'ghost	-	-	ERROR:no checkout of' "$R"
nowant "a rig with no checkout is not silently dropped" $'ghost\t-\t-\t-' "$R"

# ---------------------------------------------------------------------------------------
# The window opens at the earliest aeon commit — a fact in the graph, so that the one number
# deciding whether a system is switched off cannot be edited after the outcome is known.
# ---------------------------------------------------------------------------------------
OLD='2026-08-01T00:00:00+0000'
commit alpha main aeon-builder aeon-builder@spira.local 'feat: sp-one — first' "$OLD"
commit alpha main aeon-builder aeon-builder@spira.local 'feat: sp-two — second' '2026-08-02T00:00:00+0000'
W="$(cut window)"
want "the window starts at the EARLIEST aeon commit" '2026-08-01T00:00:00' "$W"

commit alpha main the operator dev@example.invalid 'chore: a human commit' '2026-08-03T00:00:00+0000'
commit beta master pipboy dev@example.invalid 'M-fix: something (pd-mt57)' '2026-08-03T00:00:00+0000'
commit beta master nobody nobody@example.com 'WIP: checkpoint' '2026-08-03T00:00:00+0000'
# A polecat name is derived from the graph, never from a list here: reap the directory and the
# roster read from disk would shrink, silently reclassifying last week's work as `other`.
git -C "$WS/beta" branch -q "polecat/pipboy/pd-mt57"

P="$(cut report)"
wantr "a probed repository that landed nothing shows 0"   'gamma gitea/master 0 0 0 0' "$P"
nowantr "a quiet repository is not reported as unreadable" 'gamma ?' "$P"
wantr "a probe that could not run shows ?"                 'delta ? ? ? ? ?' "$P"
want  "and says why"                                       'no landing ref' "$P"
wantr "the derived roster classifies the polecat"          'beta origin/master 0 1 0 1' "$P"
want "an unclassified author is named in the report"      'unclassified   nobody (1)' "$P"
want "the bar actually used is printed"                   'bar      spira >= 1.00 x gastown' "$P"

# A merge commit is the refinery landing a polecat's work on top of that same work. Counting
# both inflates Gas Town by its own merge rate — the exact number under scrutiny.
git -C "$WS/beta" checkout -q -b side
GIT_AUTHOR_DATE='2026-08-04T00:00:00+0000' GIT_COMMITTER_DATE='2026-08-04T00:00:00+0000' \
    git -C "$WS/beta" commit -q --allow-empty --author='pipboy <dev@example.invalid>' -m 'side work (pd-zzz)'
git -C "$WS/beta" checkout -q master
GIT_AUTHOR_DATE='2026-08-04T00:00:00+0000' GIT_COMMITTER_DATE='2026-08-04T00:00:00+0000' \
    git -C "$WS/beta" -c user.name=beta/refinery -c user.email=r@r merge -q --no-ff --no-edit -m 'Merge polecat/pipboy/pd-zzz' side
git -C "$WS/beta" push -q origin master && git -C "$WS/beta" fetch -q --prune
M="$(cut report)"
wantr "the polecat's own commit counts" 'beta origin/master 0 2 0 1' "$M"
nowant "the refinery's merge does not" 'beta/refinery' "$M"

# ---------------------------------------------------------------------------------------
# The verdict. A probe that could not run must block it even when Spira is winning — which is
# the case where the temptation to round `?` down to 0 is strongest.
# ---------------------------------------------------------------------------------------
V="$(cut verdict --window-days 7)"; rc=$?
eq   "an unreadable repository blocks the verdict" 1 "$rc"
want "and says so rather than deciding"            'UNDECIDED: at least one repository rendered ?' "$V"

# Remove both unreadable rigs and the world becomes decidable.
rm -rf "$TOWN/delta" "$TOWN/ghost"

V2="$(cut verdict --window-days 7)"; rc2=$?
eq   "spira 2 vs gastown 2 with 1 unknown is undecided" 1 "$rc2"
want "and the undecided reason names the count"         'UNDECIDED: 1 unclassified commits decide it' "$V2"

commit alpha main aeon-builder aeon-builder@spira.local 'feat: sp-three' '2026-08-04T00:00:00+0000'
commit alpha main aeon-builder aeon-builder@spira.local 'feat: sp-four' '2026-08-04T00:00:00+0000'
V3="$(cut verdict --window-days 7)"; rc3=$?
eq   "spira 4 vs gastown 2 + 1 unknown crosses over" 0 "$rc3"
want "and says it holds even against the unknowns"   'holds even if all 1 unclassified' "$V3"

# A window that has not closed yet is NOT YET, whatever the numbers say. The measurement is a
# week by construction; a crossover on day one is a sample, not a result.
V4="$(cut verdict --window-days 3650)"; rc4=$?
eq   "an open window is never a verdict"  1 "$rc4"
want "and it names the closing date"      'NOT YET: the window closes' "$V4"

# Gas Town winning outright must be reported as a refusal, not as a silence.
for i in 1 2 3 4 5 6; do
    commit beta master pipboy dev@example.invalid "M-fix: more work $i (pd-mt57)" '2026-08-05T00:00:00+0000'
done
V5="$(cut verdict --window-days 7)"; rc5=$?
eq   "gas town ahead is NO CROSSOVER" 1 "$rc5"
want "and it is stated, not implied"  'NO CROSSOVER' "$V5"

# ---------------------------------------------------------------------------------------
# A failed prefix probe must not become "no beads landed". The beads line is secondary, but a
# secondary number reported as a confident zero is still a lie.
# ---------------------------------------------------------------------------------------
touch "$TMP/pfail"
PF="$(PFAIL="$TMP/pfail" cut report)"
wantr "a failed id probe reports 0 distinct beads, from an empty set" 'beads landed spira 0' "$PF"

# ---------------------------------------------------------------------------------------
# The fence. Two tokens in this program would silently break the measurement, and both fail
# quietly for as long as nobody re-reads the source.
# ---------------------------------------------------------------------------------------
src="$(cat "$HERE/cutover.sh")"
nowant "no hardcoded origin/main outside the resolver" 'origin/main"' "${src//landing_ref/}"
# `git log ... | head -1` returns 141 under pipefail when head closes the pipe, so the window
# start would fail exactly when it succeeded (law-no-grep-q-under-pipefail).
code="$(sed -e 's/#.*//' <<< "$src")"
nowant "no head -1 or grep -q on a git log pipeline" 'git log' \
    "$(grep -E 'git .*log[^|]*\| *(head|grep -q)' <<< "$code")"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
