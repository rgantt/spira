#!/usr/bin/env bash
#
# test-destructive-bead.sh — bdq create refuses a bead whose title or description contains
#   vocabulary indicating the procedure halts the harness, unless needs-ryan is present.
#
#   ./test-destructive-bead.sh
#
# THE DEFECT THIS PREVENTS. sp-6ylz had "needs the world stopped" in its title and was
# dispatchable anyway. An aeon claimed it and ran world.sh stop from step 2, killing the
# sentinel, ops timer, both watchers, and three live aeons. The filer had written the danger
# into the title and still filed it dispatchable. The fence converts the symptom — the title
# — into the mechanism. (sp-6hdi, law-destructive-beads-are-never-dispatchable)
#
# POSITIVE CONTROL FIRST (law-absence-needs-a-positive-control). The bad-vocabulary case is
# tested before any innocuous case, confirming the check fires on a known offender.
#
# defect: sp-6hdi
# covers: spira/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
want()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "wanted [$2] in [$3]"; }
nowant(){ [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "did not want [$2] in [$3]"; }

echo "test-destructive-bead.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# A stub bd that records its call and exits 0, so passing cases reach it.
STUB_BD="$TMP/bd"
printf '#!/usr/bin/env bash\nprintf "bd-called\\n"; exit 0\n' > "$STUB_BD"
chmod +x "$STUB_BD"

# Run _bdq_check_destructive directly for fine-grained tests of each pattern.
check_title() {  # check_title <title> <labels> -> combined stdout+stderr
    env -i PATH="$PATH" HOME="$TMP" \
        SPIRA_HOME="$HERE" SPIRA_REPO="$TMP/norepo" SPIRA_DB="$TMP/nodb" \
        SPIRA_REPO_MAP="$TMP/nomap" SPIRA_BD="$STUB_BD" \
        bash -c '. "$1/lib.sh"; _bdq_check_destructive create "$2" --labels "$3"' \
            -- "$HERE" "$1" "$2" 2>&1
}

# Same, but puts the text in the description rather than the title.
check_desc() {  # check_desc <desc> <labels> -> combined stdout+stderr
    env -i PATH="$PATH" HOME="$TMP" \
        SPIRA_HOME="$HERE" SPIRA_REPO="$TMP/norepo" SPIRA_DB="$TMP/nodb" \
        SPIRA_REPO_MAP="$TMP/nomap" SPIRA_BD="$STUB_BD" \
        bash -c '. "$1/lib.sh"; _bdq_check_destructive create "clean title" -d "$2" --labels "$3"' \
            -- "$HERE" "$1" "$2" 2>&1
}

# Run bdq create end-to-end, with no repo: label so the repo-label check passes trivially.
run_bdq() {  # run_bdq <title> <labels> -> combined stdout+stderr
    env -i PATH="$PATH" HOME="$TMP" \
        SPIRA_HOME="$HERE" SPIRA_REPO="$TMP/norepo" SPIRA_DB="$TMP/nodb" \
        SPIRA_REPO_MAP="$TMP/nomap" SPIRA_BD="$STUB_BD" BD_TIMEOUT=10 \
        bash -c '. "$1/lib.sh"; bdq create "$2" --labels "$3"' \
            -- "$HERE" "$1" "$2" 2>&1
}

# ==========================================================================
echo
echo "POSITIVE CONTROL: sp-6ylz exact title is refused:"
# ==========================================================================

SP6YLZ="needs the world stopped"
out="$(check_title "$SP6YLZ" "spira,plan" || true)"
want "sp-6ylz title: refused"               "needs-ryan"      "$out"
want "sp-6ylz title: names matched phrase"  "world stopped"   "$out"

# ==========================================================================
echo
echo "each destructive pattern is refused:"
# ==========================================================================

out="$(check_title "Run world.sh stop immediately" "spira,plan" || true)"
want "world.sh stop: refused"              "needs-ryan"  "$out"
want "world.sh stop: names the phrase"    "world.sh"    "$out"

out="$(check_title "spira-world down for maintenance" "spira,plan" || true)"
want "spira-world down: refused"           "needs-ryan"  "$out"
want "spira-world down: names the phrase"  "spira-world" "$out"

out="$(check_title "run systemd/install.sh to deploy" "spira,plan" || true)"
want "systemd/install.sh: refused"         "needs-ryan"        "$out"
want "systemd/install.sh: names the phrase" "systemd/install"  "$out"

out="$(check_title "systemctl daemon-reload after edit" "spira,plan" || true)"
want "daemon-reload: refused"              "needs-ryan"     "$out"
want "daemon-reload: names the phrase"     "daemon-reload"  "$out"

out="$(check_title "systemctl stop spira-sentinel.timer" "spira,plan" || true)"
want "systemctl stop spira-*: refused"    "needs-ryan"  "$out"
want "systemctl stop spira-*: names it"  "systemctl"   "$out"

out="$(check_title "systemctl restart spira-ops.service" "spira,plan" || true)"
want "systemctl restart spira-*: refused"  "needs-ryan"  "$out"
want "systemctl restart spira-*: names it" "systemctl"   "$out"

out="$(check_title "apply a schema migration to beads" "spira,plan" || true)"
want "schema migration: refused"           "needs-ryan"  "$out"
want "schema migration: names the phrase"  "schema"      "$out"

out="$(check_title "schema migrate the users table" "spira,plan" || true)"
want "schema migrate: refused"             "needs-ryan"  "$out"

# ==========================================================================
echo
echo "vocabulary in description is also refused:"
# ==========================================================================

out="$(check_desc "Step 1: run world.sh stop to halt the loop" "spira,plan" || true)"
want "destructive desc: refused"           "needs-ryan"  "$out"
want "destructive desc: names the phrase"  "world.sh"    "$out"

# ==========================================================================
echo
echo "needs-ryan label bypasses the fence:"
# ==========================================================================

out="$(check_title "$SP6YLZ" "spira,plan,needs-ryan" 2>&1)" || true
nowant "needs-ryan: not refused"  "needs-ryan label" "$out"

out="$(check_title "Run world.sh stop" "needs-ryan" 2>&1)" || true
nowant "needs-ryan only label: not refused"  "needs-ryan label" "$out"

# ==========================================================================
echo
echo "innocent text is not refused:"
# ==========================================================================

out="$(check_title "install the new persona and update config" "spira,plan" 2>&1)" || true
nowant "innocent install: not refused"  "needs-ryan"  "$out"

out="$(check_title "stop the failing queue probe" "spira,plan" 2>&1)" || true
nowant "stop without spira-: not refused"  "needs-ryan"  "$out"

out="$(check_title "systemctl status spira-sentinel" "spira,plan" 2>&1)" || true
nowant "systemctl status (not stop/restart): not refused"  "needs-ryan"  "$out"

out="$(check_title "investigate why schema is missing" "spira,plan" 2>&1)" || true
nowant "schema without migrate: not refused"  "needs-ryan"  "$out"

out="$(check_title "restart the web server" "spira,plan" 2>&1)" || true
nowant "restart without spira-*: not refused"  "needs-ryan"  "$out"

# ==========================================================================
echo
echo "bdq create end-to-end: destructive title refused, bd not called:"
# ==========================================================================

e2e_bad="$(run_bdq "Run world.sh stop to apply config" "spira,plan" || true)"
want   "bdq: refused"         "needs-ryan"  "$e2e_bad"
nowant "bdq: bd not called"   "bd-called"   "$e2e_bad"

e2e_ok="$(run_bdq "Run world.sh stop with approval" "spira,plan,needs-ryan" 2>&1)" || true
want "bdq with needs-ryan: bd called"  "bd-called"  "$e2e_ok"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
