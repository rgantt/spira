#!/usr/bin/env bash
#
# ask — put a question, decision or insight in front of the operator, stored as a bead.
#
#   ask.sh add "<question>"        [--why "<what is blocked>"] [--default "<what I'd do>"]
#   ask.sh decide "<the choice>"   [--why ...] [--default ...]
#   ask.sh insight "<what was learned>" [--why "<why it matters>"]
#   ask.sh list [needs-you|insights|all]
#   ask.sh answered <bead-id> "<verdict>"
#   ask.sh drop <bead-id> "<reason>"
#
# WHY BEADS AND NOT A FILE
# ------------------------
# This used to write .runtime/asks.jsonl, a hand-rolled store, and it lost data: ids were a
# truncated timestamp plus a truncated random suffix, two asks filed in the same second
# collided, and because answering matched by id one reply closed both — recording a verdict
# against a question the operator never answered. Beads gives real identity, status, close reasons
# and comments, and one store rather than two. (The operator, verbatim: "the current data
# model is guaranteeing sync issues and data loss".)
#
# THE THREE KINDS, AND THE TYPES THAT ACTUALLY EXIST
#   question  -> type `decision`, label $SPIRA_ASK_LABEL  open; the close reason IS the verdict
#   decision  -> type `decision`, label $SPIRA_ASK_LABEL  open; the close reason IS the verdict
#   insight   -> type `task`,     label insight      created CLOSED — there is nothing to do
#
# beads validates issue_type against a fixed set: task, bug, epic, feature, chore, decision,
# spike, rig, event. `question`, `insight`, `note` and `idea` are NOT types, whatever
# `bd create --dry-run` says — dry-run does not run the validator, so it accepted all four
# and the first real create rejected them. The taxonomy therefore lives in LABELS, with the
# type chosen from the real set.
#
# A question and a decision share the `decision` type deliberately rather than by compromise:
# the escalation policy already says an escalation is a decision request, not a problem
# report, so a question with a recommended default IS a decision awaiting a verdict.
#
# An insight exists because an answer that scrolls off screen is lost. It is neither a task
# nor a question, and before this there was nowhere to put one.
#
# `$SPIRA_ASK_LABEL` is the label on anything awaiting them — the SAME label the escalation gate and
# the mountain design already exclude, so a question can never be dispatched to a polecat as
# if it were work. No assignee is set, for the same reason: an assignee is how Gas Town routes
# work to an agent.
set -uo pipefail

# Every path comes from the harness's one configuration surface. It is two directories
# away because the cockpit ships beside the harness, not inside it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../spira" && pwd -P)/conf.sh"
export BEADS_NO_AUTO_IMPORT=1
# THE database (the operator's call) — the same `COCKPIT_DB` every cockpit tool reads.
DB="$COCKPIT_DB"

bdt() { bd -C "$DB" "$@"; }
strip_warn() { grep -vE '^(warning:|  Fix:|  Or:)'; }

# `--default` is close to mandatory on a question: an ask without a recommendation makes the operator
# decide from scratch, which is what the escalation policy exists to prevent.
#
# AND ON AN OPERATOR ASK — one where they runs a command — put a machine check in the body:
#
#     VERIFY: <read-only shell command exiting 0 once the ask is already satisfied>
#
# `verify-asks.sh` runs those on a timer and closes the ones that pass, with the output as
# evidence. One ask requested a subscription, sat in the queue three days, and
# carried the exact proving command in its own text: *"ran those commands to verify, but i
# already did this days ago. close it out."* The check existed; nothing ran it.
# AN INSIGHT IS NOT AN ASK, AND ITS BODY MUST NOT READ LIKE ONE.
#
# (the operator, verbatim: "these insights seem more like bug reports which means they're
# implicitly asking me for feedback -- really they should be FYI only.") One `compose` wrote
# all three kinds, so every insight ever recorded opened with "**What is blocked:**" -- when
# nothing is blocked, that is the whole point of the kind -- and signed off by telling them to
# file a verdict against it. The framing they objected to was not a rendering choice; it was
# literally in the text, put there by this function.
#
# So the trailer is kind-dependent: an ask says how to answer it, a record says nothing is
# owed. `$1` is the kind, and the pane strips the old wording from the insights already
# stored, which cannot be rewritten.
compose() { # kind why default evidence
    local kind="$1" why="$2" dflt="$3" ev="${4:-}" body=""
    [ -n "$dflt" ] && body="${body}**Default — what I would do:** ${dflt}"$'\n\n'
    if [ -n "$why" ]; then
        if [ "$kind" = insight ]; then
            body="${body}**Why it matters:** ${why}"$'\n\n'
        else
            body="${body}**What is blocked:** ${why}"$'\n\n'
        fi
    fi
    # THE EVIDENCE TRAVELS WITH THE ASK. (the operator, verbatim: "with a failure like this,
    # i want to see the log itself in the decision pane. i don't know what's being asked of
    # me here!") An escalation naming a path they cannot open from the pane is a problem report
    # wearing a decision's clothes: they must go find the facts before they can even tell what is
    # being asked, which is the work the escalation existed to do for them.
    [ -n "$ev" ] && body="${body}**Evidence**"$'\n'"\`\`\`"$'\n'"${ev}"$'\n'"\`\`\`"$'\n\n' 
    if [ "$kind" = insight ]; then
        body="${body}_Recorded by the brain session. Nothing is owed — this is a record, not a_"$'\n'
        body="${body}_request. Press \`d\` in the cockpit pane to dismiss it; \`h\` brings it back._"
    else
        body="${body}_Filed by the brain session. Answer inline in the cockpit pane, or:_"$'\n'
        body="${body}\`.claude/cockpit/ask.sh answered <id> \"<verdict>\"\`"
    fi
    printf '%s' "$body"
}

create() { # type text why default labels
    local type="$1" text="$2" why="$3" dflt="$4" labels="$5" out id kind=ask
    : "${EV:=}"
    # The kind is read off the labels rather than passed separately: the labels are already
    # what every reader — the pane, `ask.sh list`, watch-answers.sh — uses to tell an insight
    # from an ask, and a second source for the same fact is a second thing to get out of step.
    case ",$labels," in *,insight,*) kind=insight ;; esac
    # THE ID COMES FROM `--json`, NEVER FROM A GREP OVER THE HUMAN OUTPUT.
    #
    # `bd create` prepends an advisory when a title looks like test data, and that advisory
    # ECHOES THE TITLE three times before the "Created issue:" line. `strip_warn` does not
    # match it — its lines begin `⚠`, `  Title:`, `  Recommendation:`. So the first
    # id-shaped token in the output is whatever the TITLE happens to contain, and the next
    # thing this script does with an insight's id is `bdt close "$id"`.
    #
    # Seen once, from the same grep run by hand: a title containing
    # "sp-pane-insights-fyi" yielded `sp-pane`, and the `bd delete` that followed removed the
    # sp-pane EPIC, its three labels and all seven of its dependency edges. Restored from
    # Dolt history; nothing about the command said it had addressed the wrong bead.
    out=$(bdt create --title "$text" --type "$type" -p 1 \
            --labels "$labels" -d "$(compose "$kind" "$why" "$dflt" "$EV")" --json 2>&1)
    id=$(python3 -c '
import json, re, sys
t = sys.stdin.read()
i = t.find("{")
if i >= 0:
    try:
        print(json.loads(t[i:])["id"]); raise SystemExit
    except (ValueError, KeyError):
        pass
# Fallback, anchored to the line that ANNOUNCES the id rather than to the whole output.
for line in t.splitlines():
    m = re.search(r"Created issue:\s+((?:hq|[a-z]{2})-[a-z0-9]+)", line)
    if m:
        print(m.group(1)); raise SystemExit
' <<<"$out")
    if [ -z "$id" ]; then
        echo "ask: create failed" >&2; printf '%s\n' "$out" >&2; return 1
    fi
    printf '%s' "$id"
}

parse_opts() { # sets WHY / DFLT from remaining args
    WHY=""; DFLT=""; EV=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --why)     WHY="${2:-}"; shift 2 ;;
            --default) DFLT="${2:-}"; shift 2 ;;
            # --evidence carries the facts themselves; --evidence-file reads them from a
            # file, which is the usual case because the facts are normally a log tail.
            --evidence) EV="${2:-}"; shift 2 ;;
            --evidence-file)
                if [ -r "${2:-}" ]; then EV="$(tail -c 2500 "$2" 2>/dev/null)"
                else EV="(evidence file unreadable: ${2:-})"; fi
                shift 2 ;;
            *) shift ;;
        esac
    done
}

case "${1:-list}" in

add|ask|question)
    shift; text="${1:?usage: ask.sh add \"<question>\" [--why ...] [--default ...]}"; shift || true
    parse_opts "$@"
    id=$(create decision "$text" "$WHY" "$DFLT" "$SPIRA_ASK_LABEL,overseer,ask-question") || exit 1
    echo "asked [$id] $text"
    [ -n "$DFLT" ] || echo "  note: no --default given. An ask without a recommendation makes the operator decide from scratch." >&2
    ;;

decide|decision)
    shift; text="${1:?usage: ask.sh decide \"<the choice>\" [--why ...] [--default ...]}"; shift || true
    parse_opts "$@"
    id=$(create decision "$text" "$WHY" "$DFLT" "$SPIRA_ASK_LABEL,overseer,ask-decision") || exit 1
    echo "decision [$id] $text"
    ;;

insight|learned)
    shift; text="${1:?usage: ask.sh insight \"<what was learned>\" [--why ...]}"; shift || true
    parse_opts "$@"
    # Created then immediately closed: an insight is a record, not work. Left open it would
    # show up in `bd ready` and eventually in front of a polecat.
    id=$(create task "$text" "$WHY" "" "insight,overseer") || exit 1
    bdt close "$id" --reason "recorded" >/dev/null 2>&1
    echo "insight [$id] $text"
    ;;

promote)
    # AN FYI CAN BECOME A DECISION. (the operator, verbatim: "in some cases this may actually
    # result in one item turning into another type — i.e. FYI turns into a decision, etc.")
    #
    # An insight is filed as a record because at the time it was one. Then they comment on
    # it and it stops being a record: "this absolutely needs to be fixed" is a directive and
    # "not quite a law, not quite a decision, but something else" is a question. Re-filing it
    # as a new bead would strand the thread they wrote in, which is the whole reason they asked
    # for threads. So the item is promoted IN PLACE, keeping its id and its comments.
    id="${2:?usage: ask.sh promote <bead-id> [--to decision|task] [--why ...] [--default ...]}"
    shift 2 || true
    TO=decision
    for a in "$@"; do case "$prev_arg" in --to) TO="$a" ;; esac; prev_arg="$a"; done
    parse_opts "$@"
    case "$TO" in
        decision) newlabels="$SPIRA_ASK_LABEL,overseer,ask-decision"; newtype=decision ;;
        task)     newlabels="$SPIRA_ASK_LABEL,overseer,ask-task";     newtype=task ;;
        *) echo "ask: --to must be decision or task" >&2; exit 1 ;;
    esac
    # An insight is created CLOSED; a thing awaiting the operator must be open or it cannot be
    # answered, and the escalation gate defers it rather than dispatching it to a worker.
    bdt reopen "$id" >/dev/null 2>&1
    bdt update "$id" --type "$newtype" >/dev/null 2>&1
    bdt label remove "$id" insight >/dev/null 2>&1
    for l in ${newlabels//,/ }; do bdt label add "$id" "$l" >/dev/null 2>&1; done
    [ -n "${WHY:-}${DFLT:-}" ] && \
        "$(dirname "$0")/reply.sh" "$id" "Promoted from FYI to $TO.${DFLT:+ Default: $DFLT}${WHY:+ What is blocked: $WHY}" >/dev/null 2>&1
    echo "promoted [$id] FYI -> $TO (kept its id and its thread)"
    ;;

answered)
    id="${2:?usage: ask.sh answered <bead-id> \"<verdict>\"}"
    verdict="${3:?a verdict is required — the close reason IS the record}"
    bdt close "$id" --reason "$verdict" 2>&1 | strip_warn | tail -2
    echo
    echo "  Does this verdict generalise? If so it is law, not a closed bead:"
    echo "    $(dirname "$SPIRA_HOME")/rule.sh enact <slug> \"<statute + the case that produced it>\""
    ;;

drop|dismiss)
    id="${2:?usage: ask.sh drop <bead-id> \"<reason>\"}"
    bdt close "$id" --reason "dismissed: ${3:-not needed}" 2>&1 | strip_warn | tail -2
    ;;

list)
    # --all is required: insights are created CLOSED by design, and `bd list` hides
    # closed issues unless asked, so the insights view was permanently empty.
    bdt list --all --limit 0 --json 2>/dev/null | strip_warn | python3 -c '
import json, sys
view = sys.argv[1] if len(sys.argv) > 1 else "needs-you"
try:
    rows = json.load(sys.stdin)
except Exception:
    print("  could not read the town database"); raise SystemExit(1)
rows = rows if isinstance(rows, list) else rows.get("issues", [])
# The taxonomy is in labels; issue_type cannot express it.
def lab(r): return set(r.get("labels") or [])
def kind(r):
    l = lab(r)
    if "insight" in l: return "insight"
    if "ask-decision" in l: return "decision"
    if "ask-task" in l: return "task"
    if "ask-question" in l: return "question"
    return r.get("issue_type") or "?"
mine = [r for r in rows if "overseer" in lab(r)]
if view in ("insights", "insight"):
    # Archived insights have been read and dismissed; they stay in `all`, not here.
    sel = [r for r in mine if "insight" in lab(r) and "archived" not in lab(r)]
elif view == "all":
    sel = mine
else:
    sel = [r for r in mine if "insight" not in lab(r) and r.get("status") == "open"]
sel.sort(key=lambda r: r.get("created_at") or "", reverse=True)
for r in sel[:40]:
    print("  [%s] %-8s %-9s %s" % (r["id"], kind(r), r.get("status"), (r.get("title") or "")[:76]))
print()
print("  %d %s" % (len(sel), view))' "${2:-needs-you}"
    ;;

*) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
