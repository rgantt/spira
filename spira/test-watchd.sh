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
missing=""; nohealth=""; unrunnable=""
while IFS='|' read -r name kind target health; do
    if [ "$kind" = daemon ]; then
        set -- $target
        [ -x "$1" ] || missing="$missing $name:$1"
    fi
    # A SHIPPED ROW WITH NO ASSERTION IS A WATCHER JUDGED ON ITS UNIT STATE ALONE, which cannot
    # tell a quiet watcher from a blind one — the exact hole this whole column exists to close.
    # A row may legitimately have none; a row this harness ships may not.
    if [ -z "$health" ]; then nohealth="$nohealth $name"; else
        set -- $health
        [ -x "$1" ] || unrunnable="$unrunnable $name:$1"
    fi
done <<< "$out"
is "and every daemon row points at something executable" "" "$missing"
is "every shipped row carries a health assertion"        "" "$nohealth"
is "and every one of them can actually be run"           "" "$unrunnable"

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

echo
echo "there is no second supervision scheme"
# THE ACCEPTANCE CRITERION, AND A CHECK THAT MUST FIRST PROVE IT CAN FIND SOMETHING. systemd
# owns every watcher process; if this script could also detach one, write down its pid and
# decide from that pid whether it is alive, there would be two answers to "is it running" and
# nothing to say which is authoritative. That is the shape of the defect all of this exists to
# fix — a watcher looked alive in every process listing for three days while reading a database
# that had been retired underneath it.
SUPERVISION='nohup|setsid|kill -0|\.pid\b|pidfile'
printf 'nohup setsid bash -c x &\necho $! > /tmp/w.pid\nkill -0 "$pid"\n' > "$TMP/offender.sh"
is "the matcher finds a second scheme when there is one" "3" \
   "$(grep -cE "$SUPERVISION" "$TMP/offender.sh" || true)"
is "and finds none in watchd.sh" "0" "$(grep -cE "$SUPERVISION" "$HERE/watchd.sh" || true)"

echo
echo "the reader's own fixture"
# A SECOND RUNTIME DIRECTORY, pinned to a non-default again, holding logs and cursors that
# nothing above has touched — so every count below is a fact about this section.
WRUN="$TMP/elsewhere/reader"; mkdir -p "$WRUN/watchd"
SCTL="$TMP/sctl"; mkdir -p "$SCTL"
# A STUB systemctl THAT RECORDS WHAT IT WAS ASKED. The real one is not usable: this suite must
# not read, still less restart, a unit on the box it runs on. `is-active` answers one line per
# unit in the order asked, which is the behaviour `status` batches against.
cat > "$SCTL/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/sctl.log"
case "\$1 \$2" in
    "--user is-active")
        shift 2
        down="\$(tr '\n' ' ' < "$TMP/sctl.down" 2>/dev/null)"
        for u in "\$@"; do
            case " \$down " in *" \$u "*) echo inactive ;; *) echo active ;; esac
        done ;;
    "--user restart") exit "\$(cat "$TMP/sctl.rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
chmod +x "$SCTL/systemctl"
: > "$TMP/sctl.down"

# The reading commands go through a config that pins SPIRA_RUN, SPIRA_ACTIONABLE and the stub's
# directory to NON-DEFAULTS. The stub is reached through SPIRA_PATH and not through PATH,
# because conf.sh replaces PATH outright — a directory handed in through the environment is
# gone before watchd.sh runs anything, which showed up once as the REAL systemctl answering.
WCONF="$TMP/reader.conf"
printf 'SPIRA_RUN = %s\nSPIRA_PATH = %s\nSPIRA_ACTIONABLE = %s\n' "$WRUN" "$SCTL" 'NEEDSME' > "$WCONF"

RMAN="$TMP/reader-manifest"
printf 'alpha|daemon|/bin/true|\nbeta|daemon|/bin/true|\nelsewhere|log|%s/somebody-elses.log|\n' \
    "$TMP" > "$RMAN"

# wds <args...> — a reading command, in a minimal environment, against that fixture.
wds() {
    env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$WCONF" SPIRA_WATCHERS="$RMAN" \
        bash "$CLONE/spira/watchd.sh" "$@"
}
# events <file> <n> — n lines, every tenth of them actionable under the pinned expression.
events() {
    local f="$1" n="$2" i
    : > "$f"
    for ((i=1; i<=n; i++)); do
        if [ $(( i % 10 )) -eq 0 ]; then printf 'NEEDSME line %d\n' "$i" >> "$f"
        else printf 'routine line %d\n' "$i" >> "$f"; fi
    done
}
ALOG="$WRUN/watchd/alpha.log"; ACUR="$WRUN/watchd/alpha.cursor"

echo
echo "cursor arithmetic"
events "$ALOG" 300
: > "$TMP/somebody-elses.log"
# COLUMN FOUR, and the table is addressed by index everywhere below:
#   1 NAME  2 UNIT  3 HEALTH  4 UNREAD  5 LAST-EVENT  6 RESTARTS  7 LOG
# which is only safe because every value `status` renders is whitespace-free.
unread() { wds status | awk -v n="$1" '$1==n{print $4}'; }
rm -f "$ACUR"
is "a watcher with no cursor at all has read nothing" "300" "$(unread alpha)"
printf '120\n' > "$ACUR"
is "and a cursor is subtracted from the line count"   "180" "$(unread alpha)"
# EVERY UNREADABLE CURSOR READS AS ZERO, which replays. The other two directions lose events
# or crash the arithmetic, and losing an event is the failure this whole contract exists to
# prevent.
for junk in '' '   ' 'nonsense' '-5' '3.5'; do
    printf '%s\n' "$junk" > "$ACUR"
    is "a cursor of [$junk] reads as none read" "300" "$(unread alpha)"
done
# THE CLAMP. A truncated or rotated log, or a final line still being written, puts the cursor
# past the end; unclamped that is a NEGATIVE unread count rendered as a negative number, and a
# `tail -n +N` starting before the beginning.
printf '900\n' > "$ACUR"
is "a cursor past the end of the log is not negative unread" "0" "$(unread alpha)"
: > "$ALOG"
printf '5\n' > "$ACUR"
is "and neither is a cursor against a log that was emptied" "0" "$(unread alpha)"
events "$ALOG" 300

echo
echo "status — what systemd says, asked once"
: > "$TMP/sctl.log"
printf '0\n' > "$ACUR"
out="$(wds status)"
is "one exec answers for every unit, however many there are" "1" \
   "$(grep -c 'is-active' "$TMP/sctl.log" || true)"
has "and that one call names the first unit"  "$(cat "$TMP/sctl.log")" "spira-watch@alpha.service"
has "and the second in the same call"         "$(cat "$TMP/sctl.log")" "spira-watch@beta.service"
is "a daemon row renders the unit's state" "active" "$(printf '%s\n' "$out" | awk '$1=="alpha"{print $2}')"
printf 'spira-watch@beta.service\n' > "$TMP/sctl.down"
is "and renders it when it is down, too"   "inactive" "$(wds status | awk '$1=="beta"{print $2}')"
: > "$TMP/sctl.down"
# A LOG ROW HAS NO UNIT, so there is nothing to ask systemd and nothing is invented.
is "a log row says who owns it instead"    "external" "$(printf '%s\n' "$out" | awk '$1=="elsewhere"{print $2}')"
has "and its log is the target itself"     "$out" "$TMP/somebody-elses.log"
is "unread is reported against the log"    "300" "$(printf '%s\n' "$out" | awk '$1=="alpha"{print $4}')"
# A WATCHER ENABLED BUT NOT YET STARTED HAS NO LOG, AND THAT IS NOT AN ERROR. `beta` has never
# written one. `wc -l < missing` fails in the SHELL rather than in `wc`, so redirecting the
# command's stderr does not suppress it, and `status` printed one such line per unstarted
# watcher on every pass — into the same stream a session hook reads.
wds status >/dev/null 2>"$TMP/status.err"
is "an unstarted watcher's absent log is silent" "" "$(cat "$TMP/status.err")"
is "and reads as nothing read yet"         "0" "$(wds status | awk '$1=="beta"{print $4}')"
# A FAILED PROBE RENDERS `?`, NEVER A STATE. systemd may not be answering at all — a container,
# a box with no user manager — and a broken check displayed as `inactive` is a fault in the
# checking machinery reported as a finding about the watcher.
NOSCTL="$TMP/nosctl"; mkdir -p "$NOSCTL"
printf 'SPIRA_RUN = %s\nSPIRA_PATH = %s\nSPIRA_ACTIONABLE = %s\n' "$WRUN" "$NOSCTL" 'NEEDSME' \
    > "$TMP/reader-nosctl.conf"
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/reader-nosctl.conf" \
       SPIRA_WATCHERS="$RMAN" bash "$CLONE/spira/watchd.sh" status)"
is "an unanswerable probe is a question mark" "?" "$(printf '%s\n' "$out" | awk '$1=="alpha"{print $2}')"
hasnt "and never a state nobody reported"     "$(printf '%s\n' "$out" | awk '$1=="alpha"{print $2}')" "active"

echo
echo "LAST EVENT — a watcher can be active, healthy and mute"
# THE COLUMN EXISTS BECAUSE THE OTHER TWO CANNOT SEE THIS. A unit that is `active` and a health
# assertion that passes are both true of a watcher that stopped producing days ago; the age of
# its last line is the only thing in the table that notices.
lastev() { wds status | awk -v n="$1" '$1==n{print $5}'; }
touch "$ALOG"
case "$(lastev alpha)" in
    [0-9]*[smhd]) ok "a log that was just written renders a fresh age" ;;
    *) bad "a log that was just written renders a fresh age" "$(lastev alpha)" ;;
esac
# A WATCHER THAT HAS NEVER WRITTEN A LINE RENDERS `-`, NEVER `0s`. `beta` has no log at all,
# and rendering that as an age would make the watcher that has never once emitted look like
# the freshest row in the table — the all-clear that displaces a look.
is "a watcher that has never emitted has no age"  "-" "$(lastev beta)"
touch -d '@1' "$ALOG" 2>/dev/null || touch -t 197001010000 "$ALOG"
case "$(lastev alpha)" in
    *d) ok "an old log renders in days" ;;
    *)  bad "an old log renders in days" "$(lastev alpha)" ;;
esac
# A CLOCK THAT MOVED IS NOT A WATCHER THAT IS UNUSUALLY FRESH. An mtime in the future gives a
# negative age, which would render as a negative number and read as nonsense in a column
# something else parses.
touch -d '@'"$(( $(date +%s) + 86400 ))" "$ALOG" 2>/dev/null
is "a log dated in the future is clamped, not negative" "0s" "$(lastev alpha)"
touch "$ALOG"

echo
echo "the restart meter — the number that says when mtime stops being enough"
# law-take-the-simple-fix-with-a-meter: the staleness check compares MTIME, which is the cheap
# choice and moves for edits that changed nothing. This column is what would make that visible,
# so it has to count restarts that actually happened and nothing else.
meter() { wds status | awk -v n="$1" '$1==n{print $6}'; }
rm -f "$WRUN/watchd/alpha.restarts" "$WRUN/watchd/beta.restarts"
printf '0\n' > "$TMP/sctl.rc"
is "a watcher that has never been restarted reads zero" "0" "$(meter alpha)"
wds restart alpha >/dev/null 2>&1
is "and one restart is one"                            "1" "$(meter alpha)"
wds restart alpha >/dev/null 2>&1
is "and it accumulates"                                "2" "$(meter alpha)"
is "while a watcher nobody restarted stays at zero"    "0" "$(meter beta)"
# A REFUSED RESTART DID NOT HAPPEN. Counting it would charge the staleness heuristic for a
# broken unit, which is the one thing this number exists to be trusted about.
printf '1\n' > "$TMP/sctl.rc"
wds restart alpha >/dev/null 2>&1
is "a restart systemd refused is not counted"          "2" "$(meter alpha)"
printf '0\n' > "$TMP/sctl.rc"
# THERE IS NO UNIT BEHIND A LOG ROW, so there is nothing that could have been restarted. `-`
# rather than `0`, which would assert something was never restarted when nothing could be.
is "a log row has no restart count to give"            "-" "$(meter elsewhere)"
rm -f "$WRUN/watchd/alpha.restarts" "$WRUN/watchd/beta.restarts"

echo
echo "health assertions — telling a blind watcher from a quiet one"
# THE FAILURE THIS WHOLE COLUMN EXISTS FOR. A watcher reading a database that was retired
# underneath it is SILENT, and so is a watcher with nothing to say. A process listing, an
# `is-active` and an unread count agree on both. One here looked healthy in all three for three
# days while seeing nothing at all, and an answer given in the meantime reached nobody.
HCONF="$TMP/health.conf"
# EVERY VALUE PINNED TO A NON-DEFAULT AGAIN, and SPIRA_HEALTH_TIMEOUT and SPIRA_ID_PREFIX most
# of all: asserting against the shipped default passes just as well if the literal is written
# into the code, which is the thing a config key exists to stop.
printf 'SPIRA_RUN = %s\nSPIRA_PATH = %s\nSPIRA_ACTIONABLE = %s\nSPIRA_HEALTH_TIMEOUT = 1\nSPIRA_ID_PREFIX = zz\n' \
    "$WRUN" "$SCTL" 'NEEDSME' > "$HCONF"
HMAN="$TMP/health-manifest"
cat > "$HMAN" <<EOF
sound|daemon|/bin/true|/bin/true
sick|daemon|/bin/true|/bin/false
gone|daemon|/bin/true|/no/such/probe --version
slow|daemon|/bin/true|sleep 30
quiet|daemon|/bin/true|
piped|daemon|/bin/true|printf 'hi\n' | grep -q hi
noisy|daemon|/bin/true|echo LEAKED-TO-STDOUT
EOF
wdh() {
    env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$HCONF" SPIRA_WATCHERS="$HMAN" \
        bash "$CLONE/spira/watchd.sh" "$@"
}
health() { printf '%s\n' "$1" | awk -v n="$2" '$1==n{print $3}'; }
started="$SECONDS"
hout="$(wdh status 2>"$TMP/health.err")"
elapsed=$(( SECONDS - started ))

# THE POSITIVE CONTROL, AND EVERY VERDICT BELOW DEPENDS ON IT. A probe that could never exit 0
# would render DEGRADED everywhere and this section would pass for the wrong reason
# (law-absence-needs-a-positive-control).
is "a probe that exits 0 renders OK"        "OK"       "$(health "$hout" sound)"
is "a probe that exits non-zero is DEGRADED" "DEGRADED" "$(health "$hout" sick)"
# EVERY WAY A PROBE CAN FAIL MEANS THE SAME THING: nothing here proved the watcher can see.
is "a probe that is not there is DEGRADED"  "DEGRADED" "$(health "$hout" gone)"
is "a probe that never returns is DEGRADED" "DEGRADED" "$(health "$hout" slow)"
# AND NONE OF THEM MAY RENDER `OK`, OR `0`, OR NOTHING AT ALL. A broken check displayed as an
# all-clear displaces the suspicion that would have prompted a look, which is the whole shape
# of the incident behind this bead (law-alerts-must-be-actionable).
for w in sick gone slow; do
    got="$(health "$hout" "$w")"
    case "$got" in
        OK|0|'') bad "$w never renders an all-clear" "[$got]" ;;
        *)       ok "$w never renders an all-clear" ;;
    esac
done
# NO ASSERTION IS A THIRD FACT, not a pass. A row with an empty health field was never judged,
# and saying `OK` would claim a check that nobody wrote.
is "a row with no assertion renders a dash"  "-" "$(health "$hout" quiet)"
# A HEALTH COMMAND IS SHELL AND A TARGET IS NOT, which is why the field is last and may hold a
# pipe: the useful assertions are pipelines.
is "a health command may be a pipeline"      "OK" "$(health "$hout" piped)"
# THE PROBE MUST NOT BE ABLE TO WRITE INTO A TABLE SOMETHING ELSE PARSES BY COLUMN.
hasnt "a probe's stdout never reaches the table" "$hout" "LEAKED-TO-STDOUT"
is "and it does not reach stderr either"     "0" "$(grep -c 'LEAKED-TO-STDOUT' "$TMP/health.err" || true)"
# BOUNDED, BECAUSE `status` IS WHAT A SESSION HOOK RUNS. `slow` sleeps 30s against a pinned
# 1s ceiling; unbounded, this assertion is what would hang.
if [ "$elapsed" -lt 20 ]; then ok "a hanging probe cannot hold up status"
else bad "a hanging probe cannot hold up status" "took ${elapsed}s"; fi
# DEGRADED ON ITS OWN SAYS A CHECK FAILED AND NOT WHICH, so the reason is carried with it —
# otherwise the next step is to re-run the probe by hand, which is the work already done here.
has "each degraded watcher is named with its reason" "$hout" "sick:"
has "and the reason carries the exit code"           "$hout" "(exit 1)"
has "and a timeout says so in words"                 "$hout" "timed out after 1s"
hasnt "a healthy watcher is not in the reason block" "$hout" "sound:"

echo
echo "health-ids — absence of OUR ids, never presence of foreign ones"
# THE DISCRIMINATING FACT, and the reason the obvious assertion is wrong. A database here
# legitimately holds beads imported under other prefixes, so a check keyed on "this state names
# something that is not ours" is TRUE of a healthy watcher and would therefore have passed on
# the blind one. What no healthy watcher can do is go a whole state file without naming one
# local bead.
#
# THE FIXTURE IS THE SHAPE OF THE REAL CAPTURE, NOT THE CAPTURE. A watcher's state file is a
# list of the operator's own bead ids, and shipping one would teach a colleague's agent to
# reason about work that does not exist. The two states below differ by exactly one entry, so
# the verdict is attributable to the discriminating fact and to nothing else.
mkstate() {          # mkstate <file> [extra id]
    local f="$1" extra="${2:-}" i pfx sep=""
    {   printf '{'
        for ((i=1; i<=51; i++)); do
            case $(( i % 3 )) in 0) pfx=aa ;; 1) pfx=bb ;; *) pfx=cc ;; esac
            printf '%s"%s-%04x": {"status": "closed", "comments": %d, "insight": false}' \
                   "$sep" "$pfx" "$i" "$(( i % 3 ))"
            sep=', '
        done
        [ -n "$extra" ] && printf '%s"%s": {"status": "closed", "comments": 0, "insight": false}' "$sep" "$extra"
        printf '}\n'
    } > "$f"
}
BLIND="$TMP/state-blind.json"; SEEING="$TMP/state-seeing.json"
mkstate "$BLIND"; mkstate "$SEEING" "zz-0001"
hids() { env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$HCONF" SPIRA_WATCHERS="$HMAN" \
             bash "$CLONE/spira/watchd.sh" health-ids "$@"; }

# WHY A CHECK KEYED ON FOREIGN PREFIXES COULD NOT HAVE CAUGHT THIS: both states name exactly
# the same foreign ids, so any assertion reading them returns the same verdict for the healthy
# state and the blind one. Only the local prefix separates them.
foreign() { grep -oE '"(aa|bb|cc)-[0-9a-f]+"' "$1" | wc -l; }
is "the healthy state names foreign ids too" "$(foreign "$BLIND")" "$(foreign "$SEEING")"
is "a state naming one of our beads passes"  "0" "$(hids "$SEEING" >/dev/null 2>&1; echo $?)"
is "and a state naming none of them fails"   "1" "$(hids "$BLIND" >/dev/null 2>&1; echo $?)"
has "saying which file and which prefix"     "$(hids "$BLIND" 2>&1)" "no zz- id"
# A PREFIX MATCH MUST NOT BE FOUND INSIDE ANOTHER ID. `wzz-1` is not one of ours.
printf '{"wzz-0001": {}}\n' > "$TMP/state-near.json"
is "a prefix inside a longer id does not count" "1" "$(hids "$TMP/state-near.json" >/dev/null 2>&1; echo $?)"
# A STATE FILE THAT IS NOT THERE IS THE SAME BLINDNESS ARRIVING EARLIER — the watcher has never
# completed a pass, or the file moved and the assertion now points at nothing.
is "a state file that does not exist fails"  "1" "$(hids "$TMP/no-state.json" >/dev/null 2>&1; echo $?)"
has "and names the path it looked at"        "$(hids "$TMP/no-state.json" 2>&1)" "$TMP/no-state.json"
# REFUSED RATHER THAN GUESSED. An unusable prefix cannot produce a verdict either way, and
# answering OK when the check could not run is the failure this command was written to end.
# Exit 2, so it is distinguishable from a real DEGRADED.
is "an unusable prefix is refused, not answered" "2" \
   "$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$HCONF" SPIRA_ID_PREFIX='sp-' \
      bash "$CLONE/spira/watchd.sh" health-ids "$SEEING" >/dev/null 2>&1; echo $?)"

echo
echo "and end to end: a watcher pointed at the wrong database reports DEGRADED"
# THE ACCEPTANCE CRITERION, through the whole path a real one takes: a manifest row, the health
# command it names, `status` running it, and the column a session hook reads.
EMAN="$TMP/e2e-manifest"
printf 'seeing|daemon|/bin/true|%s health-ids %s\nblind|daemon|/bin/true|%s health-ids %s\n' \
    "$CLONE/spira/watchd.sh" "$SEEING" "$CLONE/spira/watchd.sh" "$BLIND" > "$EMAN"
eout="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$HCONF" SPIRA_WATCHERS="$EMAN" \
        bash "$CLONE/spira/watchd.sh" status 2>/dev/null)"
is "a watcher reading this database is OK"            "OK"       "$(health "$eout" seeing)"
is "and one reading a database with none of our beads is DEGRADED" \
   "DEGRADED" "$(health "$eout" blind)"
has "with the reason on the report, not in a log"     "$eout"    "blind: $BLIND names no zz- id"

echo
echo "drain filters to actionable, and --all is the escape hatch"
# THE ACCEPTANCE CRITERION, AND THE REASON THIS BEAD EXISTS. `drain` is what a session hook
# advertises into a context window that has just opened. Unfiltered, a real session was offered
# a replay of 283 raw lines as the first thing in it.
printf '0\n' > "$ACUR"
out="$(wds drain alpha)"
is "only the actionable lines are handed over" "30" \
   "$(printf '%s\n' "$out" | grep -c '^NEEDSME' || true)"
is "and nothing else is"                      "0" \
   "$(printf '%s\n' "$out" | grep -c '^routine' || true)"
# BOTH NUMBERS ARE IN THE HEADER. The suppressed lines are the cost of the filter, and a filter
# whose cost is invisible is one nobody can tell has gone wrong.
has "the header says how much was suppressed" "$out" "=== alpha (30 actionable of 300 new) ==="
printf '0\n' > "$ACUR"
out="$(wds drain alpha --all)"
is "--all hands over every line"              "300" \
   "$(printf '%s\n' "$out" | grep -c '^\(routine\|NEEDSME\) line' || true)"
has "and says so without the second number"   "$out" "=== alpha (300 new) ==="

echo
echo "drain advances the cursor exactly once"
printf '0\n' > "$ACUR"
wds drain alpha >/dev/null
is "the cursor lands on the line count"  "300" "$(cat "$ACUR")"
out="$(wds drain alpha)"
is "a second drain hands over nothing"   "" "$out"
is "and does not move the cursor"        "300" "$(cat "$ACUR")"
# THE CURSOR ADVANCES BY WHAT WAS READ, NOT BY WHAT WAS PRINTED. A filtered line has been
# considered and rejected, not missed — and if it stayed unread the hook would go on reporting
# a backlog that no amount of draining could clear.
printf '0\n' > "$ACUR"
printf 'routine only\nnothing to see\n' > "$ALOG"
out="$(wds drain alpha)"
has "a drain with nothing actionable still says what it read" "$out" "(0 actionable of 2 new)"
is "and still marks it read"             "2" "$(cat "$ACUR")"
events "$ALOG" 300

echo
echo "drain, with no watcher named, answers for all of them"
printf '0\n' > "$ACUR"
printf '0\n' > "$WRUN/watchd/beta.cursor"
printf 'NEEDSME from somebody else\n' > "$TMP/somebody-elses.log"
printf '0\n' > "$WRUN/watchd/elsewhere.cursor"
out="$(wds drain)"
has "the daemon row is drained"  "$out" "=== alpha ("
# A `log` ROW IS DRAINED TOO. Its writer is somebody else's; how much of it has been READ is
# ours, and that is the only part a cursor was ever about.
has "and so is the log row"      "$out" "=== elsewhere (1 actionable of 1 new) ==="
is "and its cursor moved"        "1" "$(cat "$WRUN/watchd/elsewhere.cursor")"

echo
echo "the filter is configuration, and an empty one is refused"
# A LITERAL IN TWO COMMANDS IS HOW TWO COMMANDS COME TO DISAGREE — which is exactly what
# happened: `drain` did not filter, `tail` did, and the hook advertised the one that did not.
printf '0\n' > "$ACUR"
is "an operator's own expression decides" "30" \
   "$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$WCONF" SPIRA_WATCHERS="$RMAN" \
      SPIRA_ACTIONABLE='line [0-9]*0$' bash "$CLONE/spira/watchd.sh" drain alpha \
      | grep -c ' line ' || true)"
printf '0\n' > "$ACUR"
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$WCONF" SPIRA_WATCHERS="$RMAN" \
       SPIRA_ACTIONABLE= bash "$CLONE/spira/watchd.sh" drain alpha 2>&1)"; rc=$?
is "an empty expression is refused"       "2" "$rc"
has "and names the way to ask for that"   "$out" "--all"
is "and nothing was marked read"          "0" "$(cat "$ACUR")"
# AND THE SHIPPED DEFAULT ACTUALLY MATCHES WHAT THIS HARNESS'S OWN WATCHER EMITS. A default
# that filtered out every real event would be indistinguishable, from the outside, from a
# watcher with nothing to say.
printf 'OPERATOR ANSWERED sp-1: take your default  --  a title\nroutine progress\nOPERATOR COMMENTED on sp-2 (3 total)  --  a title\n' > "$ALOG"
printf 'SPIRA_RUN = %s\nSPIRA_PATH = %s\n' "$WRUN" "$SCTL" > "$TMP/reader-default.conf"
printf '0\n' > "$ACUR"
out="$(env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$TMP/reader-default.conf" \
       SPIRA_WATCHERS="$RMAN" bash "$CLONE/spira/watchd.sh" drain alpha 2>&1)"
has "the default catches an answered escalation" "$out" "OPERATOR ANSWERED sp-1"
has "and a comment on one"                       "$out" "OPERATOR COMMENTED on sp-2"
hasnt "and not the progress beside them"         "$out" "routine progress"
events "$ALOG" 300

echo
echo "an option that is not one is refused, not taken for a name"
for c in drain tail; do
    out="$(wds "$c" --al 2>&1)"; rc=$?
    is "$c refuses an unknown option"  "2" "$rc"
    has "and quotes it back"           "$out" "--al"
done
out="$(wds drain nosuch 2>&1)"; rc=$?
is "drain refuses a name with no row"  "2" "$rc"
has "and names the manifest it read"   "$out" "$RMAN"
out="$(wds tail 2>&1)"; rc=$?
is "tail without a name says how"      "2" "$rc"
has "and prints the usage"             "$out" "usage: watchd.sh tail"

echo
echo "tail replays what was written while nobody was reading"
# THE INTEGRATION CASE, and outcome 1 of the design's Intent: after a context reset, re-latching
# must replay every event written while nobody was attached, and drop none.
#
# stop_tree kills a reader by PID, children first. NEVER by pattern: `pkill -f` matches any
# command line that merely mentions the string, including this suite's own — which is how a
# `down` once killed the shell that invoked it and then reported the process healthy by
# matching that same shell.
stop_tree() {
    local p="$1" c
    for c in $(pgrep -P "$p" 2>/dev/null); do stop_tree "$c"; done
    kill "$p" 2>/dev/null
}
# read_tail <file> <n> <args...> — attach, wait for n lines, detach.
read_tail() {
    local out="$1" n="$2"; shift 2
    local i tp
    : > "$out"
    wds tail "$@" > "$out" 2>"$TMP/tail.err" &
    tp=$!
    for ((i=0; i<100; i++)); do
        [ "$(wc -l < "$out" 2>/dev/null || echo 0)" -ge "$n" ] && break
        sleep 0.1
    done
    stop_tree "$tp"
    wait "$tp" 2>/dev/null
}
N=300
events "$ALOG" "$N"
printf '0\n' > "$ACUR"
read_tail "$TMP/tail.out" "$N" alpha --all
is "every event written with no reader is replayed" "$N" "$(wc -l < "$TMP/tail.out")"
# AND THE CURSOR MOVED AS IT READ, not at exit — which is what makes the NEXT attach quiet.
# Advancing only on exit would re-fire the whole history on every re-latch, which is the noise
# the filter exists to remove arriving by another route.
is "and the cursor followed the stream"             "$N" "$(cat "$ACUR")"
read_tail "$TMP/tail2.out" 1 alpha --all
is "so re-attaching replays nothing"                "0" "$(wc -l < "$TMP/tail2.out")"
# A LINE WRITTEN WHILE ATTACHED IS STREAMED, which is the half `drain` cannot do and the reason
# `tail` is what a Monitor runs.
: > "$TMP/tail3.out"
wds tail alpha --all > "$TMP/tail3.out" 2>/dev/null &
tp=$!
for ((i=0; i<40; i++)); do [ -s "$TMP/tail3.out" ] && break; sleep 0.1; printf 'NEEDSME live %d\n' "$i" >> "$ALOG"; done
stop_tree "$tp"; wait "$tp" 2>/dev/null
is "a line appended while attached arrives" "yes" \
   "$(grep -q 'NEEDSME live' "$TMP/tail3.out" && echo yes || echo no)"
# AND `tail` FILTERS BY THE SAME EXPRESSION `drain` DOES. The two disagreeing is the defect.
events "$ALOG" "$N"
printf '0\n' > "$ACUR"
read_tail "$TMP/tail4.out" 30 alpha
is "the default is filtered, exactly as drain is" "30" "$(wc -l < "$TMP/tail4.out")"
is "and the cursor still counts every line read"  "$N" "$(cat "$ACUR")"

echo
echo "restart is systemd's to do"
: > "$TMP/sctl.log"
out="$(wds restart 2>"$TMP/restart.err")"; rc=$?
is "restarting all of them exits clean"   "0" "$rc"
# A LOG ROW HAVING NO UNIT IS NOT NEWS WHEN YOU ASKED FOR ALL OF THEM. This runs on a timer as
# well as by hand, and a line of explanation on every pass is the noise that makes a real one
# unreadable (law-alerts-must-be-actionable).
is "and says nothing about the rows it skipped" "" "$(cat "$TMP/restart.err")"
is "in ONE call, whatever the manifest holds" "1" "$(grep -c 'restart' "$TMP/sctl.log" || true)"
has "naming the first daemon row"         "$(cat "$TMP/sctl.log")" "spira-watch@alpha.service"
has "and the second"                      "$(cat "$TMP/sctl.log")" "spira-watch@beta.service"
hasnt "and never the log row"             "$(cat "$TMP/sctl.log")" "elsewhere"
: > "$TMP/sctl.log"
wds restart alpha >/dev/null
log="$(cat "$TMP/sctl.log")"
has "one watcher restarts only itself"    "$log" "spira-watch@alpha.service"
hasnt "and leaves the other alone"        "$log" "beta"
# A LOG ROW NAMED ON ITS OWN IS A REFUSAL, NOT A SKIP. There is no unit, so the caller asked for
# something that cannot happen — and a zero exit would tell them it had.
: > "$TMP/sctl.log"
out="$(wds restart elsewhere 2>&1)"; rc=$?
is "a log row cannot be restarted"        "2" "$rc"
has "and says why"                        "$out" "written by something else"
is "and systemd was never asked"          "" "$(cat "$TMP/sctl.log")"
out="$(wds restart nosuch 2>&1)"; rc=$?
is "an unknown name is refused"           "2" "$rc"
# SYSTEMD'S REFUSAL IS OURS TO REPORT. Reporting a failed restart as done is the shape of every
# defect in this subsystem: a check that says all-clear displaces the look that would find it.
printf '1\n' > "$TMP/sctl.rc"
out="$(wds restart 2>&1)"; rc=$?
is "a refused restart is a failure here too" "1" "$rc"
has "and points at the unit to ask about"    "$out" "systemctl --user status"
printf '0\n' > "$TMP/sctl.rc"

echo
echo "a malformed manifest answers no reading command either"
# `exec` already refuses one. So must every command that reads, for the same reason: half a
# manifest is a partial answer that reads exactly like a complete one.
printf 'good|daemon|/bin/true\nbroken row\n' > "$TMP/reader-bad"
for c in status drain restart; do
    rc=0
    env -i HOME="$TMP/home" PATH="$PATH" SPIRA_CONF="$WCONF" SPIRA_WATCHERS="$TMP/reader-bad" \
        bash "$CLONE/spira/watchd.sh" "$c" >"$TMP/o" 2>&1 || rc=$?
    is "$c refuses it"        "1" "$rc"
    is "and emits nothing"    "" "$(grep -v '^watchd:' "$TMP/o")"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
