#!/usr/bin/env bash
#
# test-conf.sh — the one configuration surface, and the clean-clone acceptance test.
#
#   ./test-conf.sh
#
# WHAT IT HOLDS. Four properties, each of which was a real defect while this was being built:
#
#   1. PRECEDENCE. environment > config file > derived default. Environment first is what
#      keeps every other suite isolated — a suite sets SPIRA_DB to a throwaway database, and
#      a config file that could override it would point the suite at the operator's own.
#   2. THE ALLOWLIST ACTUALLY MATCHES. The key list is written over several lines, and the
#      membership test was a `case` on " $key " — so six of twenty-two keys were followed by
#      a newline rather than a space and were silently refused as unknown. An allowlist that
#      rejects valid keys is worse than none: it fails exactly where it was meant to help.
#   3. A CONFIG FILE IS NOT SHELL. It is read by the process that summons agents.
#   4. THE CLEAN CLONE RUNS. A fresh checkout with no config file at all resolves every path,
#      finds the example repo-map, and names what is missing rather than dying as a shell
#      error. That is the acceptance test for the whole exercise.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        got: %s\n' "$1" "$2"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A harness tree that is NOT this checkout, so nothing here can read the operator's own
# config by accident and report a pass it did not earn.
CLONE="$TMP/clone"
mkdir -p "$CLONE/spira" "$CLONE/cockpit"
cp "$HERE"/conf.sh "$HERE"/lib.sh "$HERE"/doctor.sh "$HERE"/seed.sh "$CLONE/spira/"
cp "$HERE"/repo-map.example "$CLONE/spira/"
cp -r "$HERE"/statutes "$CLONE/spira/" 2>/dev/null
cp "$HERE"/../cockpit/ask.sh "$CLONE/cockpit/" 2>/dev/null
CONF_SH="$CLONE/spira/conf.sh"

# Every probe runs with SPIRA_CONF pointed somewhere explicit and HOME redirected, so the
# operator's ~/.config/spira/spira.conf is never in play.
probe() {                # probe <conf-path> <var> [env assignments...]
    local conf="$1" var="$2"; shift 2
    env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$conf" "$@" \
        bash -c ". '$CONF_SH' 2>/dev/null; printf '%s' \"\${$var:-}\""
}
mkdir -p "$TMP/home"

echo "defaults, with no config file at all"
NONE="$TMP/nonexistent.conf"
is "SPIRA_HOME is where conf.sh sits" "$CLONE/spira" "$(probe "$NONE" SPIRA_HOME)"
is "SPIRA_REPO is the tree above it"  "$CLONE"               "$(probe "$NONE" SPIRA_REPO)"
is "SPIRA_HOME_REPO is its basename"  "clone"                "$(probe "$NONE" SPIRA_HOME_REPO)"
is "SPIRA_COCKPIT is beside the harness" "$CLONE/cockpit" "$(probe "$NONE" SPIRA_COCKPIT)"
# THE DATABASE DEFAULT IS OUTSIDE THE CHECKOUT. A beads database accumulates internal notes
# and agent memories; a default inside a git repository is one `git add -A` from publishing
# them (law-beads-is-never-public).
db="$(probe "$NONE" SPIRA_DB)"
case "$db" in "$CLONE"*) bad "the default database is outside the checkout" "$db" ;;
              *) ok "the default database is outside the checkout" ;; esac
# EVERY OPTIONAL KEY IS EMPTY. Each names something a colleague may not have, and a caller
# must treat empty as "skip", never as "guess".
for k in SPIRA_TOWN SPIRA_MIRROR SPIRA_EXPORTER SPIRA_DESIGN SPIRA_WIKI_HOOK SPIRA_DOLT_DATA; do
    is "$k defaults to empty" "" "$(probe "$NONE" "$k")"
done
# AND THE MAP FALLS BACK TO THE EXAMPLE, which is the whole reason a clean clone resolves.
is "repo-map falls back to the example" "$CLONE/spira/repo-map.example" \
   "$(probe "$NONE" SPIRA_REPO_MAP)"
printf 'x | /x | push | origin/main | |\n' > "$CLONE/spira/repo-map"
is "and prefers a real repo-map once one exists" "$CLONE/spira/repo-map" \
   "$(probe "$NONE" SPIRA_REPO_MAP)"
rm -f "$CLONE/spira/repo-map"

echo
echo "the config file"
CONF="$TMP/spira.conf"
cat > "$CONF" <<'EOF'
# a comment, and a blank line follow

SPIRA_DB = /tmp/some/db
SPIRA_HOME_REPO=tight
SPIRA_GOAL   =   spaced-out
SPIRA_PATH = /opt/one:/opt/two
SPIRA_TOWN = $HOME/town
SPIRA_OPERATOR = "a quoted name"
COCKPIT_BOTTOM_PCT = 41
EOF
is "a plain key"                 "/tmp/some/db"  "$(probe "$CONF" SPIRA_DB)"
is "no spaces around ="          "tight"         "$(probe "$CONF" SPIRA_HOME_REPO)"
is "spaces on both sides"        "spaced-out"    "$(probe "$CONF" SPIRA_GOAL)"
is "\$HOME expands"              "$TMP/home/town" "$(probe "$CONF" SPIRA_TOWN)"
is "quotes are stripped"         "a quoted name" "$(probe "$CONF" SPIRA_OPERATOR)"
is "a COCKPIT_ key is honoured"  "41"            "$(probe "$CONF" COCKPIT_BOTTOM_PCT)"
# EVERY KEY IN THE ALLOWLIST MUST ACTUALLY MATCH IT. This is the regression for the newline
# bug: the list spans lines, and a key at a line boundary was refused as unknown. Driving
# each key through the file one at a time is the only shape that would have caught it.
badkeys=""
for k in $(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$NONE" \
           bash -c ". '$CONF_SH' 2>/dev/null; printf '%s' \"\$SPIRA_CONF_KEYS\""); do
    case "$k" in SPIRA_FAYTHS|SPIRA_MAX_AEONS) continue ;; esac   # not exported; read in-process
    printf '%s = sentinel-value\n' "$k" > "$TMP/one.conf"
    out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/one.conf" \
           bash -c ". '$CONF_SH' 2>&1 >/dev/null")"
    case "$out" in *"unknown key"*) badkeys="$badkeys $k" ;; esac
done
is "every advertised key is accepted by the allowlist" "" "$badkeys"

echo
echo "precedence, and what a config file may not do"
is "the environment beats the file" "/env/wins" \
   "$(probe "$CONF" SPIRA_DB SPIRA_DB=/env/wins)"
# SET-TO-EMPTY IS A REAL ANSWER, not an absent one: an empty SPIRA_TOWN is how an operator
# says they have no predecessor harness, and the file must not fill it back in.
is "an environment value set to EMPTY still beats the file" "" \
   "$(probe "$CONF" SPIRA_TOWN SPIRA_TOWN=)"
# SPIRA_HOME AND SPIRA_REPO ARE NOT SETTABLE FROM A FILE. The landing gate extracts a branch
# to a scratch tree and runs that tree's suites; a config that could point them back at the
# installed copy would make the gate test the code already in force, and pass.
printf 'SPIRA_HOME = /somewhere/else\nSPIRA_REPO = /elsewhere\n' > "$TMP/hijack.conf"
is "a config file cannot move SPIRA_HOME" "$CLONE/spira" "$(probe "$TMP/hijack.conf" SPIRA_HOME)"
is "a config file cannot move SPIRA_REPO" "$CLONE"               "$(probe "$TMP/hijack.conf" SPIRA_REPO)"
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/hijack.conf" \
       bash -c ". '$CONF_SH' 2>&1 >/dev/null")"
has "and says so rather than ignoring it in silence" "$out" "unknown key SPIRA_HOME"
# A VALUE IS NOT SHELL. This file is read by the process that summons agents.
printf 'SPIRA_GOAL = $(touch %s/PWNED)\n' "$TMP" > "$TMP/evil.conf"
probe "$TMP/evil.conf" SPIRA_GOAL >/dev/null
[ -e "$TMP/PWNED" ] && bad "a value is not executed" "the command ran" \
                    || ok "a value is not executed"
printf 'SPIRA_GOAL = `touch %s/PWNED2`\n' "$TMP" > "$TMP/evil2.conf"
probe "$TMP/evil2.conf" SPIRA_GOAL >/dev/null
[ -e "$TMP/PWNED2" ] && bad "nor is a backticked one" "the command ran" \
                     || ok "nor is a backticked one"
# A MALFORMED LINE IS REPORTED AND SURVIVED. A harness that refuses to start over one bad
# line in a config is a harness that cannot be repaired from the box it is broken on.
printf 'this is not a setting\nSPIRA_GOAL = still-read\n' > "$TMP/junk.conf"
is "a malformed line does not stop the rest being read" "still-read" \
   "$(probe "$TMP/junk.conf" SPIRA_GOAL)"
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/junk.conf" \
       bash -c ". '$CONF_SH' 2>&1 >/dev/null")"
has "and is named with its line number" "$out" "spira.conf:1:"

echo
echo "what is exported, and what must not be"
# THE REGRESSION FOR AN ELEVEN-TEST OUTAGE. Anything derived from where conf.sh sits must not
# reach a child: a fixture library sourced by a suite published the live installation's
# SPIRA_HOME into the environment of the program that suite then ran under a temporary one,
# and it read the operator's real repo-map while every log line looked ordinary.
leaked=""
for k in SPIRA_HOME SPIRA_REPO SPIRA_REPO_DERIVED SPIRA_HOME_REPO SPIRA_RUN \
         SPIRA_REPO_MAP SPIRA_PREFIX_MAP SPIRA_CHAMBER SPIRA_COCKPIT SPIRA_PANEL \
         SPIRA_NOTIFY SPIRA_FAYTHS SPIRA_MAX_AEONS; do
    got="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$CONF" \
           bash -c ". '$CONF_SH' 2>/dev/null; env" | grep -c "^$k=" || true)"
    [ "$got" = 0 ] || leaked="$leaked $k"
done
is "no location-derived key is exported" "" "$leaked"
# And the ones that MUST reach a non-shell child, because nothing else carries them there.
missing=""
for k in SPIRA_DB COCKPIT_DB SPIRA_TOWN SPIRA_PATH SPIRA_OPERATOR COCKPIT_BOTTOM_PCT; do
    got="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$CONF" \
           bash -c ". '$CONF_SH' 2>/dev/null; env" | grep -c "^$k=" || true)"
    [ "$got" = 1 ] || missing="$missing $k"
done
is "every key a non-shell child needs is exported" "" "$missing"

echo
echo "PATH"
has "SPIRA_PATH is prepended" "$(probe "$CONF" PATH)" "/opt/one:/opt/two:"
has "and the usual tail is still there" "$(probe "$CONF" PATH)" "/usr/bin"

echo
echo "a missing program is NAMED, not a bare shell error"
# An empty PATH, and bash reached ABSOLUTELY — `env -i PATH=<empty> bash` cannot find bash
# itself, which fails before the code under test runs and reports as the code being silent.
mkdir -p "$TMP/empty-bin"
out="$(env -i HOME="$TMP/home" PATH="$TMP/empty-bin" SPIRA_CONF="$NONE" \
       /bin/bash -c ". '$CONF_SH' 2>/dev/null; spira_require bd git 2>&1")"
has "the program is named"      "$out" "bd"
has "so is what it is for"      "$out" "beads"
has "and the PATH that was searched" "$out" "spira: PATH is"
has "and where to fix it"       "$out" "SPIRA_PATH"

echo
echo "the clean clone — the acceptance test"
# doctor.sh must run to a verdict on a tree with no config, no database and no repo-map, and
# every fault must be a SENTENCE naming what is missing. A harness that fails on a missing
# binary with a bare shell error is not shareable, and that is the whole point of this bead.
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$NONE" \
       bash "$CLONE/spira/doctor.sh" 2>&1)"; rc=$?
is "doctor exits non-zero when the database is absent" "1" "$rc"
has "it names the missing database"    "$out" "has no .beads"
has "and tells you how to create one"  "$out" "bd -C"
has "it notices there is no spira.conf" "$out" "no spira.conf found"
has "and where it looked"               "$out" "XDG_CONFIG_HOME"
has "it warns that the map is the EXAMPLE" "$out" "still reading the EXAMPLE map"
has "it reports the harness location"   "$out" "$CLONE"
hasnt "and it does not read the operator's own database" "$out" "/workspaces"
# --paths is the other half: whatever it decided, it can say so.
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$NONE" \
       bash "$CLONE/spira/doctor.sh" --paths 2>&1)"
has "--paths reports the config file in force" "$out" "config file"
has "and every resolved key"                   "$out" "SPIRA_REPO_MAP"

echo
echo "the shipped examples parse"
# spira.conf.example must be readable BY THE PARSER THAT READS IT. Every key in it is
# commented out, so a fully uncommented copy is what is actually exercised — otherwise the
# example could name a key the allowlist refuses and nothing would notice.
EX="$(cd "$HERE/.." && pwd)/spira.conf.example"
if [ -f "$EX" ]; then
    sed -e 's/^# \([A-Z_][A-Z0-9_]*\) *=/\1 =/' "$EX" | grep -E '^[A-Z_]+ *=' > "$TMP/ex.conf"
    is "spira.conf.example has keys to uncomment" "0" \
       "$([ -s "$TMP/ex.conf" ] && echo 0 || echo 1)"
    out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/ex.conf" \
           bash -c ". '$CONF_SH' 2>&1 >/dev/null")"
    is "and every one of them is a key the parser accepts" "" "$out"
else
    bad "spira.conf.example exists" "not found at $EX"
fi
# repo-map.example must parse as a six-column map, or the fallback that makes a clean clone
# runnable hands the harness a file it cannot read.
badrow=""
for n in $(SPIRA_REPO_MAP="$HERE/repo-map.example" bash -c \
           ". '$CONF_SH'; . '$HERE/lib.sh'; repo_names" 2>/dev/null); do
    b="$(SPIRA_REPO_MAP="$HERE/repo-map.example" bash -c \
         ". '$CONF_SH'; . '$HERE/lib.sh'; repo_field $n base" 2>/dev/null)"
    m="$(SPIRA_REPO_MAP="$HERE/repo-map.example" bash -c \
         ". '$CONF_SH'; . '$HERE/lib.sh'; repo_land $n" 2>/dev/null)"
    case "$b" in ""|*" "*) badrow="$badrow $n:base" ;; esac
    case "$m" in push|pr|hold) ;; *) badrow="$badrow $n:land=$m" ;; esac
done
is "every example row has a land mode and a spaceless base" "" "$badrow"

echo
echo "the seed statutes"
statute_faults=0
for f in "$HERE"/statutes/law-*.txt; do
    [ -f "$f" ] || continue
    k="$(basename "$f" .txt)"
    w="$(wc -w < "$f")"
    # rule.sh refuses over 130 words, so a statute that ships longer than that could never be
    # amended in place by the command that manages statutes.
    [ "$w" -le 130 ] || { bad "$k is one paragraph" "$w words"; statute_faults=1; }
    # AND IT MUST NAME NO INVENTORY. A statute naming a repository, a path or an operator only
    # teaches a colleague's agent to index on someone else's box
    # (law-harness-ships-mechanism-not-inventory).
    hits="$(bash "$HERE/inventory.sh" --scan "$f" | tr '\n' ' ')"
    [ -n "$hits" ] && { bad "$k names no inventory" "$hits"; statute_faults=1; }
done
[ "$statute_faults" -eq 0 ] && ok "every shipped statute is one paragraph and names no inventory"


echo
echo "an explicit SPIRA_HOME owns its own repo-map"
# THE FALLBACK CHAIN IS ORDERED BY WHO ANSWERED. A caller that sets SPIRA_HOME — a fixture,
# or the landing gate's scratch checkout — is naming the tree that IS the harness, so that
# tree's map leads. Derived, the operator's config-dir map leads instead, which is where an
# operator whose harness lives in a repository they did not write keeps theirs.
#
# Unconditional config-dir-first broke four suites at once and none of them said so: every
# fixture plants a map at $SPIRA_HOME/repo-map and reaches it by setting SPIRA_HOME, so all
# of them silently read the operator's REAL seven repositories. The reports were "0
# movements" and "not an ancestor" — landing looking broken, with nothing naming the map.
CFGD="$TMP/cfgdir"; mkdir -p "$CFGD"
printf 'fromconfig | /tmp/x | push | origin/main | |\n' > "$CFGD/repo-map"
: > "$CFGD/spira.conf"
HOMEMAP="$TMP/otherhome"; mkdir -p "$HOMEMAP"
cp "$CONF_SH" "$HOMEMAP/conf.sh"
printf 'fromhome | /tmp/y | push | origin/main | |\n' > "$HOMEMAP/repo-map"
is "an explicit SPIRA_HOME leads with its own map" "$HOMEMAP/repo-map" \
   "$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$CFGD/spira.conf" SPIRA_HOME="$HOMEMAP" \
      bash -c ". '$CONF_SH'; printf '%s' \"\${SPIRA_REPO_MAP:-}\"")"
is "a derived SPIRA_HOME leads with the config dir's" "$CFGD/repo-map" \
   "$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$CFGD/spira.conf" \
      bash -c ". '$HOMEMAP/conf.sh'; printf '%s' \"\${SPIRA_REPO_MAP:-}\"")"
# And an explicit SPIRA_HOME with no map of its own still falls through to the config dir,
# because that is production: the aeon is handed SPIRA_HOME by the sentinel, and the
# installed tree ships no map — only the example.
rm -f "$HOMEMAP/repo-map"
is "and falls through when that tree has no map" "$CFGD/repo-map" \
   "$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$CFGD/spira.conf" SPIRA_HOME="$HOMEMAP" \
      bash -c ". '$CONF_SH'; printf '%s' \"\${SPIRA_REPO_MAP:-}\"")"

echo
echo "what git SHIPS is what the boundary says ships"
# THE FENCE ABOVE RUNS OVER FILES ON DISK, and on disk the operator's own repo-map sits
# beside the example — so it was exempted from that fence by name, and being exempted is
# how it stayed TRACKED. The boundary manifest said both spira.conf and repo-map were
# gitignored; only spira.conf was. conf.sh resolves the map config-dir, `$SPIRA_HOME/
# repo-map`, `repo-map.example`, so a tracked map at the middle position is not dead weight
# a colleague ignores — it is the map their clone silently USES, naming seven checkouts
# they do not have. A fixture clone cannot catch this: it is built by copying the files the
# harness is supposed to ship, which is the answer the test is meant to be checking.
# So this asks git, in the real checkout (law-absence-needs-a-positive-control).
# The matcher, as a function, so it can be shown to FIRE before it is believed when silent.
leaks() {                # leaks <newline-separated paths> -> the offenders, if any
    local f out=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "${f##*/}" in
            repo-map|spira.conf|*.pyc) out="$out $f" ;;
        esac
    done <<EOF
$1
EOF
    printf '%s' "$out"
}
# POSITIVE CONTROL, FIRST. A matcher that returns nothing is indistinguishable from a
# matcher pointed at the wrong thing, and "no offenders" is the reading that stops anyone
# looking. Hand it an offender and require it to say so (law-absence-needs-a-positive-control).
is "the leak matcher catches a tracked repo-map" " spira/repo-map" \
   "$(leaks 'spira/repo-map.example
spira/repo-map
spira/conf.sh')"

ROOT="$(cd "$HERE/.." && pwd -P)"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    # THE INDEX, not the worktree and not HEAD: the index is what the next commit ships, and
    # the worktree is where the operator's own untracked map legitimately sits.
    tracked="$(git -C "$ROOT" ls-files)"
    case "$tracked" in
        *repo-map.example*) ok "the tracked-file query resolves a file known to be present" ;;
        *) bad "the tracked-file query resolves a file known to be present" \
               "repo-map.example is absent from ls-files — the query is broken, not the tree" ;;
    esac
    is "no operator map, config or bytecode is tracked" "" "$(leaks "$tracked")"
    # And the ignore rules must cover them, or the next `git add -A` re-adds what was just
    # removed. check-ignore exits 1 when a path is NOT ignored.
    unfenced=""
    for f in spira/repo-map spira/repo-map.local spira.conf; do
        git -C "$ROOT" check-ignore -q "$f" 2>/dev/null || unfenced="$unfenced $f"
    done
    is "and .gitignore fences each of them" "" "$unfenced"
else
    echo "  SKIP  not a git checkout — the shipped-file fence did not run"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
