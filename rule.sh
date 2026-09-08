#!/usr/bin/env bash
#
# rule.sh — enact, amend, or retire a statute in one command.
#
#   rule.sh enact <slug> "<statute text>"    write it, then synthesise it into the wiki
#   rule.sh retire <slug>                    remove it
#   rule.sh list                             what is in force
#   rule.sh show <slug>                      one statute's full text
#
# `<slug>` is written without the `law-` prefix; it is added for you.
#
# WHY THIS IS A COMMAND AND NOT A CHECKLIST
# -----------------------------------------
# Enacting a statute is two steps — write it to the statute book, regenerate the wiki
# page that is its only git-backed copy — and a rule that depends on remembering a second
# step is a resolution, not a mechanism. The standing lesson here is that when a rule is
# discovered the deliverable is a guard or a command, never a note.
#
# ONE DATABASE. Statutes live in the Spira beads database and nowhere else; that is the
# store every aeon reads its memories from at summon. There is no propagation step,
# because there is nothing to propagate to. `SPIRA_DB` overrides the path, as it does for
# every tool in this repo.
#
# WHEN TO REACH FOR IT
# --------------------
# When the operator answers an escalation, that answer is a verdict. Ask whether it
# generalises; if it does, enact it in the same session with the case that produced it
# as the trailing citation, so the rule carries its own history. The escalation queue should
# be producing law, not just draining — a class of question that keeps coming back is a
# missing statute.
#
# Statutes are read by every agent on every session, so write them to be read a thousand
# times: one paragraph, imperative, ~70 words, the scar as a single clause rather than a
# narrative of how we got here.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/spira" && pwd -P)/conf.sh"
export BEADS_NO_AUTO_IMPORT=1
DB="$SPIRA_DB"

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# THE SECOND STEP IS OPTIONAL, AND THAT IS RULE 2 OF THE BOUNDARY. Rendering the statute book
# into a wiki page is an effect on a repository the harness must not require: a clean clone
# with no wiki anywhere on the machine has to work. So it is a CONFIGURED hook, called when
# present and skipped in silence when not. An optional call is not a dependency; a hard path
# is. The hook is given no arguments and is expected to regenerate whatever it renders.
synth() {
    local hook="$SPIRA_WIKI_HOOK"
    [ -x "$hook" ] || return 0
    "$hook"
}
slugify() { printf 'law-%s' "${1#law-}"; }

# A missing `.beads` is a real fault to report, never a reason to quietly address whatever
# database the working directory happens to resolve to.
[ -d "$DB/.beads" ] || { echo "rule: $DB has no .beads — refusing to guess a database" >&2; exit 1; }

case "${1:-}" in

enact)
    [ $# -ge 3 ] || usage
    key="$(slugify "$2")"; shift 2
    text="$*"
    words=$(wc -w <<<"$text")
    if [ "$words" -gt 130 ]; then
        echo "rule: refusing — ${words} words. A statute is one paragraph (~70 words);" >&2
        echo "      every agent pays this context on every session. Put the case history" >&2
        echo "      in the wiki and keep the scar here as a single clause." >&2
        exit 1
    fi
    bd -C "$DB" remember --key "$key" "$text" >/dev/null || {
        echo "rule: failed to write $key to the statute book at $DB" >&2; exit 1; }
    echo "enacted $key (${words} words)"
    synth
    echo
    echo "Statute is live in every agent session at its next summon."
    echo "Commit wiki/notes/common-law.md to replicate it off this box."
    ;;

retire)
    [ $# -eq 2 ] || usage
    key="$(slugify "$2")"
    bd -C "$DB" memories --json 2>/dev/null \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if sys.argv[1] in d else 1)' "$key" || {
        echo "rule: no statute '$key' in the statute book at $DB" >&2; exit 1; }
    bd -C "$DB" forget "$key" >/dev/null 2>&1 && echo "forgot $key"
    synth
    echo
    echo "Retired. Do not leave a retired statute standing with a correction attached —"
    echo "that is the same defect as a correction banner on a stale page."
    ;;

list)
    bd -C "$DB" memories --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
laws = {k: v for k, v in sorted(d.items()) if k.startswith("law-") and isinstance(v, str)}
for k, v in laws.items():
    print(f"  {k:<44} {len(v.split()):>3}w  {v.split(".")[0][:64]}")
print(f"\n{len(laws)} statutes in force")'
    ;;

show)
    [ $# -eq 2 ] || usage
    key="$(slugify "$2")"
    # `recall` only. The first version fell through to `bd remember "$key"` when recall
    # found nothing, which is a WRITE command reached by mistyping a slug in a read.
    bd -C "$DB" recall "$key" 2>/dev/null || {
        echo "rule: no statute '$key' — \`rule.sh list\` shows what is in force" >&2; exit 1; }
    ;;

*) usage ;;
esac
