#!/usr/bin/env bash
#
# test-watchd.sh — the watcher manifest, and what `install.sh` does with it.
#
#   ./test-watchd.sh
#
# WHAT IT HOLDS. The manifest is the single source of truth for what should be watching, and
# every failure this suite guards was a way for that claim to be quietly false:
#
#   1. A MALFORMED ROW IS REFUSED, NOT SKIPPED. Every bad fixture here also carries a good
#      row, and the parser must emit NOTHING — because a parser that returns the rows it
#      liked lets the install enable a partial set and report success, and a watcher that
#      was never started looks exactly like a watcher with nothing to say.
#   2. `daemon` AND `log` ARE DIFFERENT THINGS. A daemon row is a process we own and one
#      unit; a log row names a file something else writes, and a unit for it would double
#      up whatever is already producing it.
#   3. NO PATH IS IN A UNIT. Every path in the rendered unit must lie under a value that
#      came from configuration, which is checked against a config pinned to NON-DEFAULTS —
#      asserting against the shipped default passes just as well if the literal is written
#      in, which is the thing the key exists to prevent.
#   4. THE INSTALL IS DRIVEN BY THE MANIFEST. Exactly one instance per daemon row, none for
#      a log row, an instance whose row has gone is disabled, and a manifest that does not
#      parse installs nothing at all.
#
# It needs no database and no beads server: everything here is a file, a renderer and a
# stub `systemctl` that records what it was asked to do.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        got: %s\n' "$1" "$2"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

# A harness tree that is NOT this checkout, so nothing here can read the operator's own
# configuration and report a pass it did not earn.
CLONE="$TMP/clone"
mkdir -p "$CLONE/spira" "$CLONE/cockpit"
cp "$HERE/conf.sh" "$HERE/watchd.sh" "$CLONE/spira/"
cp -r "$ROOT/systemd" "$CLONE/systemd"

# EVERY CONFIGURED VALUE IS PINNED TO A NON-DEFAULT. SPIRA_COCKPIT would derive to
# $CLONE/cockpit and SPIRA_RUN to $CLONE/.runtime/spira; both are moved somewhere unrelated,
# so a literal written into the manifest parser or into the unit template cannot pass.
COCKPIT="$TMP/elsewhere/cockpit"; RUN="$TMP/elsewhere/run"
mkdir -p "$COCKPIT" "$RUN"
printf '#!/bin/sh\nsleep 3600\n' > "$COCKPIT/watch-answers.sh"; chmod +x "$COCKPIT/watch-answers.sh"
CONF="$TMP/spira.conf"
cat > "$CONF" <<EOF
SPIRA_COCKPIT = $COCKPIT
SPIRA_RUN = $RUN
EOF

# wd <manifest> <args...> — run the dispatcher against one manifest, in a minimal
# environment. The operator's own config file can never be reached from here.
wd() {
    local m="$1"; shift
    env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$CONF" SPIRA_WATCHERS="$m" \
        bash "$CLONE/spira/watchd.sh" "$@"
}

GOOD="$TMP/good"
cat > "$GOOD" <<'EOF'
# a comment, and a blank line follow

good|daemon|@SPIRA_COCKPIT@/watch-answers.sh|/bin/true
cron|log|@SPIRA_RUN@/somebody-elses.log
spaced | daemon | /bin/sleep 3600 |
piped|daemon|/bin/true|/bin/echo a | /bin/grep a
EOF

echo "the manifest parses — the positive control"
# A CHECK THAT FINDS NOTHING MUST FIRST PROVE IT COULD HAVE FOUND SOMETHING. Every rejection
# below is believable only because this passes first: the parser can read a manifest, so a
# silent refusal later is about the row and not about the parser
# (law-absence-needs-a-positive-control).
out="$(wd "$GOOD" manifest 2>"$TMP/err")"; rc=$?
is "a well-formed manifest is accepted"            "0" "$rc"
is "and every row comes back" "4" "$(printf '%s\n' "$out" | grep -c '|' || true)"
has "a placeholder resolves from configuration"    "$out" "good|daemon|$COCKPIT/watch-answers.sh|/bin/true"
has "and does so for a log row too"                "$out" "cron|log|$RUN/somebody-elses.log|"
has "whitespace around every field is trimmed"     "$out" "spaced|daemon|/bin/sleep 3600|"
# The health command is the LAST field precisely so it may contain a pipe: it is a command
# line, and a health check that could not be a pipeline would be a check of the easy half.
has "a health command may contain a pipe"          "$out" "piped|daemon|/bin/true|/bin/echo a | /bin/grep a"
is "nothing is said on stderr about a good file"   "" "$(cat "$TMP/err")"

echo
echo "daemon and log are different things"
out="$(wd "$GOOD" units)"; rc=$?
is "units exits clean"                    "0" "$rc"
has "a daemon row renders an instance"    "$out" "spira-watch@good.service"
has "and so does the second one"          "$out" "spira-watch@spaced.service"
# THE ACCEPTANCE CRITERION. Something else already writes that log; a unit here would run a
# second copy of whatever is producing it.
hasnt "a log row renders no unit"         "$out" "cron"
is "exactly one instance per daemon row"  "3" "$(printf '%s\n' "$out" | grep -c '^spira-watch@' || true)"

echo
echo "a malformed row is REFUSED, and the whole file with it"
# Each fixture is the good row plus ONE offender. The assertion that matters is that stdout
# is empty: refusing names the fault, skipping would hand back the good row and let the
# install enable a partial set while reporting success.
refuses() {              # refuses <label> <offending row> <expected phrase>
    local label="$1" row="$2" want="$3" m="$TMP/bad"
    printf 'good|daemon|/bin/true\n%s\n' "$row" > "$m"
    local out err rc
    out="$(wd "$m" manifest 2>"$TMP/e")"; rc=$?; err="$(cat "$TMP/e")"
    if [ "$rc" = 0 ]; then bad "$label is refused" "exit 0"; return; fi
    if [ -n "$out" ]; then bad "$label refuses the WHOLE file" "emitted: $out"; return; fi
    case "$err" in *"$want"*) ;; *) bad "$label is named" "$err"; return ;; esac
    case "$err" in *":2:"*) ;; *) bad "$label names its line number" "$err"; return ;; esac
    ok "$label"
}
refuses "too few fields"              'two|fields'                    'expected name|kind|target'
refuses "a space in the name"          'bad name|daemon|/bin/true'     'not a usable watcher name'
refuses "a slash in the name"          'a/b|daemon|/bin/true'          'not a usable watcher name'
refuses "an unknown kind"              'x|weird|/bin/true'             'is not a kind'
refuses "a target that stops after the kind" 'x|daemon|'               'expected name|kind|target'
refuses "a target that is only whitespace"   'x|daemon|   |/bin/true'   'has no target'
# A relative target resolves against `/` under systemd, which either fails at the worst
# moment or finds something else entirely.
refuses "a relative target"            'x|daemon|relative/watch.sh'    'must be an absolute path'
refuses "an unknown placeholder"       'x|daemon|@NOPE@/y'             'unknown placeholder @NOPE@'
# THE ONE THAT LOOKS HARMLESS. SPIRA_TOWN is an optional key that defaults to empty, so
# `@SPIRA_TOWN@/watch.sh` expands to `/watch.sh` — a path that exists on somebody's box and
# is nobody's watcher.
refuses "a placeholder that resolves to empty" 'x|daemon|@SPIRA_TOWN@/y' '@SPIRA_TOWN@ is empty'
refuses "a duplicate name"             'good|daemon|/bin/false'        'already defined above'
refuses "a bad health command"         'x|daemon|/bin/true|@NOPE@ -v'  'health'

# AND THE OFFENDER IS WHAT MADE IT FAIL, not the fixture's shape. The same file without the
# bad row parses, which is what makes every rejection above attributable.
printf 'good|daemon|/bin/true\n' > "$TMP/bad"
is "the fixture minus its offender parses" "0" "$(wd "$TMP/bad" manifest >/dev/null 2>&1; echo $?)"

echo
echo "an absent or empty manifest says so rather than reading as none"
out="$(wd "$TMP/no-such-file" manifest 2>&1)"; rc=$?
is "a missing manifest is an error"    "1" "$rc"
has "and it names the path it looked at" "$out" "$TMP/no-such-file"
: > "$TMP/empty"
out="$(wd "$TMP/empty" manifest 2>&1)"; rc=$?
is "an empty manifest is not an error"  "0" "$rc"
has "but it is said out loud"           "$out" "defines no watchers"

echo
echo "exec — the dispatcher systemd starts a watcher through"
out="$(wd "$GOOD" exec cron 2>&1)"; rc=$?
is "a log row has nothing to run"      "2" "$rc"
has "and says why"                     "$out" "written by something else"
out="$(wd "$GOOD" exec nope 2>&1)"; rc=$?
is "an unknown name is refused"        "2" "$rc"
has "and names the manifest"           "$out" "$GOOD"
# It becomes the target, with the target's own arguments.
printf 'echo|daemon|/bin/echo watchd-ran-it\n' > "$TMP/echo"
is "a daemon row runs its target"      "watchd-ran-it" "$(wd "$TMP/echo" exec echo 2>/dev/null)"
# AND A MALFORMED MANIFEST RUNS NOTHING. `exec` is the one caller that could act on a
# half-read file, so it must refuse for the same reason the parser does.
printf 'echo|daemon|/usr/bin/touch %s/RAN\nbroken row\n' "$TMP" > "$TMP/echo-bad"
wd "$TMP/echo-bad" exec echo >/dev/null 2>&1; rc=$?
is "a malformed manifest runs nothing"  "1" "$rc"
is "and the target was never reached"   "absent" "$([ -e "$TMP/RAN" ] && echo ran || echo absent)"

echo
echo "the manifest this harness ships"
# The shipped rows are read with no config file at all, so they resolve from the defaults a
# clean clone derives — which is the only reason a clean clone has watchers.
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/none.conf" \
       bash "$HERE/watchd.sh" manifest 2>&1)"; rc=$?
is "it parses"  "0" "$rc"
missing=""
while IFS='|' read -r name kind target health; do
    [ "$kind" = daemon ] || continue
    set -- $target
    [ -x "$1" ] || missing="$missing $name:$1"
done <<< "$out"
is "and every daemon row points at something executable" "" "$missing"

echo
echo "install.sh — what the manifest actually causes"
# A stub systemctl, so the install can be run to completion and then ASKED what it did. The
# real one is not usable here: this suite must not enable a unit on the box it runs on.
STUB="$TMP/stub"; mkdir -p "$STUB"
# The stubs are reached through SPIRA_PATH rather than through PATH: conf.sh REPLACES PATH
# outright, so a directory handed in through the environment is gone before install.sh runs
# anything — which showed up here as the REAL systemctl answering, and an empty log that read
# as "the install enabled nothing".
cat > "$STUB/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/systemctl.log"
case "\$*" in
    *list-unit-files*) cat "$TMP/installed-units" 2>/dev/null ;;
    *is-active*)       echo active ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/loginctl"
chmod +x "$STUB/systemctl" "$STUB/loginctl"

IHOME="$TMP/ihome"; mkdir -p "$IHOME"
: > "$TMP/installed-units"
install_run() {          # install_run <manifest> -> exit code; log in $TMP/systemctl.log
    : > "$TMP/systemctl.log"
    printf 'SPIRA_COCKPIT = %s\nSPIRA_RUN = %s\nSPIRA_WATCHERS = %s\nSPIRA_PATH = %s\n' \
        "$COCKPIT" "$RUN" "$1" "$STUB" > "$TMP/install.conf"
    env -i HOME="$IHOME" PATH="$STUB:$PATH" SPIRA_CONF="$TMP/install.conf" \
        bash "$CLONE/systemd/install.sh" > "$TMP/install.out" 2>&1
}
install_run "$GOOD"; rc=$?
enabled="$(grep -oE 'spira-watch@[A-Za-z0-9_-]+\.service' "$TMP/systemctl.log" | sort -u | tr '\n' ' ')"
is "the install completes"                      "0" "$rc"
# The positive control for the log itself: an install that enabled nothing at all would make
# every "absent" assertion below pass for the wrong reason.
has "the stub recorded the install"             "$(cat "$TMP/systemctl.log")" "daemon-reload"
is "exactly one instance per daemon row, and no more" \
   "spira-watch@good.service spira-watch@piped.service spira-watch@spaced.service " "$enabled"
hasnt "the log row gets no unit"                "$enabled" "cron"
has "and the template itself is installed"      "$(ls "$IHOME/.config/systemd/user")" "spira-watch@.service"
is "the watchers' log directory is made before anything starts" \
   "yes" "$([ -d "$RUN/watchd" ] && echo yes || echo no)"

U="$IHOME/.config/systemd/user/spira-watch@.service"
unit="$(cat "$U")"
hasnt "no placeholder survives into the unit"   "$unit" "@"
has "ExecStart is the dispatcher and the instance" "$unit" "ExecStart=$CLONE/spira/watchd.sh exec %i"
has "stdout appends to the log the cursor indexes" "$unit" "StandardOutput=append:$RUN/watchd/%i.log"
# law-fence-loops-on-shared-hardware: a watcher polls, and this box may be running production
# on the same cores, so it is fenced BEFORE it is enabled.
has "the unit is CPU-fenced"                    "$unit" "CPUQuota="
has "and it is niced"                           "$unit" "Nice="
has "and systemd owns its restarts"             "$unit" "Restart=always"

# NO PATH IS HARDCODED IN THE UNIT. Every absolute path in the rendered file must lie under a
# value that came from the config above — and that config pins both to non-defaults, so a
# literal cannot pass by coincidence.
paths="$(sed 's|file://|file:|' "$U" | grep -oE '[=:]/[^ ]+' | sed 's/^[=:]//')"
is "the path extractor found paths to judge" "yes" "$([ -n "$paths" ] && echo yes || echo no)"
stray=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in "$CLONE/spira"/*|"$RUN"/*) ;; *) stray="$stray $p" ;; esac
done <<< "$paths"
is "and every one of them came from configuration" "" "$stray"

echo
echo "a row that has gone stops running"
# Otherwise the manifest is the source of truth only for what STARTS, and a watcher deleted
# from it goes on polling — and goes on being believed — until somebody reads systemctl
# output they had no reason to read.
printf 'spira-watch@retired.service enabled enabled\nspira-watch@good.service enabled enabled\n' \
    > "$TMP/installed-units"
install_run "$GOOD"
log="$(cat "$TMP/systemctl.log")"
has "an instance with no row is disabled"     "$log" "disable --now spira-watch@retired.service"
hasnt "and one that still has a row is not"   "$log" "disable --now spira-watch@good.service"
: > "$TMP/installed-units"

echo
echo "a manifest that does not parse installs nothing"
printf 'good|daemon|/bin/true\nbroken row\n' > "$TMP/install-bad"
# A HOME THAT HAS NEVER BEEN INSTALLED INTO, so "no unit was rendered" is a fact about this
# run and not a leftover from the successful one above.
IHOME2="$TMP/ihome2"; mkdir -p "$IHOME2"; IHOME="$IHOME2"
install_run "$TMP/install-bad"; rc=$?
out="$(cat "$TMP/install.out")"
is "the install refuses"                      "1" "$rc"
has "and says the manifest is why"            "$out" "watcher manifest is malformed"
hasnt "no watcher instance is enabled"        "$(cat "$TMP/systemctl.log")" "spira-watch@"
# AND NOT A SINGLE UNIT IS WRITTEN. The refusal comes before the render loop, so the outcome
# of a bad manifest is a box exactly as it was, not a half-installed one.
is "and no unit was rendered at all"          "no" \
   "$([ -e "$IHOME2/.config/systemd/user/spira-cockpit.service" ] && echo yes || echo no)"
# NOT EVEN THE UNITS THAT HAVE NOTHING TO DO WITH WATCHERS: the refusal comes before the
# enable loop, so a half-installed box is not one of the outcomes.
hasnt "and nothing else is enabled either"    "$(cat "$TMP/systemctl.log")" "enable --now"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
