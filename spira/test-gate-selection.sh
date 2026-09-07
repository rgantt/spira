#!/usr/bin/env bash
#
# test-gate-selection.sh — the landing gate runs the suites the change needs, and errs wide.
#
#   ./test-gate-selection.sh
#
# WHAT IS BEING PROTECTED IS NOT THE SPEED, IT IS THE WIDENING. Selecting suites from the
# changed files makes the gate cheap; the only way it can be WRONG is by running too few, and
# that failure is green. Nothing downstream reports it: the branch passes, the bead closes,
# the commit lands, and the suite that would have caught the defect was never invoked. So
# almost every case here asserts that some input selects EVERYTHING — a shared file, a path
# no suite claims, a file list that could not be read — and the handful asserting a narrow
# selection each also prove the same call can go wide, because a selector that always returned
# every suite would satisfy the first group silently
# (law-absence-needs-a-positive-control).
#
# TWO FIXTURES, DELIBERATELY. A synthetic tree of two-line suites drives the RULES, where
# every glob and every path is pinned to a value the real map does not contain — asserting
# against `spira/landing.sh` alone passes just as well if the rule were written as a literal.
# The real tree then drives the MAP, because the map is a claim about this repository and a
# model of it would be a second copy that agrees with itself.
#
# The end-to-end cases run `gate-spira.sh` itself rather than the selector, because the
# wiring between them is where a correct selector still runs everything: the gate is what
# decides to skip the fixture build and the suite loop, and a suite that only tested
# `gate-select.sh` would have passed on every version of this change including the one that
# forgot to use it.
#
# In an explicit, minimal environment: SPIRA_CONF points at a file that does not exist, so
# the operator's real configuration cannot decide an assertion.
#
# covers: spira/gate-select.sh spira/gate-spira.sh spira/gate.sh spira/gate-full.sh spira/test-*.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
same()    { [ "$2" = "$3" ]       && ok "$1" || bad "$1" "wanted [$2], got [$3]"; }
has()     { [[ "$3" == *"$2"* ]]  && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
hasnt()   { [[ "$3" != *"$2"* ]]  && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# `env -i` on every invocation: what a gate may see is exactly what it is handed.
sel() {                 # sel <tree> <changed path>... -> the selected suites, one per line
    local tree="$1"; shift
    printf '%s\n' "$@" > "$T/files"
    ( cd "$tree" && env -i PATH="$PATH" HOME="$HOME" SPIRA_CONF="$T/nonexistent.conf" \
        bash spira/gate-select.sh "$T/files" 2>/dev/null )
}
count() { printf '%s' "$1" | grep -c . ; }

# =======================================================================================
# THE RULES, against a synthetic tree.
#
# Every name here is one the real repository does not use, so a rule accidentally written as
# a literal — `spira/landing.sh` rather than "whatever the covers line said" — fails.
# =======================================================================================
F="$T/fixture"
mkdir -p "$F/spira/widget" "$F/spira/codex" "$F/docs"
cp "$ROOT/spira/gate-select.sh" "$F/spira/gate-select.sh"

mkstub() {              # mkstub <name> <covers globs>
    cat > "$F/spira/test-$1.sh" <<EOF
#!/usr/bin/env bash
# covers: $2
set -uo pipefail
echo "ran test-$1" >> "\${GATE_RAN:-/dev/null}"
EOF
}
mkstub zither  'spira/zither.sh spira/widget/*'
mkstub quokka  'spira/quokka.py'
mkstub tessera 'docs/tessera.txt'
mkstub vellum  'spira/codex/*'
ALL=4

out="$(sel "$F" spira/zither.sh)"
same "a claimed file selects only the suites claiming it" "spira/test-zither.sh" "$out"

out="$(sel "$F" spira/widget/deep/thing.conf)"
same "a covers glob matches through directories" "spira/test-zither.sh" "$out"

# Named, not counted against $ALL: a count expressed as an offset from the number of stubs
# silently becomes an assertion about the fixture's size the moment one is added.
out="$(sel "$F" spira/quokka.py spira/zither.sh)"
has  "two files select the union — first"  "spira/test-quokka.sh" "$out"
has  "two files select the union — second" "spira/test-zither.sh" "$out"
same "and nothing else"                    "2" "$(count "$out")"

# --- the four ways to select everything ------------------------------------------------
for shared in spira/lib.sh spira/conf.sh spira/testdb.sh spira/gate.sh spira/gate-spira.sh; do
    out="$(sel "$F" "$shared")"
    same "$shared is shared — selects every suite" "$ALL" "$(count "$out")"
done

out="$(sel "$F" spira/never-heard-of-it.sh)"
same "a path no suite claims selects every suite" "$ALL" "$(count "$out")"

out="$(sel "$F" spira/quokka.py spira/never-heard-of-it.sh)"
same "one unclaimed path widens a narrow selection" "$ALL" "$(count "$out")"

: > "$T/files"
out="$( cd "$F" && env -i PATH="$PATH" HOME="$HOME" bash spira/gate-select.sh "$T/files" 2>/dev/null )"
same "an EMPTY changed-file list selects every suite" "$ALL" "$(count "$out")"

out="$( cd "$F" && env -i PATH="$PATH" HOME="$HOME" bash spira/gate-select.sh "$T/no-such-list" 2>/dev/null )"
same "an UNREADABLE changed-file list selects every suite" "$ALL" "$(count "$out")"

out="$( cd "$F" && env -i PATH="$PATH" HOME="$HOME" bash spira/gate-select.sh 2>/dev/null )"
same "no argument at all selects every suite" "$ALL" "$(count "$out")"

# --- the one way to select nothing -----------------------------------------------------
out="$(sel "$F" README.md docs/notes.md .gitignore)"
same "prose and the ignore file select NO suite" "" "$out"

# A file that only LOOKS inert. The inert list is spelled out rather than inferred from a
# directory, and this is why: `docs/tessera.txt` sits beside prose and is covered.
out="$(sel "$F" docs/tessera.txt)"
same "an inert-looking directory does not make its contents inert" "spira/test-tessera.sh" "$out"

out="$(sel "$F" spira/test-quokka.sh)"
same "a suite covers itself without saying so" "spira/test-quokka.sh" "$out"

# PROSE A SUITE CLAIMS IS NOT INERT. An extension is a guess about whether a file can change
# behaviour; a `# covers:` glob naming it is a statement that it does, and the statement wins.
# Ordered the other way this is silent and GREEN, which is why it is asserted from both sides
# here and again against the real map below: the personas an aeon is executed with are `.md`
# files claimed by eleven suites, and they selected none of them.
out="$(sel "$F" spira/codex/persona.md)"
same "prose a suite CLAIMS selects that suite" "spira/test-vellum.sh" "$out"

out="$(sel "$F" spira/codex/persona.md README.md)"
same "unclaimed prose beside it adds nothing" "spira/test-vellum.sh" "$out"

# The positive control for the pair above: inert still decides the files nobody claims, so
# "claimed prose runs suites" has not simply become "prose runs suites".
out="$(sel "$F" spira/codex.md)"
same "prose no suite claims still selects nothing" "" "$out"

# --- --lint, proved in BOTH directions -------------------------------------------------
( cd "$F" && env -i PATH="$PATH" HOME="$HOME" bash spira/gate-select.sh --lint >/dev/null 2>&1 )
same "--lint is green when every suite declares its covers" "0" "$?"

cat > "$F/spira/test-undeclared.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
EOF
lintout="$( cd "$F" && env -i PATH="$PATH" HOME="$HOME" bash spira/gate-select.sh --lint 2>&1 )"; rc=$?
same "--lint REFUSES a suite with no covers line"  "1" "$rc"
has  "--lint names the offending suite" "test-undeclared.sh" "$lintout"
rm -f "$F/spira/test-undeclared.sh"

# =======================================================================================
# THE MAP, against the real repository. These are claims about THIS tree, so a fixture would
# only be a second copy of the map agreeing with itself.
# =======================================================================================
( cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" bash spira/gate-select.sh --lint >/dev/null 2>&1 )
same "every suite in this repository declares what it covers" "0" "$?"

NSUITES="$(ls "$ROOT"/spira/test-*.sh | wc -l)"

out="$(sel "$ROOT" spira/landing.sh)"
has   "landing.sh selects the landing suite" "spira/test-landing.sh" "$out"
has   "landing.sh selects the sentinel suite that dispatches it" "spira/test-sentinel.sh" "$out"
[ "$(count "$out")" -lt "$NSUITES" ] \
    && ok "landing.sh does NOT select every suite" \
    || bad "landing.sh does NOT select every suite" "selected all $NSUITES"

out="$(sel "$ROOT" README.md)"
same "a README edit selects no suite in this repository" "" "$out"

out="$(sel "$ROOT" spira/lib.sh)"
same "lib.sh selects every suite in this repository" "$NSUITES" "$(count "$out")"

# A persona is the brief an aeon is actually executed with, and it is a `.md` file. In this
# repository the chamber is claimed by eleven suites, so the number that must never appear
# here is zero.
out="$(sel "$ROOT" spira/chamber/builder.md)"
has  "a persona selects the suites claiming the chamber" "spira/test-fayth.sh" "$out"
[ "$(count "$out")" -gt 1 ] \
    && ok "a persona selects more than one of them" \
    || bad "a persona selects more than one of them" "selected [$out]"
[ "$(count "$out")" -lt "$NSUITES" ] \
    && ok "and not every suite in this repository" \
    || bad "and not every suite in this repository" "selected all $NSUITES"

# The positive control for the two narrow cases above: the same call against the same tree
# CAN return everything, so "selected few" is a verdict rather than a broken matcher.
out="$(sel "$ROOT" spira/a-file-that-does-not-exist.sh)"
same "an unclaimed path selects every suite in this repository" "$NSUITES" "$(count "$out")"

# =======================================================================================
# THE WIRING, end to end through gate-spira.sh.
#
# The tree carries no testdb.sh, so the gate takes its own "could not build a shared fixture"
# path and the suites build nothing — the real branch, not a stub of it. What is under test is
# which suites the gate INVOKES, and each stub records that it ran.
# =======================================================================================
G="$T/gatetree"
mkdir -p "$G/spira/widget"
cp "$ROOT/spira/gate-select.sh" "$ROOT/spira/gate-spira.sh" "$G/spira/"
# The two publication fences are the tree's own, stubbed to pass: they scan every file and
# have their own suites, and what is being asserted here is the selection around them.
printf '#!/usr/bin/env bash\nexit 0\n' > "$G/spira/exclude.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$G/spira/inventory.sh"
F="$G"; mkstub zither 'spira/zither.sh spira/widget/*'; mkstub quokka 'spira/quokka.py'
printf 'prose\n' > "$G/README.md"

# The exit status goes through a FILE, not a variable. `out="$(rungate ...)"` runs the
# function in a subshell, so anything it assigns is gone by the time the caller reads it —
# and an unset status reads as whatever the last unrelated command left behind.
rungate() {             # rungate <changed path>... -> what ran, one suite per line
    printf '%s\n' "$@" > "$T/gfiles"
    : > "$T/ran"
    ( cd "$G" && env -i PATH="$PATH" HOME="$HOME" GATE_RAN="$T/ran" \
        SPIRA_GATE_FILES="$T/gfiles" bash spira/gate-spira.sh >/dev/null 2>&1 )
    printf '%s' "$?" > "$T/rc"
    cat "$T/ran"
}
gate_rc() { cat "$T/rc"; }

out="$(rungate spira/zither.sh)"
same "the gate runs only the selected suite" "ran test-zither" "$out"
same "and passes"                            "0" "$(gate_rc)"

out="$(rungate README.md)"
same "a docs-only change runs NO suite at all" "" "$out"
same "and still passes"                        "0" "$(gate_rc)"

out="$(rungate spira/lib.sh)"
same "a shared file runs every suite" "2" "$(count "$out")"

out="$(rungate spira/brand-new.sh)"
same "an unclaimed new file runs every suite" "2" "$(count "$out")"

# SPIRA_GATE_ALL overrides the selection. This is the seam gate-full.sh uses, and a gate that
# ignored it would leave the daily full run silently selecting from an empty file list.
: > "$T/ran"
printf 'README.md\n' > "$T/gfiles"
( cd "$G" && env -i PATH="$PATH" HOME="$HOME" GATE_RAN="$T/ran" SPIRA_GATE_ALL=1 \
    SPIRA_GATE_FILES="$T/gfiles" bash spira/gate-spira.sh >/dev/null 2>&1 )
same "SPIRA_GATE_ALL=1 runs every suite whatever changed" "2" "$(count "$(cat "$T/ran")")"

# THE GATE ITSELF REFUSES AN UNDECLARED SUITE. Without this the map decays in the direction
# nobody sees: a suite claiming nothing runs only when something else forces a full pass, and
# it looks exactly like a suite that is passing.
cat > "$G/spira/test-undeclared.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
EOF
printf 'README.md\n' > "$T/gfiles"
gout="$( cd "$G" && env -i PATH="$PATH" HOME="$HOME" SPIRA_GATE_FILES="$T/gfiles" \
    bash spira/gate-spira.sh 2>&1 )"; rc=$?
same "the gate REFUSES a branch whose suite declares no covers" "1" "$rc"
has  "and says which suite"  "test-undeclared.sh" "$gout"
rm -f "$G/spira/test-undeclared.sh"

# And it fails closed on the selector's absence, for the same reason the publication fences
# do: a missing selector cannot narrow anything, but nothing else here would notice it gone.
mv "$G/spira/gate-select.sh" "$T/parked"
gout="$( cd "$G" && env -i PATH="$PATH" HOME="$HOME" SPIRA_GATE_FILES="$T/gfiles" \
    bash spira/gate-spira.sh 2>&1 )"; rc=$?
same "the gate refuses a branch with no selector" "1" "$rc"
has  "and names it" "gate-select.sh is missing" "$gout"
mv "$T/parked" "$G/spira/gate-select.sh"

# =======================================================================================
# THE METER. The selection is only safe because something else runs the WHOLE set against the
# base ref on a timer, so a hole in the covers map surfaces within a day rather than never.
# That meter is the half of this change that is easy to ship broken and never notice: a
# gate-full.sh that silently exited 0 would look exactly like a map with no holes in it.
#
# Against real git repositories in a temp directory, with the gate command supplied by a
# fixture repo-map — what is under test is what gate-full does with a verdict, not how one is
# reached, and every path here is pinned to a non-default so a literal would fail.
# =======================================================================================
FULLREPO="$T/fullrepo"
git init -q "$FULLREPO"
git -C "$FULLREPO" config user.email spira@example.invalid
git -C "$FULLREPO" config user.name spira-test
echo prose > "$FULLREPO/README.md"
git -C "$FULLREPO" add -A >/dev/null 2>&1
git -C "$FULLREPO" commit -qm init >/dev/null 2>&1
# A base ref that is NOT `main` and NOT a remote-tracking ref: the base is declared, never
# guessed, and a repository nothing pushes still has one.
git -C "$FULLREPO" branch -M trunk

# ONE LINE PER ASK, and it records the TITLE rather than the whole invocation: the evidence
# argument is a multi-line block, so counting lines of `$*` counts the finding's own length.
printf '#!/usr/bin/env bash\nprintf "ASK %%s\\n" "$2" >> "$SPIRA_ASK_LOG"\n' > "$T/fake-ask.sh"
chmod +x "$T/fake-ask.sh"

full() {                # full <gate command> [repo-name] -> stdout+stderr; status in $T/rc
    local cmd="$1" name="${2:-fullrepo}"
    printf 'fullrepo | %s | push | trunk |  | %s\n' "$FULLREPO" "$cmd" > "$T/fullmap"
    ( env -i PATH="$PATH" HOME="$HOME" \
        SPIRA_CONF="$T/nonexistent.conf" SPIRA_REPO_MAP="$T/fullmap" \
        SPIRA_RUN="$T/fullrun" SPIRA_HOME_REPO=fullrepo \
        SPIRA_NOTIFY="$T/fake-ask.sh" SPIRA_ASK_LOG="$T/asks" \
        bash "$ROOT/spira/gate-full.sh" "$name" 2>&1 )
    printf '%s' "$?" > "$T/rc"
}
asks() { [ -f "$T/asks" ] && grep -c '^ASK ' "$T/asks" || echo 0; }

out="$(full 'exit 0')"
same "a green full run exits 0"        "0" "$(gate_rc)"
has  "and names the ref it judged"     "trunk" "$out"
same "and escalates nothing"           "0" "$(asks)"

# THE SEAM. gate-full exists to run EVERY suite, and the gate command is what would select
# fewer — so the one thing it must put in that command's environment is the override.
out="$(full 'echo "ALL=[$SPIRA_GATE_ALL] FILES=[${SPIRA_GATE_FILES:-unset}]"; exit 1')"
has "it forces SPIRA_GATE_ALL=1 into the gate command" "ALL=[1]" "$out"
has "and hands it no changed-file list to select from" "FILES=[unset]" "$out"

# The cadence group starts from a clean slate: the seam case above is itself a red run, and
# an escalation count that carried over from it would be asserting about two conditions.
: > "$T/asks"
out="$(full 'echo "the aeon suite is red" >&2; exit 1')"
same "a red full run exits 1"                   "1" "$(gate_rc)"
has  "the finding carries the failing output"   "the aeon suite is red" "$out"
has  "and says no branch can have caused it"    "no branch can" "$out"
has  "and offers the widening as the default"   "covers" "$out"
same "and escalates once"                       "1" "$(asks)"

full 'echo "the aeon suite is red" >&2; exit 1' >/dev/null
same "the SAME finding does not escalate again" "1" "$(asks)"

full 'echo "the sentinel suite is red" >&2; exit 1' >/dev/null
same "a CHANGED finding does escalate again"    "2" "$(asks)"

# COULD NOT CHECK IS NOT A PASS, in either of its two shapes.
out="$(full 'exit 0' nosuchrepo)"
same "an unmapped repository exits 3"           "3" "$(gate_rc)"
same "and escalates nothing"                    "2" "$(asks)"

out="$(full '')"
same "a repository declaring no gate exits 3"   "3" "$(gate_rc)"
has  "and says so rather than reporting a pass" "no gate of its own" "$out"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
