---
type: note
created: 2026-09-05
updated: 2026-09-08
tags: [spira, ops, sop, runbook, generated]
aliases: [SOPs, Standard operating procedures, The shelf]
---

# Standard operating procedures

**Generated — do not edit.** Regenerated whole by the harness's `spira/sop.sh synth` from the Spira beads database, which is the source of truth. Editing this page has no effect; the next run overwrites it. Amend an SOP instead:

```bash
spira/sop.sh write <slug> -   # text on stdin
```

Statutes are how to behave; SOPs are how to fix. They share one mechanism, split by prefix — `law-` and `sop-` — so the [[spira]] Ops persona reads its runbooks exactly the way every agent already reads [[common-law]]. Ops is summoned by an incident bead filed from a failed systemd unit, matches the payload against the `MATCH:` lines below, and executes the first one that fires.

**20 SOP(s)** on the shelf as of 2026-09-08.

## The closing rule

**An incident resolved without an SOP must produce one.** This is `law-bake-rules-into-tools` applied to production, and it is enforced rather than asked for: writing an SOP is what regenerates this page, the regenerated page is the commit that names the incident bead, and a bead closed with no commit naming it is reopened by `aeon.sh`. An incident fixed by hand and forgotten does not close.

## The shelf

### Content landed reopen

`sop-content-landed-reopen`

**Symptom** — bead reopened repeatedly by CHECK 5 despite work being content_landed

**Check** — verify bead has content-landed label and CHECK 5 skips reopening

**Fix** — sending.sh adds content-landed label after reaping; sentinel.sh CHECK 5 reads it

**Escalate** — n/a

**Reference** — wiki/notes/standard-operating-procedures.md

**Matches** `closed bead with no commit naming its id, content-landed branch reaped`

### Destroy branch loses unlanded work

`sop-destroy-branch-loses-unlanded-work`

**Symptom** — a bead closes correctly (its fix commit names it on spira/<id>) yet the sentinel reopens it every time citing "no commit names it." The commit exists (`git show <sha>` succeeds) but is dangling, on no branch — the next summon's worktree is byte-identical to origin/main.

**Check** — `git branch --contains <claimed-sha>` empty + `ls $SPIRA_RUN/landstate/ | grep -c <bead-id>` -> 0 across every prior close.

**Fix** — root cause was sp-mqsl (spira_destroy_branch deleted unlanded work, no landed-check before `git branch -D` on reclaim/slay). FIXED, spira-harness commit 4b51363: spira_destroy_branch now resolves the repo's land ref (spira_landref) and refuses (REFUSED, like the existing holder/worktree refusals) when the branch tip is not an ancestor of it, before the reclaim/slay path can delete it. Commit is on spira-harness LOCAL main only, not yet on origin/main — landing it is tracked by sp-bvo7 (which already carries an earlier stuck local-main commit and the same dirty-tree/rebase job). Until sp-bvo7 lands, the underlying race is still live in the deployed code; a fresh occurrence of this symptom means check sp-bvo7's status first, not re-diagnose the mechanism.

**Escalate** — never — Ops's own tooling. If sp-bvo7 lands but the symptom recurs, that is new information worth its own incident.

**Reference** — sp-qj8n, sp-mqsl (fixed, spira-harness 4b51363), sp-bvo7 (landing), wiki/notes/destroy-branch-loses-unlanded-work-sop-2026-09-08.md

**Matches** `never appears in landstate|byte-identical to origin/main at start|dangling.*not on any branch`

### Env prefix left of pipe

`sop-env-prefix-left-of-pipe`

**Symptom** — a variable meant to configure the READER of a pipeline (`VAR=x cmd1 | cmd2`) never reaches it — cmd2 sees its own defaults. watchtower.sh set SPIRA_INCIDENT_TYPE/PRIORITY/ACTOR on the LEFT of `snapshot | bash incident.sh file ...`; each side of a pipeline forks its own subshell before assignments apply, so incident.sh always read its hard-coded defaults (`--type bug --priority 1`, actor unset). Every routine sweep filed as a P1 bug wearing the operator's name instead of a P2 chore.

**Check** — reproduce generically before touching the suspect script — `bash -c 'f(){ echo hi; }; V=chore f | { echo "RHS sees V=[${V:-UNSET}]"; cat >/dev/null; }'` prints `UNSET`. Grep the suspect file for `VAR=... \` lines immediately above a line containing `|` — that shape is the bug regardless of which script it is in.

**Fix** — move the prefix onto the RHS command that actually needs it: `snapshot | VAR=x bash reader.sh args`. Verify with the same reproduction pattern, RHS-prefixed: `echo x | V=chore bash -c 'echo $V'` prints `chore`. Never fix by exporting the vars earlier in the script instead — that leaks scope into everything after the pipeline, wider than the one command that needed it.

**Escalate** — never — this is a shell-scoping defect, always Ops's to fix directly.

**Reference** — sp-b9qs

**Matches** `VAR=x.*\| bash|env prefix.*(left|right) side of a pipe|assignments scope to cmd1 only|prefix on the LEFT of a pipeline`

### Escalation body is a slug

`sop-escalation-body-is-a-slug`

**Symptom** — an ask reaches the operator's pane titled with a mangled identifier — `incident:Spira-sweep-----is-the-pipeline-moving- has failed 5 times` — defaulting to "read <bead>", carrying no evidence. He replies he cannot decide from it. The alert fired correctly; what it SAYS is the fault.

**Check** — read the ask as HE sees it, not the bead behind it: `bd -C $SPIRA_DB show <ask-id> --json | head -c 600`. A title holding `incident:` with hyphen runs is a DEDUPE SLUG rendered as prose. Then `grep -n 'ASK" add' /workspaces/spira-harness/spira/*.sh`; the site is an `add` whose fields are all constants or `$ref`/`$id`, never one carrying `--evidence`.

**Fix** — build every field from the SUBJECT. Title = the bead's own title, the count, and the ELAPSED TIME it spans — a bare count cannot say whether 5 is an hour of noise or a fortnight. `--why` = what the subject is FOR. `--default` = a decision, never an errand. `--evidence-file` = the payload. TWO TRAPS: `--evidence-file` keeps the TAIL while vital signs sit at the HEAD, so pass a `head -c 2000` copy, not `$pf`; and incident.sh is read by byte offset while running, so patch beside and `mv`. Verify by RENDERING — stub `$ASK` to echo argv, `bash -x` the block.

**Escalate** — only if the fix changes WHETHER it fires. Muting or raising SIN_AT is his call.

**Reference** — wiki/notes/spira-sweep-sop-2026-09-08.md

**Matches** `has failed [0-9]+ times and Ops has not broken|incident:[A-Za-z0-9-]{20,}|not enough information for me to make a decision`

### Lake bucket missing

`sop-lake-bucket-missing`

**Symptom** — pokedumpster lake or ship work fails against s3://pkdump-lake-237707363372-us-west-2 with NoSuchBucket or AccessDenied.

**Check** — aws s3api head-bucket --bucket pkdump-lake-237707363372-us-west-2. A 404 means the bucket was never created; a 403 means the credential is the backup identity, not a lake identity.

**Fix** — there is none available to Ops, and that is by design. Both identities on this box (user/gantt-mtgc-backup and role/mtgc-backup) are scoped to backup duties and cannot CreateBucket. Do not widen them.

**Escalate** — it needs an admin credential for account 237707363372, which only Ryan holds. Say what is blocked and what is not, and stop.

**Reference** — wiki/notes/lake-bucket-sop-2026-08-10.md

**Matches** `NoSuchBucket|pkdump-lake|AccessDenied.*s3|CreateBucket`

### Mtgc unit failed

`sop-mtgc-unit-failed`

**Symptom** — an mtgc prod unit failed and fired its OnFailure alert. Every incident from the systemd intake starts here; triage before reaching for a fix.

**Check**

```
systemctl --user show <unit> -p Result -p ExecMainStatus -p NRestarts, then journalctl --user -u <unit> -n 40. Result= distinguishes exit-code from timeout from oom-kill, and the journal alone often does not say which.
```

**Fix** — resolve by Result. exit-code — read the command's own error, fix it, systemctl --user start <unit>, then confirm the NEXT scheduled run is green rather than the manual one. timeout — find what it waited on before extending anything. oom-kill or a disk error — see sop-root-disk-pressure.

**Escalate** — if the fix is a code change. Prod runs from /opt/mtgc-prod, a different checkout from /workspaces, so merging changes nothing on the running system and the deploy is a separate named step.

**Reference** — wiki/projects/spira/spira.md

**Matches** `mtgc-.*\.service|MTGC unit FAILED`

### Proc walk awk per hop

`sop-proc-walk-awk-per-hop`

**Symptom** — test-aeon-heartbeat.sh hangs or runs past its slice; `bash -x` sticks silently inside a `youngest_in_subtree`/`shf` call, no further trace. Not the orphaned-child-holds-pipe mechanism (sop-suite-hang-blocks-pipe) — nothing is left running.

**Check** — `bash -c 'sleep 3600 & wait' & outer=$!`; `time env -i PATH="$PATH" HOME=/tmp bash -c '. spira/lib.sh; youngest_in_subtree "$1" 0' _ "$outer"`. Multi-second wall time on a box with hundreds of live processes (`ls /proc|grep -c '^[0-9]*$'`) confirms it.

**Fix** — old code forked one `awk` per ancestor hop per pid (up to 40/pid) — cost scales with processes x depth x fork overhead, exceeding any timeout on a loaded box. Fixed in spira/lib.sh (spira-harness main, commit 0a53666 — push rejected non-fast-forward, rebase before it reaches other replicas): build the whole pid->ppid map with ONE awk pass, walk ancestry as bash array lookups. 4.8s -> 0.08s measured; suite 22/22 in well under its slice. subtree_has_flock untouched (few flock procs, cheap); batch it too if ever implicated.

**Escalate** — never. A push rejection here isn't one either — rebase and retry; systemd units run the working tree directly regardless.

**Reference** — sp-a8c5

**Matches** `youngest_in_subtree|subtree_has_flock|test-aeon-heartbeat.*(hang|timeout|never produced)`

### Reclaim loop on needs ryan block

`sop-reclaim-loop-on-needs-ryan-block`

**Symptom** — a bead is reclaimed and re-summoned every lease cycle although every session reaches the identical diagnosis: IN_PROGRESS, blocked purely on an unanswered needs-ryan sub-decision, nothing new. Each cycle burns a full aeon session re-deriving the same answer.

**Check** — `bd -C /workspaces/spira show <bead> --json` for status+labels; find the needs-ryan bead it cites and `bd show <ask-id> --json` for its status. Two-plus `sp-reclaim-N-refused` labels with the same diagnosis confirms.

**Fix** — check whether the blocker already closed — the loop may have resolved and the labels are stale; note that and close. If still open, this session cannot safely touch the reclaim cadence inside an Ops wall — link to sp-2k5a and stop, do not re-diagnose. Mechanism recon (CHECK 2's `bd reclaim --older-than 180m` in sentinel.sh has no needs-ryan exemption) and proposed fix shapes are on sp-rzyl.

**Escalate** — only if the blocking ask itself looks stale or wrong — reply in its own thread, never a second one.

**Reference** — wiki/notes/reclaim-loop-needs-ryan-sop-2026-09-08.md

**Matches** `reclaimed [0-9]+ times|sp-reclaim-[0-9]+-refused.*sp-reclaim-[0-9]+-refused|respawned [0-9]+x for one unanswered ask`

### Root disk pressure

`sop-root-disk-pressure`

**Symptom** — a unit died with ENOSPC, a bus error, or a disk check trip. The 98G LVM root runs production; /workspaces is a separate 938G disk that is nearly empty.

**Check** — df -h / /workspaces and du -xh --max-depth=1 / 2>/dev/null | sort -h | tail. Confirm the pressure is on / and not on /workspaces before touching anything.

**Fix** — clear agent scratch first — it is the usual culprit and it is free. If the container store is on /, run /workspaces/gt/settings/migrate-container-store.sh --preflight then --run; it refuses while any polecat is live, verifies row counts before restarting, and rolls back on any post-stop failure. Then restart the failed unit and re-run its check.

**Escalate** — if the space is production data rather than scratch, or if --preflight refuses. Never widen a disk threshold to quiet the check.

**Reference** — wiki/notes/container-storage-volume-sop-2026-08-11.md

**Matches** `No space left on device|ENOSPC|Bus error|disk.*(9[0-9]|100)%|diskcheck.*FAIL`

### Spira blind landing meter

`sop-spira-blind-landing-meter`

**Symptom** — a Spira sweep headed "minutes since the last landing ? (last: none recorded)". `?` means the pass COULD NOT READ it, never that nothing landed — conclude neither stall nor health. The four-figure gate wait beside it: same bead, also blind.

**Check** — read the records — `for f in $SPIRA_RUN/landstate/*; do echo "$(basename $f): $(cat $f)"; done`. Rows are `LANDED <tip> <epoch> <repo>`; `date -d @<epoch>`. A LANDED epoch minutes old under "none recorded" means blind meter, not stalled pipeline. All-RED with no LANDED means the queue really has produced nothing — go to sop-spira-no-rebase. Date the gate-wait row too: `wc -l $SPIRA_RUN/gate.log; tail -4`. Its max spans `tail -50`, so under 50 rows "recent" means "ever"; later `waited=0s` rows date it to a dead topology.

**Fix** — do not patch or re-file it from a sweep. Both meters are one harness bead, sp-86q8 (P0, repo:spira); confirm its state — `bd -C /workspaces/spira dep tree sp-86q8`. READY or IN_PROGRESS means queued, leave it: blindness costs a sweep, throttles no aeon (law-file-it-and-let-the-loop-fix-it). Closed means read its close reason. Absent or blocked is the only new work.

**Escalate** — nothing needs the operator. A BLIND HEADLINE IS NOT THE SWEEP — having shown the pipeline moves, go on to the verdicts and the poison list (sop-spira-verdict-not-executed). Put the real last-landing time and the gate-wait row's age in the close reason; one closed on an unreadable headline is indistinguishable from one that never looked.

**Reference** — wiki/notes/blind-landing-meter-sop-2026-09-07.md

**Matches** `none recorded|minutes since the last landing +\?`

### Spira no aeons

`sop-spira-no-aeons`

**Symptom** — a Spira sweep reporting "aeons alive 0" — with ready beads waiting, the shape sop-spira-sweep calls a summoning fault. A DELIBERATE HALT looks exactly the same, and so does an idle loop with nothing ready. All three render identically because the watchtower has no notion of an intentional stop.

**Check** — ask the sentinel's own journal, not the snapshot — `journalctl --user -u spira-sentinel.service --since -3h -o short-iso | grep Finished | tail -30`. A steady two-minute cadence with ONE clean gap is a halt somebody chose; confirm with `bd -C $SPIRA_DB list --status open -l needs-ryan`, since the halt is normally waiting on an operator verdict. Ragged or absent passes while `spira-sentinel.timer` is `active` is the real fault. `ready to claim 0` alongside is simply an idle loop.

**Fix** — a chosen halt is not yours to undo — the escalation holding it is the operator's to answer, and restarting underneath it discards the reason it was stopped. Say in the close which it was and name the bead. For a real summoning fault, read the sentinel's last pass for why it summoned nobody (pool exhausted, capacity paused, no fayth whose predicate matches the ready beads) before touching anything.

**Escalate** — never restart a deliberately halted world on your own initiative. If the blocking verdict looks stale, reply in that bead's thread rather than filing a second one.

**Reference** — wiki/notes/blind-landing-meter-sop-2026-09-07.md

**Matches** `aeons alive +0`

### Spira no rebase

`sop-spira-no-rebase`

**Symptom** — the landing pass reopens a closed bead — "does not rebase onto <base>" — its landstate row reading "RED <tip> <at> no-rebase". Nothing lands, and it does not self-limit: each reopen requeues the bead and the next pass reopens it again.

**Check** — cat $SPIRA_RUN/landstate/* — all-RED with no LANDED row is why the sweep renders minutes-since-last-landing as ?; never read that ? as zero. Take the conflict FROM GIT, never from file-existence: a path missing from base is equally "added by the branch" and "deleted by base". git -C <repo> worktree add -q --detach /tmp/reb <tip> && git -C /tmp/reb rebase <base>; read the CONFLICT lines; abort; worktree remove --force.

**Fix** — by the conflict git printed. CONTENT — apply law-duplicate-not-a-hard-merge: diff against base file by file, and if base holds the work, bd supersede <id> --with <successor> (a close reason alone the sentinel does not read, so it reopens) and delete the branch. MODIFY/DELETE — the branch predates a deliberate removal; usually only the dead file conflicts and the product change merges clean. Confirm that, keep the product change, drop the dead file. BRANCH GONE, bead open — the tip is dangling, awaiting gc: rescue it first with git -C <repo> branch <branch> <tip> and bd label add <id> branch:<branch>.

**Escalate** — when the deletion behind a modify/delete was a design change, not a tidy-up — dropping discards coverage somebody chose. Reply into the thread that owns it, never a second bead.

**Reference** — wiki/notes/landing-no-rebase-sop-2026-09-07.md

**Matches** `does not rebase onto|CONFLICT \(modify/delete\)|no-rebase`

### Spira strand ledger

`sop-spira-strand-ledger`

**Symptom** — a strand count you cannot resolve to a class, or a live aeon count disagreeing with the snapshot.

**Check** — `stranded (claimed, nobody home)` is the GHOST count, the only failure; `strand ledger, other classes` itemises the rest as `kind=n`. A `?` IS UNREAD, NEVER ZERO. Ghost `?` beside a numeric total is a collector predating the split: `cockpit-ensure.timer` restarts `spira-cockpit.service` within a minute of the code landing, so re-read once; if it outlives two passes suspect that timer, not this code. `?` on both: strands.json absent or unparsable. Classify a ledger with `SPIRA_RUN=<dir> cockpit.sh strands`, the collector's function. Keys are `<partition>:<kind>:<id>`, split FROM THE RIGHT: a partition may carry a colon. `empty` is a childless epic: nothing claimed, nobody dead. Match workers on argv[1] via /proc, not `pgrep -f`.

**Fix** — act only on `ghost`; every other class is a disposition, not a fault. For `empty`, READ THE EPIC'S BODY — one carrying a method says its children are filed, so the gap is an edge. strand-classify.py reads a bead's own `parent` FIELD, not dependency edges: `bd update <child> --parent <epic>` clears it, `bd dep add -t parent-child` does not; re-run `strand.sh` and require zero. An `escalated: <epoch>` entry HAS ALREADY ASKED — find it; if the subject never moved, or closed on `done`/`ok`, see sop-spira-verdict-not-executed.

**Escalate** — only when a disposition needs a decision; name the prior ask and reversal cost. Never escalate an unclassified count.

**Reference** — wiki/notes/strand-ledger-sop-2026-09-07.md

**Matches** `stranded \(claimed, nobody home\)|strand ledger, other classes|strands\.json|SP_STRAND|open epic with no children`

### Spira suite never run

`sop-spira-suite-never-run`

**Symptom** — (a) `list` shows LAST `-` AGE `-` for one suite. (b) RESOLVED 2026-09-08: nothing invoked `suites.sh run` at all. Operator verdict on sp-rmnw: install a timer, hourly cap. spira-suites.timer/.service now installed and enabled.

**Check** — (a) `ls --time-style=full-iso $SPIRA_RUN/suites/*.result` vs the suite's add-date in git log. (b) `systemctl --user list-timers spira-suites.timer` must show a real NEXT, not `-`; if absent, the defect recurred.

**Fix** — (a) nothing; close. (b) `cd /workspaces/spira-harness/systemd && ./install.sh` — re-applying an already-decided template to a box that fell out of sync is restoring drift, not a fresh decision (law-detect-drift-never-install applies to the first install, not a resync).

**Escalate** — only if the cadence itself must change; the hourly cap was the operator's explicit decision.

**Reference** — wiki/notes/suite-never-run-sop-2026-09-08.md

**Matches** `timed suites with no result yet [1-9]|never produced a result|LAST - and AGE -|Nothing invokes suites\.sh run`

### Spira suite red duplicate bead

`sop-spira-suite-red-duplicate-bead`

**Symptom** — two open bugs with the IDENTICAL title "<suite> is red in the timed suite run", read as suites.sh minting a bead per pass. Usually it is not. suites.sh already dedupes on `<suite>:<fingerprint>`, so a second bead means the FAILURE CHANGED, which files afresh by design.

**Check** — compare FINGERPRINTS, never titles — `bd -C $SPIRA_DB show <id> --json | python3 -c "import json,sys;d=json.load(sys.stdin);d=d[0] if isinstance(d,list) else d;print(d['external_ref'])"`. Different refs is different failures; confirm on each bead's own "N passed, M failed" line (49/1 vs 48/2 is a second assertion, not a repeat). Prove dedupe is live by recomputing the fingerprint NOW: `out="$(bash spira/<suite>)"; rc=$?; sig="$(printf '%s\n' "$out"|grep -F FAIL||true)"; printf 'rc=%s\n%s\n' "$rc" "$sig" | sed -e 's/[0-9]\{3,\}/N/g' | cksum | tr -d ' \t'`. A `sp-recur-N` label on the bead holding that ref is the dedupe WORKING.

**Fix** — `bd -C $SPIRA_DB supersede <old> --with <new>` — the older signature is a subset of the newer. A close reason alone the sentinel does not read, so it reopens (law-duplicate-not-a-hard-merge). Do NOT dedupe on suite name alone in suites.sh: that collapses a failure which GREW an assertion into a bare count, hiding the new one. Never fix the red itself; it is a builder's bead and blocks nothing.

**Escalate** — nothing. Fingerprints that genuinely MATCH is a real incident.sh defect — file it, do not decide it.

**Reference** — wiki/notes/suite-red-duplicate-bead-sop-2026-09-08.md

**Matches** `is red in the timed suite run|duplicate bead every run|suite:[a-z0-9.-]+:[0-9]{9,}|files a SEPARATE bead each time`

### Spira sweep

`sop-spira-sweep`

**Symptom** — the ten-minute watchtower sweep: vital signs, not a failure. EIGHT MINUTES; systemd kills you at the deadline. CUT BEADS for what you cannot finish.

**Check** — THIS BEAD'S METADATA MEANS NOTHING. sp-recur-N counts ten-minute intervals nobody closed, never failed fixes. P1/bug is a defect, not a severity. "Reopened by sentinel: no commit names it" means the last session was HEALTHY.

**Fix** — IS ANYTHING COMING OUT? Read $SPIRA_RUN/landstate/* yourself, never the headline (sop-spira-blind-landing-meter); all-RED with no LANDED is sop-spira-no-rebase. ARE THE WORKERS WORKING? Ready beads and no aeons alive, or in_progress with nobody home, is a summoning fault (sop-spira-no-aeons, sop-spira-strand-ledger). NEVER RUN THE MENU'S `suites.sh run` HERE — 420s against a 480s wall leaves no record; read `$SPIRA_RUN/suites/*.result` instead and confirm a red's bead by its FINGERPRINT, not its title (sop-spira-suite-red-duplicate-bead). "NO RESULT YET N" IS NOT N NEW SUITES — already escalated as sp-rmnw (sop-spira-suite-never-run). Name the scans you skipped. THEN COMMIT BEFORE YOU CLOSE, ALWAYS: a held SOP writes no page, and the sentinel reopens any bead no commit names. Commit the applied ledger or a note whose subject carries the bead id; verify `git log --all --grep=<id>` is NON-EMPTY before `bd close`.

**Escalate** — a `sin` LABEL ALREADY PAGED HIM, evidence-free. Find it (`bd list --status open -l needs-ryan`) and REPLY IN THAT THREAD, vital signs inline. All closed means `sin` owes no reply. Never a second bead.

**Reference** — wiki/notes/spira-sweep-clean-close-reopen-2026-09-08.md

**Matches** `Spira sweep — is the pipeline moving|minutes since the last landing`

### Spira verdict not executed

`sop-spira-verdict-not-executed`

**Symptom** — a verdict was given and nothing carried it out, or it did not STICK and the operator answered twice. Answering closes the ask and leaves the SUBJECT untouched, so an unexecuted verdict looks exactly like one never given. For poison the recommended default REPRODUCES THE ASK.

**Check** — confirm the SUBJECT moved, never that the ask closed. Read STATUS, LEASE and LABELS together — a bead an incident calls poisoned is often already cleared and running, and a live heartbeat settles that faster than any label. A close reason holding no verdict — `done`, `ok`, empty — is a dismissal: treat the subject as unmoved. Two identically-titled asks minutes apart is one durability failure, not two findings. For poison SEPARATE THE TWO COUNTERS: only `sp-attempt-N` poisons — `attempts_of` takes its highest and sentinel CHECK 4 dedupes solely on `spira-poison` being absent, so attempts >= POISON_AT with the label gone re-poisons in one pass.

**Fix** — execute it; operator-authorised, so do not re-ask. Clearing `spira-poison` alone schedules its recurrence: drop every `sp-attempt-N` label too, then the poison label. `sp-reclaim-N` counts dead WORKERS, documented at `reclaims_of` in lib.sh as feeding nothing that stops work, SO A BEAD WHOSE ONLY COUNTERS ARE `sp-reclaim-N` CANNOT RE-POISON — that residue is not worth an incident. Verify it reaches `bd ready` and is STILL there one pass later.

**Escalate** — only if executing now means something materially different. Same thread, never a second bead.

**Reference** — wiki/notes/verdict-not-executed-sop-2026-09-07.md

**Matches** `verdict on `sp-|accepted the recommended default|clear the poison|spira-poison|already decided on this`

### Suite hang blocks pipe

`sop-suite-hang-blocks-pipe`

**Symptom** — timed suites show `LAST -  AGE -` forever; `spira-suites.service` Result=timeout at ~900s. RECURRING 2026-09-08, 4x now (sp-a8c5, sp-3cb0, sp-g4u6): same suite, same diagnosis each time -- only `behind N of origin/main` grows.

**Check** — `journalctl --user -u spira-suites.service --since -6h | grep -c timeout`. `suites.sh list` -- first LAST=- AGE=- suite is the culprit. If it has a known fix commit: `git -C /workspaces/spira-harness merge-base --is-ancestor <sha> origin/main` -- unpushed local fix does nothing, the timer runs origin/main.

**Fix** — (1) a suite's background child outlives `timeout`'s kill, keeping suites.sh's capture pipe open (unhardened as of 2026-09-08). (2) a fix commit exists but never reached origin/main -- sp-a8c5's 0a53666 sits on spira-harness local main only, ahead 1/behind growing, dirty tree, unpushed. Landing it is out of scope for a brain-worktree Ops aeon under an 8-min wall; filed as sp-bvo7. BEFORE FILING AGAIN: check sp-bvo7 is still open (`bd -C /workspaces/spira show sp-bvo7 --json`) and note against it rather than minting a duplicate.

**Escalate** — never for the hang. Landing a stuck local fix in another dirty/diverged repo is a normal land, not an incident -- file against sp-bvo7 if already open, else file fresh.

**Reference** — sp-a8c5, sp-3cb0, sp-g4u6, sp-bvo7

**Matches** `timed suites.*never produced a result|Result=timeout.*spira-suites|start operation timed out.*suites`

### Synth wiki worktree

`sop-synth-wiki-worktree`

**Symptom** — `sop.sh write`/`synth`, run from an Ops aeon's own worktree of SPIRA_WIKI, renders the regenerated SOP page into SPIRA_WIKI's main checkout instead of the caller's worktree. The aeon's own tree stays unchanged (nothing to commit, bead reopens for no commit naming it) while main gets a live uncommitted diff any later `git add -A` there sweeps into an unrelated commit.

**Check** — from the aeon's worktree, `git -C "$SPIRA_WIKI" status --short` before running `sop.sh write`; if it is clean beforehand and dirty on `wiki/notes/standard-operating-procedures.md` afterward while the worktree's own git status stays clean, this is it.

**Fix** — upgrade sop.sh (this fix resolves OUT by comparing `git rev-parse --path-format=absolute --git-common-dir` of the caller's toplevel against SPIRA_WIKI's, writing into the caller's own toplevel on a match). If running an older sop.sh, workaround: `SOP_PAGE="$PWD/wiki/notes/standard-operating-procedures.md" sop.sh write ...` then `git -C "$SPIRA_WIKI" checkout -- wiki/notes/standard-operating-procedures.md` to undo the accidental write to main.

**Escalate** — never — this is Ops's own tooling.

**Reference** — sp-vu2t

**Matches** `sop\.sh synth writes into the main brain checkout|SOP_PAGE.*worktree|writes into the main brain checkout`

### Test bead no payload

`sop-test-bead-no-payload`

**Symptom** — Ops aeon summoned on a bead labelled `incident` titled literally "test bead", empty description, no comments, `issue_type: task`, no `external_ref`.

**Check** — `bd -C /workspaces/spira show <id> --json | grep -c external_ref` -> 0 confirms the fixture pattern. ALSO check `ls $SPIRA_RUN/landstate/ | grep -c <bead-id>`. A prior marker commit can exist (dangling, `git show <sha>` succeeds) yet be on no branch if landstate never got an entry for it — the bead reopens on "no commit names it" even though a correct commit was made, and that is a landing-gap fault, not this SOP's.

**Fix** — record `sop.sh applied`, then `git commit --allow-empty -m "<bead-id> — test bead: no payload, SOP sop-test-bead-no-payload applied, no code change needed"` before closing, or aeon.sh reopens it. If landstate is confirmed empty for this bead, say so in the close reason and cite the landing-gap incident instead of re-diagnosing the payload again.

**Escalate** — never for the payload. A landstate gap is Ops's own tooling to investigate — file it, do not chase it inside this bead's wall.

**Reference** — wiki/notes/test-bead-incident-sop-2026-09-08.md, sp-qj8n

**Matches** `"title": ?"test bead"|· test bead`

Related: [[spira]], [[common-law]], [[codified-judgement]]
