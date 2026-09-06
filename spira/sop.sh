#!/usr/bin/env bash
#
# sop.sh — write, match, recall and synthesise a Standard Operating Procedure.
#
#   sop.sh write <slug> [-|<file>]   write or amend sop-<slug>; text on stdin or from a file
#   sop.sh show <slug>               one SOP's full text
#   sop.sh list                      what is on the shelf
#   sop.sh match [-|<file>]          which SOPs match an incident payload
#   sop.sh retire <slug>             remove it
#   sop.sh synth                     regenerate wiki/notes/standard-operating-procedures.md
#
# `<slug>` is written without the `sop-` prefix; it is added for you.
#
# WHY THIS IS THE SAME MECHANISM AS rule.sh
# -----------------------------------------
# Statutes are how to behave; SOPs are how to fix. They are stored the same way and read
# the same way — `bd remember` / `bd recall`, split by prefix — so Ops reads its runbooks
# exactly as every agent already reads law, rather than through a second knowledge channel
# that has to be invented, delivered and remembered.
#
# WHY AN SOP HAS A SHAPE AND THIS PROGRAM REFUSES PROSE
# -----------------------------------------------------
# A runbook written as a paragraph cannot be matched to an incident by a program and cannot
# be executed without being re-read and re-interpreted. Four fields make it mechanical:
#
#   MATCH:     an extended regex tested against the incident payload   (optional)
#   SYMPTOM:   what you are looking at                                 (required)
#   CHECK:     the command that confirms it is really this             (required)
#   FIX:       what to do about it                                     (required)
#   ESCALATE:  when this is not yours to fix                           (optional)
#   REF:       the long form, usually a wiki page                      (optional)
#
# MATCH is what makes recall deterministic. Matching an incident to a runbook by asking a
# model is the expensive tier; a regex written by whoever resolved the incident is the
# cheap one, and cheap-then-expensive is the whole shape of this harness.
#
# WHY THE WORD CAP
# ----------------
# An SOP is injected into every Ops session, exactly like a statute. 250 words is enough
# for a real procedure and small enough that thirty of them still fit; the long form goes
# behind REF, where it costs nothing until someone needs it.
#
# WHY SPIRA AND NOT THE TOWN
# --------------------------
# Statutes go to both because Gas Town agents still read them. SOPs go only to Spira: the
# Ops persona is the only thing that executes one, it reads the harness database, and putting
# runbooks in the town would charge every polecat context for a book it cannot act on.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# `synth` renders into the operator's wiki, which is the one thing here the harness must not
# require. SPIRA_WIKI is empty on a clone that has no wiki, and `synth` says so and stops
# rather than deriving a path that happens to resolve (rule 2 of the boundary).
OUT="${SOP_PAGE:-${SPIRA_WIKI:+$SPIRA_WIKI/wiki/notes/standard-operating-procedures.md}}"
WORD_CAP="${SOP_WORD_CAP:-250}"

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
slugify() { printf 'sop-%s' "${1#sop-}"; }

# Read from a file, from stdin on `-`, or from stdin when nothing is named. Never from an
# argument: prose in a shell argument is how backticks and $( ) become command substitution
# (law-commit-messages-via-stdin).
slurp() {
    case "${1:--}" in
        -) cat ;;
        *) [ -f "$1" ] || { echo "sop: no such file: $1" >&2; exit 1; }; cat "$1" ;;
    esac
}

# All SOPs as JSON, {key: text}. One query, so every subcommand costs the same.
shelf() {
    bdjson memories 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(json.dumps({k: v.strip() for k, v in sorted(d.items())
                  if isinstance(v, str) and k.startswith("sop-")}))'
}

case "${1:-}" in

write)
    [ $# -ge 2 ] || usage
    key="$(slugify "$2")"
    text="$(slurp "${3:--}")"
    [ -n "${text//[[:space:]]/}" ] || { echo "sop: refusing — empty SOP" >&2; exit 1; }

    # Fail closed on shape. A malformed SOP that is stored anyway is worse than a rejected
    # one, because it reads as a runbook right up to the moment someone needs it at 3am.
    missing=""
    for field in SYMPTOM CHECK FIX; do
        grep -qE "^[[:space:]]*$field:" <<< "$text" || missing="$missing $field"
    done
    if [ -n "$missing" ]; then
        echo "sop: refusing — missing required field(s):$missing" >&2
        echo "     An SOP is SYMPTOM / CHECK / FIX at minimum, with optional MATCH," >&2
        echo "     ESCALATE and REF. A paragraph cannot be matched or executed." >&2
        exit 1
    fi

    # A MATCH line must be a regex grep can actually compile, checked here rather than
    # discovered by `sop.sh match` returning nothing during an incident.
    re="$(sed -n 's/^[[:space:]]*MATCH:[[:space:]]*//p' <<< "$text" | head -1)"
    if [ -n "$re" ]; then
        # grep exits 1 for "compiled fine, matched nothing" and 2 for "will not compile".
        # Only the second is an error, which is why this tests the status rather than
        # whether anything matched.
        printf '' | grep -E -- "$re" >/dev/null 2>&1
        if [ "$?" -ge 2 ]; then
            echo "sop: refusing — MATCH is not a valid extended regex: $re" >&2
            exit 1
        fi
    fi

    words=$(wc -w <<<"$text")
    if [ "$words" -gt "$WORD_CAP" ]; then
        echo "sop: refusing — ${words} words, cap is ${WORD_CAP}." >&2
        echo "     Every Ops session pays for every SOP. Keep the procedure here and put" >&2
        echo "     the narrative behind a REF: line pointing at a wiki page." >&2
        exit 1
    fi

    bdq remember --key "$key" "$text" >/dev/null || {
        echo "sop: failed to write $key to $SPIRA_DB" >&2; exit 1; }
    echo "wrote $key (${words} words)"
    [ -n "$re" ] && echo "  matches: $re" || echo "  no MATCH: line — recall falls back to key tokens"
    "$0" synth
    ;;

show)
    [ $# -eq 2 ] || usage
    bdq recall "$(slugify "$2")" 2>/dev/null || {
        echo "sop: no such SOP: $(slugify "$2")" >&2; exit 1; }
    ;;

list)
    shelf | python3 -c '
import sys, json, re
d = json.load(sys.stdin)
for k, v in d.items():
    sym = ""
    m = re.search(r"^\s*SYMPTOM:\s*(.+)$", v, re.M)
    if m: sym = m.group(1).strip()
    print(f"  {k:<40} {len(v.split()):>3}w  {sym[:60]}")
print(f"\n{len(d)} SOP(s) on the shelf")'
    ;;

match)
    # The deterministic tier. Every SOP whose MATCH regex fires against the payload, best
    # first by number of distinct lines hit; SOPs with no MATCH line fall back to their key
    # tokens, which is weak on purpose — it is a nudge to go and write a MATCH.
    payload="$(slurp "${2:--}")"
    shelf | SOP_PAYLOAD="$payload" python3 -c '
import sys, json, os, re
payload = os.environ.get("SOP_PAYLOAD", "")
d = json.load(sys.stdin)
hits = []
for k, v in d.items():
    m = re.search(r"^\s*MATCH:\s*(.+)$", v, re.M)
    sym = re.search(r"^\s*SYMPTOM:\s*(.+)$", v, re.M)
    sym = sym.group(1).strip() if sym else ""
    score, how = 0, ""
    if m:
        try:
            pat = re.compile(m.group(1).strip(), re.I | re.M)
            score = len({l for l in payload.splitlines() if pat.search(l)})
            how = "MATCH"
        except re.error:
            score, how = 0, "BAD-REGEX"
    else:
        toks = [t for t in k[len("sop-"):].split("-") if len(t) > 3]
        score = sum(1 for t in toks if re.search(re.escape(t), payload, re.I))
        how = "key-tokens"
    if score > 0:
        hits.append((score, k, how, sym))
for score, k, how, sym in sorted(hits, reverse=True):
    print(f"{k}\t{how}\t{score}\t{sym}")
' 2>/dev/null
    ;;

retire)
    [ $# -eq 2 ] || usage
    key="$(slugify "$2")"
    bdq forget "$key" >/dev/null 2>&1 || { echo "sop: no such SOP: $key" >&2; exit 1; }
    echo "retired $key"
    "$0" synth
    echo
    echo "Retire an SOP the way a statute is retired: remove it. Do not leave it standing"
    echo "with a correction attached — that is a stale runbook with a warning label."
    ;;

synth)
    # REGENERATED WHOLE, NEVER PATCHED (law-regenerate-derived-summaries). Editing the page
    # does nothing; amend the SOP. It exists for the same two reasons common-law.md does:
    # the Dolt store is gitignored and backed up nowhere, so this is the only copy of the
    # runbooks that leaves the building, and it is the only one readable without any of this
    # tooling — which is the situation you are in when something has already failed.
    if [ -z "$OUT" ]; then
        echo "sop: no wiki configured (SPIRA_WIKI) — nothing to synthesise into." >&2
        echo "sop: the SOPs themselves are in the database; \`sop.sh list\` reads them." >&2
        exit 0
    fi
    today="$(TZ="${SPIRA_TZ:-${TZ:-}}" date '+%Y-%m-%d')"
    # The shelf goes to a FILE, not down a pipe. A heredoc-fed `python3 -` owns stdin, so
    # `shelf | python3 - <<PY` silently hands the script an empty stdin and it renders an
    # empty page over a good one — a derived document that regenerates itself to nothing.
    # A path also has no ARG_MAX ceiling, which argv would.
    shelf_file="$(mktemp)"; trap 'rm -f "$shelf_file"' EXIT
    shelf > "$shelf_file"
    python3 - "$today" "$OUT" "$shelf_file" <<'PY'
import json, sys, re, textwrap
today, out = sys.argv[1], sys.argv[2]
sops = json.load(open(sys.argv[3]))
if not isinstance(sops, dict):
    sys.exit("sop-synth: refusing — the shelf did not parse; the page is left alone")

def field(v, name):
    m = re.search(rf"^\s*{name}:\s*(.*?)(?=^\s*(?:MATCH|SYMPTOM|CHECK|FIX|ESCALATE|REF):|\Z)",
                  v, re.M | re.S)
    return m.group(1).strip() if m else ""

b = []
b += ["---", "type: note", "created: 2026-09-05", f"updated: {today}",
      "tags: [spira, ops, sop, runbook, generated]",
      "aliases: [SOPs, Standard operating procedures, The shelf]", "---", ""]
b += ["# Standard operating procedures", ""]
b += ["**Generated — do not edit.** Regenerated whole by `.claude/spira/sop.sh synth` from "
      "the Spira beads database, which is the source of truth. Editing this page has no "
      "effect; the next run overwrites it. Amend an SOP instead:", ""]
b += ["```bash", ".claude/spira/sop.sh write <slug> -   # text on stdin", "```", ""]
b += ["Statutes are how to behave; SOPs are how to fix. They share one mechanism, split by "
      "prefix — `law-` and `sop-` — so the [[spira]] Ops persona reads its runbooks exactly "
      "the way every agent already reads [[common-law]]. Ops is summoned by an incident bead "
      "filed from a failed systemd unit, matches the payload against the `MATCH:` lines "
      "below, and executes the first one that fires.", ""]
b += [f"**{len(sops)} SOP(s)** on the shelf as of {today}.", ""]
b += ["## The closing rule", ""]
b += ["**An incident resolved without an SOP must produce one.** This is "
      "`law-bake-rules-into-tools` applied to production, and it is enforced rather than "
      "asked for: writing an SOP is what regenerates this page, the regenerated page is the "
      "commit that names the incident bead, and a bead closed with no commit naming it is "
      "reopened by `aeon.sh`. An incident fixed by hand and forgotten does not close.", ""]
b += ["## The shelf", ""]
if not sops:
    b += ["*Empty.* The first incident to be resolved fills it.", ""]
for k, v in sops.items():
    b += [f"### {k[len('sop-'):].replace('-', ' ').capitalize()}", "", f"`{k}`", ""]
    for name, label in (("SYMPTOM", "Symptom"), ("CHECK", "Check"), ("FIX", "Fix"),
                        ("ESCALATE", "Escalate"), ("REF", "Reference")):
        val = field(v, name)
        if not val:
            continue
        if "\n" in val or val.strip().startswith(("$", "sudo", "systemctl", "bd ", "git ")):
            b += [f"**{label}**", "", "```", *val.splitlines(), "```", ""]
        else:
            b += [f"**{label}** — {' '.join(textwrap.wrap(val, 10000))}", ""]
    m = re.search(r"^\s*MATCH:\s*(.+)$", v, re.M)
    b += [f"**Matches** `{m.group(1).strip()}`" if m else
          "**Matches** — no `MATCH:` line; this SOP is found by key tokens only, which is "
          "weak. Add one.", ""]
b += ["Related: [[spira]], [[common-law]], [[codified-judgement]]", ""]
open(out, "w").write("\n".join(b))
print(f"sop-synth: wrote {out} — {len(sops)} SOP(s)")
PY
    ;;

*) usage ;;
esac
