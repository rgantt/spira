# Spira

Spira is an unattended work loop. You decompose a design into issues in a dependency graph;
it summons short-lived agent sessions that claim one issue each, do the work in their own git
worktree, put the branch through a gate, land it, and reap what is left behind. Nothing is
long-lived except a handful of systemd timers.

It is built for a box that is not a build farm — one that may also be running production
services, CI runners and the operator's own session — and for an account whose rate-limit
window, not its CPU, is the real ceiling on throughput.

The three properties that shape everything else:

- **Deterministic before inference.** Every routine decision is a predicate over the issue
  graph and the commit graph. Judgement by a model is the last tier, reached only when every
  deterministic check has passed and work is still not moving. Adding a check is how the
  system learns; inference is a cost centre, not a feature.
- **Nothing durable lives in a session.** A worker holds a *lease*, not state. If it dies,
  the lease goes stale and the issue returns to ready. Crash recovery is a property of the
  substrate rather than of the agent.
- **Detection outranks rejection.** A gate that refuses bad work is worth less than a watcher
  that notices the pipeline has stopped. Thresholds only ever anticipate the outage you
  already had.

The substrate is **beads** (`bd`): a dependency-graph issue tracker over Dolt, which also
holds the harness's knowledge base — the statutes every agent reads, and the runbooks the ops
persona executes.

---

## Vocabulary

The names are from Final Fantasy X, and they are load-bearing enough to learn once.

| term | what it is |
|---|---|
| **bead** | one issue in the graph — the unit of work, with an id, labels, dependencies and a lease |
| **fayth** | a persona *definition*: a predicate carving its partition out of the graph, the statutes it reads, the tools it may use, a model, and what wakes it |
| **aeon** | one summoned *instance* of a fayth. It claims a bead, works it, closes or fails it, and exits |
| **the chamber** | `spira/chamber/` — where the fayths live, one `.fayth` (the definition) and one `.md` (the brief) per persona |
| **the sentinel** | the reconcile loop: compare current state to goal state, close the gap |
| **the Cloister** | the landing gate a branch passes before it may merge |
| **the Sending** | reaping the branch and worktree of work that has landed |
| **a pilgrimage** | an epic; it completes when every child has closed |
| **a Sin** | an incident class that keeps recurring because no runbook has broken the cycle |
| **poison** | a bead that has failed its attempt ladder and will not be retried |

A **party member** (`FAYTH_ROLE=party`) travels with you and is always around; a **task fayth**
is summoned for one encounter and dismissed after it. Only task fayths draw on the aeon pool,
so a persistent role cannot be crowded out of it by workers holding slots for an hour.

---

## The loop

Seven timers, each doing one thing, none waiting on another.

| unit | cadence | what it does |
|---|---|---|
| `spira-sentinel.timer` | 2 min | reconcile the graph — the checks below |
| `spira-ops.timer` | 5 min | summon the ops persona for any waiting incident |
| `spira-auron.timer` | 2 min | watch the sentinel — escalate if the loop has stalled |
| `spira-watchtower.timer` | 30 min | read the pipeline's vital signs and file them as work ops claims |
| `spira-skew.timer` | 1 h | is the harness in force the harness that landed? |
| `spira-suites.timer` | 1 h | run every test suite the landing gate does not |
| `spira-archivist.timer` | 5 min | rescue a session's unfinished business before it is cleared |

`spira-archive.timer`, `spira-watch-refresh.timer`, `spira-watch-notify.timer`,
`cockpit-ensure.timer` and `beads-push.timer` keep the surrounding machinery honest —
transcripts archived, watchers running current code, unread events escalated, the operator's
panes repaired, databases pushed to their remotes.

### The sentinel's checks

Each is a deterministic predicate that names the single action closing its gap.

1. **Completed pilgrimages** — an epic whose children have all closed is announced and closed.
2. **Dead workers** — a stale lease is reclaimed. Three cases, because they fail differently:
   a lease that has simply expired; a holder that `/proc` says is gone; and an orphaned claim
   whose bead is held by nobody at all.
3. **Stale blocked flags** — `is_blocked` is a cached column and goes wrong after an edit.
4. **Poison** — a bead past its attempt ceiling stops being retried and is escalated instead.
5. **Closed but not landed** — a bead closed with no commit naming it unblocks its dependents
   on a promise nobody kept. It is reopened. *Closed is not landed*, and the gap between the
   two is where most wrong answers about this system come from.
6. **Landing** — dispatched to its own process (see below), plus the Sending, plus a sweep of
   work parked on CI.
7. **Idle capacity** — ready work and a free slot is the whole point. The pool
   (`SPIRA_MAX_AEONS`) is drawn down in the order personas are named, and an *elastic* persona
   takes whatever is left once everyone else is seated.
8. **Judgement** — everything above passed, work remains, nothing is ready and nothing is
   running. Only here does a model get asked what is wrong. It gates on whether the graph
   actually *moved*, never on whether the pass wrote something: gating on writes lets every
   futile action mute the one check that notices paralysis.

### Auron watches the sentinel

`spira/auron.sh` is the watchdog over the loop. Its only power is speech: it reads timestamps
and counters, compares them to thresholds, and raises or clears an alert bead. It repairs
nothing, restarts nothing and summons nothing — a watchdog that can act is a second
controller with no supervisor of its own. It fires on sentinel pass staleness (no completed
pass in ten minutes), summon starvation (ready work, free capacity, nothing summoned across
two consecutive checks), a database that has not been reachable, and an aeon holding a lease
with no live process past expiry. It writes a heartbeat after every completed pass so the ops
pane can show its own age — a silent watchdog and a healthy system are otherwise
indistinguishable, and the pane would render the healthy reading.

### Landing is a separate process, and its unit name is the mutex

An ordinary sentinel pass is a handful of queries. A landing pass fetches, rebases, runs a
repository's whole gate and pushes — minutes, not seconds. Left in the loop it starved the
check below it, so a free slot sat empty with work ready. It runs as a transient systemd unit
with a fixed name; systemd refuses to start a unit that is already active, so a pass arriving
mid-landing declines and moves on. No lockfile, no pid file.

Fire-and-forget needs a positive control, because "nothing landed" and "the landing worker
never ran" look identical from outside. So it writes a status file (when it finished, its exit
code, how many branches it actually *saw*) and an append-only progress mailbox the sentinel
drains on its next pass.

---

## The life of a bead

1. **You file it.** Labels put it in a persona's partition; a `repo:<name>` label says which
   repository the work belongs to. A bead may also name the persona it wants — that narrows,
   it never widens: the partition still decides whether the work is yours, and the preference
   decides only that it is not somebody else's.
2. **An aeon claims it** atomically (`bd ready --claim`, never select-then-claim, which races
   every other aeon) under a lease with a TTL the persona sets.
3. **It gets a worktree** cut from that repository's declared base ref, and a brief assembled
   from the persona's `.md`, the statutes in force, and the bead itself.
4. **It works.** A heartbeat refreshes the lease, but only while something *observably moves*;
   a persona that goes quiet for `FAYTH_STALL_BEATS` checks stops heartbeating and its lease
   expires. There is deliberately no wall-clock ceiling on the worker persona — a clock cannot
   tell slow from stuck, and killing on one charges an attempt for being legitimately long.
5. **It commits, naming the bead id**, cuts the review, and **exits**. An aeon does not sit
   watching CI. It labels the bead and the sweep raises its priority when CI comes back red or
   releases it to land when green.
6. **The gate judges the branch.** Four outcomes, and only one of them blames the branch.
7. **The landing pass merges or opens a pull request**, per the repository's declared mode.
8. **The Sending reaps** the branch and worktree once a commit on the base branch names the
   bead — and nothing else.

---

## Personas

Three ship in the chamber. Adding a fourth is two files, not a code change.

**Builder** — the only persona that writes code. Its partition is deliberate plan work and
nothing else, so it can never claim beads imported from somewhere alongside them. Elastic, and
therefore named last: it takes whatever the pool has left. It reads statutes only — runbooks
are for a persona that will execute one, and a shelf of them would push the law it *does* have
to obey off the end of the context budget.

**Ops** — the healer, and the only persona whose work arrives from outside the plan. Incidents
are filed by a systemd `OnFailure=` hook, never by hand; sweeps are filed by the watchtower. It
reads both books, statutes and runbooks. It is a party member with its own summoner, so it is
never starved by workers holding slots. Its session is walled to comfortably less than the
sweep cadence: a session must end before the next snapshot arrives, and findings it cannot
finish are cut into beads rather than lost.

**Spike** — researches one question to a costed document and carries no conversation.
Feasibility research is the worst thing to do inside a long-lived session: it reads heavily,
almost nothing it reads is needed once the question is answered, and every page stays in
context and is re-read on every later turn. A spike starts at the floor, reads, writes one
document, and exits — the conversation gets the document, not the reading. It has the full
toolset including an editor, because for most interesting questions the only honest answer to
"is this feasible" comes from trying it; the discipline is in the deliverable, and
`confine.sh` enforces it at the gate: **a spike may leave a branch and must not leave a merge.**

### Two mechanisms worth knowing

**The fence on the predicate.** An installation that imported a predecessor's beads has a ready
queue full of work that predecessor is still doing. A persona whose predicate is too loose
refuses to claim *at all* rather than trusting a config string to be right.

**The closing rule.** A persona may declare that its work is not resolved until something is
written back to the shelf. Ops does: an incident closed without a runbook coming out of it has
its close undone, the bead reopened and marked poison, and the reason written on it. Recording
the truth is always the cheapest way out — "it matched, it held, it taught us nothing new" is a
complete outcome, and so is "it did not hold". Only silence is outlawed. That is declared in
the persona, not keyed on a persona's name in the runner, so it binds the role rather than the
string.

---

## Landing

Each repository declares, in `repo-map`, the checkout an aeon may work in, the ref its work is
cut from and judged against, how it lands, a formatter, and the gate command it must pass.

**Never assume the base branch is `main`.** It is declared rather than derived because every
automatic source is a local cache: the remote-HEAD ref is written at clone time and can be
stale or absent, and the checkout's own HEAD answers whatever branch a human last looked at.
This bug is worth fixing once rather than four times.

**Three landing modes**, and the column also decides whether there is a CI run to wait for:

- `push` — merge into base and push. The branch is the release.
- `pr` — push, open a pull request, arm auto-merge, and let the repository's own CI be the
  authority. Green pull requests merge themselves.
- `hold` — gate it, note it once, and leave the branch for a human. For a repository this
  harness has no business advancing.

Only `pr` opens a pull request, so only `pr` has CI. A bead parked on CI under `push` or `hold`
waits for an event that cannot occur — and because the park label is excluded from every
persona's predicate *and* from the stranded-work report, that wait would be invisible as well
as endless.

**The gate is deliberately cheap and mechanical.** A gate that needs judgement is not a gate,
it is a review. One layer is universal — a shell script that does not parse is the commonest
way an unattended change breaks a harness — and everything else is the repository's own
declared command.

**It fails closed, and failing closed is not the same as blaming the branch.** Four exit
outcomes: `PASS`, `FAIL`, `BASE_FAIL`, `NO_VERDICT`. Nothing lands under the last three, but
only `FAIL` says the branch is at fault and only `FAIL` may cost it an attempt. Conflating them
poisons good beads and pages the operator about work that was fine.

This repository's own gate checks the *pipeline*, not the code. What this system **is** is N
workers pulling from a graph into a merge queue, and every failure it has had is a property of
that pipeline — two things running at once, a lock, a queue that stopped moving — never a
function returning the wrong value. So the gate is the fences that guard the irreversible,
which are sub-second and which nothing routes around, plus a soak that reproduces a merge-queue
livelock against the old code and shows it gone.

It replaced a 17-minute, 43-suite gate that, on the day the pipeline spent a morning unable to
land anything, found zero real defects and produced two failures — both of them suites reading
the state of the box rather than the code. Being 17 minutes long it was also most of the
contention that made the shared worktree worth locking, and that lock is what livelocked the
queue. The three real defects that day were found by tests written for the specific change, in
minutes, and by a 20-second soak — neither of them in the 17 minutes.

---

## Keeping it inside its means

| program | question it answers |
|---|---|
| `governor.sh` | how much of this machine may Spira use, and what did it get for it |
| `capacity.sh` | is the account's window shut, and which attempts did that cost |
| `tokens.sh` | what the account actually spends, and on what |
| `attempts.sh` | what every claimable bead is carrying on the retry ladder, and why |
| `yield.sh` | what the gate is *worth*, recorded beside what it costs |
| `ctx-meter.sh` | how much context a session is carrying and how close that is to the edge |

The governor is a deterministic function of what `/proc` says, averaged over the interval since
the last pass and folded into a moving average across passes — a single two-second sample lands
on or between a test suite at random and produces budgets of 0, 1 and 2 within minutes at a
constant worker count. It only ever *withholds*: a persona's own concurrency stays the ceiling
and the governor is the floor.

Attempts charged during an account outage are false attempts and are given back — but only
where the evidence still exists. Reclassification refuses to reason about the rest, and prints
the same evidence so the refusal is checkable rather than asserted.

---

## Watching, and being answered

**Watchers are rows in a manifest**, not unit files. `spira/watchers` is the single source of
truth for what should be watching; the installer renders one systemd unit per row and disables
any instance whose row has gone. The contract a reader latches onto is two files per watcher and
nothing else — an append-only log and an integer cursor — so `tail -n +$((cursor+1)) -F` is a
conforming client, and a session attaches to a file rather than owning a process.

A row may carry a **health assertion**: a command that must exit 0 for the watcher to be
reported healthy. It exists because *a watcher reports silence identically whether nothing
happened or it is looking at the wrong thing.* A process listing, an `is-active` and an unread
count are all silent for a watcher reading a database that was retired underneath it. So the
assertion asks what discriminates — does this watcher's own state name a single bead of *our*
prefix — rather than whether the process is up.

**The attention panel** (`cockpit/`) is a terminal UI over the beads that want a human:
decisions, FYIs, notifications and alerts. It exists because chat is a log and a log cannot
hold an open question. A verdict is written *into the bead* — the close reason is the answer —
never to a side-channel log, so any session can read what was decided.

Nothing in that pane closes an alert. An alert is a condition that self-clears, so the only
thing that may retract it is whatever asserted it; a hand-closed alert whose condition is still
true comes straight back, which teaches the operator that acting on the pane does nothing —
exactly how a pane becomes wallpaper.

**An escalation is a decision request, not a problem report**: the decision as a question with
a default, what is blocked until it is answered and what is not, and what it costs to reverse
the wrong choice. `cockpit/ask.sh` files one. A default is close to mandatory — an ask without
a recommendation makes the operator decide from scratch, which is what the escalation path
exists to prevent.

The strongest dedupe is *is it already in front of them*, not a clock and not a stamp file. A
clock re-asks a question already on the screen; a stamp file answers a question about this
box's memory rather than about their queue. So the queue is asked. An ask they have already
*closed* does not suppress a new one — a closed ask is an answered question, and the condition
recurring after an answer is new information.

**A failed probe renders `?`, never 0.** A panel that reports a broken check as all-clear
displaces the suspicion that would have prompted a look.

**Loom** (`loom/`) is a read endpoint over the live graph and a page that renders it — one
route, the raw rows plus their dependency edges, everything else derived in the browser. Its
query carries a **budget**: a query that overruns is refused rather than served late, because
serving a stale snapshot instead would be kinder to one reader and fatal to the design — it
hides the one signal that says a query per request has stopped being cheap enough. It refuses
to start without a database rather than letting `bd` discover one from its working directory,
which would come up healthy serving a different harness's graph.

**The archivist** (`archivist.sh`) rescues a session's unfinished business before it is thrown
away — questions asked and never answered, findings stated and never filed, verdicts acted on
and never recorded. Context is re-read in full on every turn, so a long session costs many times
a fresh one for identical work, and the fix is exactly what nobody dares do: the session nearest
the ceiling is also the one carrying the most that was never written down. It reads the
transcript from disk rather than the conversation, so it costs the session it is rescuing no
turn, no tokens and no interruption. That is the design constraint, not an optimisation — a
persistence step that adds turns makes the problem worse every time it runs, and worst in the
sessions that need it most.

**`skew.sh`** asks the question nothing else does: is the harness in force the harness that
landed? A second copy of the harness inside a repository is how work aimed at the harness can
land in it, pass its gate, and never run.

---

## The statute book and the shelf

Two bodies of written knowledge, stored and delivered the same way — `bd remember` / `bd
recall`, split by key prefix, injected into an agent's session at summon. A persona declares
which prefixes it reads.

- **Statutes** (`law-`) are how to behave. `rule.sh enact <slug> "<text>"` is one command,
  because a rule that depends on remembering a second step is a resolution, not a mechanism.
  `retire` is the other half, and retiring is as deliberate an act as enacting: a superseded
  statute left standing with a correction attached is the same defect as a correction banner on
  a stale page.
- **SOPs** (`sop-`) are how to fix. `sop.sh` writes, matches, recalls and synthesises them.
  An SOP has a *shape* — a match expression, checks, steps — and the program refuses prose,
  because a runbook written as a paragraph cannot be matched to an incident by a program or
  executed without being re-interpreted.

Write them to be read a thousand times: one paragraph, imperative, the scar as a single clause
rather than a narrative. Every agent pays that context on every session, and `enact` refuses
anything over 130 words for exactly that reason.

The statutes in `spira/statutes/` are the seed set a fresh installation starts with; `seed.sh`
writes them into your database on install and never overwrites a key you have amended. They
cover the machinery only — a rule naming a repository, a deploy path or an operator's own
preferences stays in that operator's database and does not ship.

**A rule tightens when it is re-violated**, not when it is annoying: practice → written down
once → statute every agent reads → a program that refuses. A program that refuses is a *fence*
— a polite refusal, not a wall — so every guard names its own override, and every guard binds
the actor that actually violated the rule. A guard on a shared path binds whoever is most
disciplined about using that path, which is usually the automation, and misses the offender.

---

## Getting started

You need `bd`, `git`, `flock`, `python3`, and whichever coding-agent CLI your personas name.
`cargo` is optional — without it you lose the attention panel, not the loop.

```sh
git clone <this repo> spira && cd spira

mkdir -p ~/.config/spira
cp spira.conf.example    ~/.config/spira/spira.conf    # then edit it
cp spira/repo-map.example ~/.config/spira/repo-map     # your repositories, one row each
$EDITOR ~/.config/spira/spira.conf

bd -C <your SPIRA_DB> init   # a database, OUTSIDE any checkout
spira/doctor.sh              # what is missing, all of it, in one read-only pass
spira/seed.sh                # write the shipped statutes into that database
systemd/install.sh           # render the unit templates for this box and start the timers
```

Keep the database outside every repository. It accumulates internal working notes and agent
memories, and a path inside a checkout is one `git add -A` away from publishing them.

`doctor.sh` is read-only and names every missing program, unreadable database and unmapped
repository in one pass, distinguishing *fatal* (the loop cannot run) from *warn* (one feature
is off). It exists because a harness that dies with `command not found` from a systemd timer
has told you nothing: not which program, not what it is for, not where to get it, and not into
a log anyone reads.

The units in `systemd/` are **templates**, not units — every path is a placeholder filled from
your configuration. Never edit an installed unit; edit the template and re-run the installer.
`install.sh --diff` tells you when somebody did.

### Running it

```sh
spira/world.sh status        # what is up, what is down, what is running
spira/world.sh stop          # halt the loop: no summons, no landing, no live workers
spira/world.sh start

spira/sentinel.sh --report   # the gap, changing nothing
spira/strand.sh report       # work that exists and is not moving, with the reason
spira/watchtower.sh --show   # the pipeline's vital signs
spira/suites.sh list         # every suite, where it runs, what it claims to cover

spira/slay.sh <bead-id>      # stop one aeon cleanly and make its bead say what is true
spira/hold.sh <bead-id>      # claim a bead for a non-aeon actor
spira/release.sh <bead-id>
```

`world.sh` deliberately does not touch the databases — stopping the loop must never risk the
data, and a stopped database makes every diagnostic you are about to run fail — nor the panes
the operator is reading, because halting the loop must not also blind the person halting it.

---

## Configuration

**One surface: `spira.conf`.** Every path, name and label the harness touches resolves through
it. Three sources, first to speak wins: the **environment** (which is how every test suite
drives a fixture, and what keeps a suite from pointing at your real database), then the
**config file**, then a **default derived from where the harness is installed** — so a clean
clone with no configuration at all still resolves to something coherent rather than to someone
else's box.

It is **parsed, not sourced.** A config file that is shell can set `PATH`, run a command, or
shadow a library function, and it is read by a process that summons agents. `KEY = value`,
`#` comments, an allowlist of keys, and an unrecognised key is *reported*, not obeyed — a typo
silently ignored is a setting you believe is in force.

Two keys are deliberately **not settable from the file**: where the harness *is* is a fact
about where its loader sits, not a configuration question. The gate extracts a branch to a
scratch tree and runs that tree's own suites; a config that could point them back at the
installed copy would make the gate test the code already in force, and pass.

The other files you own:

| file | what it says |
|---|---|
| `repo-map` | `repo:<label>` → checkout, base ref, landing mode, formatter, gate |
| `spira/chamber/*.fayth` | your personas: partition, model, concurrency, lease, tools |
| `spira/watchers` | what should be watching, one row per watcher |
| `spira/inventory-deny` | extra names the publish fence must refuse. Ships empty |
| `spira/actors`, `spira/prefix-map` | only what the graph cannot vote for itself |

The last row is the rule the map files follow: **derive what can be derived, and keep a file
only for what cannot.**

---

## Two fences on this repository

This repository is meant to be cloned by people whose infrastructure is not yours, and two
checks run from its own gate to keep it that way.

- `spira/exclude.sh` — a beads database is never public. It accumulates internal working notes,
  agent memories and the operator's own judgement, and a path inside a checkout is one
  `git add -A` away from publishing them. The check, a pre-commit hook, and the installer that
  arms both.
- `spira/inventory.sh` — refuse to ship one operator's infrastructure: absolute paths rooted in
  a home or workspace directory, real e-mail addresses, provenance marks naming a person and a
  date, plus whatever you add. **It scans comments rather than stripping them**, because that
  is where all of it was: a version that stripped them passed a tree naming seven repositories,
  a host and a person across ninety lines.

Ship the **mechanism** — the rule, the trap, the reason a guard fails closed. Do not ship the
**inventory** — a repository name, a deploy path, a host, a person, a bead id, the date an
incident happened. Those teach a colleague's agent to reason about a machine that does not
exist, and sometimes to act on it.

---

## Repository layout

<!-- BOUNDARY:BEGIN -->

### Ships in `spira` — the harness

Generic mechanism. A colleague clones this and it carries none of the operator's data.

| path | what it is |
|---|---|
| `spira/` | the harness proper — aeon runner, sentinel and its checks, gate, governor, sending, strand, drain, the chamber and its fayth format, lib.sh, and the test suites that hold them |
| `spira/boundary` | this manifest — it describes the harness, so it travels with it |
| `spira/boundary.sh` | renders this manifest into every document that publishes it; the wiki-side target is configured and skipped when unset, per rule 2 |
| `spira/conf.sh` | the one configuration surface: the loader, the key allowlist, the derived defaults, and `spira_require`, which names a missing program instead of dying as a shell error |
| `spira/repo-map.example` | example rows showing the six columns. The real rows are operator data |
| `spira/prefix-map` | id-prefix to repo: label, for prefixes no export can vote for. Ships because the mechanism does; its rows are one installation's history and are meant to be replaced |
| `spira/exclude.sh` | keeps the beads database and its exports out of this repository — the check the gate runs, the pre-commit hook, and the installer that arms both. A beads database is never public |
| `spira/hooks/` | the pre-commit hook itself, TRACKED and armed by core.hooksPath. .git/hooks is not cloned, so a hook that lived there would reach a colleague missing and unannounced |
| `spira/inventory.sh` | the fence that keeps one operator's infrastructure out of a repository meant to be cloned — repository names, hosts, paths, people, dates. It scans comments, which is where all of it was |
| `spira/inventory-deny` | the tokens that fence refuses beyond the structural ones. Ships EMPTY: a list of somebody else's names is itself the inventory |
| `spira/actors.example` | commit author to harness, for authors the commit graph cannot vote on. Its rows are one installation's roster |
| `spira/gate-select.sh` | which suites a changed-file list needs, read from the `# covers:` line each suite declares about itself. Every uncertain case selects everything — the only wrong answer here is too few, and too few is green |
| `spira/gate-full.sh` | the meter under that selection: runs the whole suite set against the ref everything lands on, daily, and escalates on red. A hand-kept map decays silently, so it is checked rather than trusted |
| `spira/skew.sh` | is the harness in force the harness that landed — the hourly check that the executing copy is current, clean and the only one, and the landing gate's fence against work landing in a copy nothing executes |
| `spira/doctor.sh` | read-only preflight — every missing program, unreadable database, unmapped repository and unbuilt panel, named in one pass |
| `spira/statutes/` | the SEED statute book, one file per statute. Statutes live in the beads KV store, which is per-installation, so a clone gets the mechanism and none of the law unless it ships as text |
| `spira/seed.sh` | writes those statutes into a fresh database, and never over one already in force |
| `cockpit/` | the decisions panel (Rust) and the ops pane — how a human sees what the harness is doing and answers what it asks. Generic; it reads whatever database it is pointed at |
| `systemd/` | unit TEMPLATES plus install.sh. The units in force on a machine are generated from these, never edited in place |
| `concierge.sh` | one named Remote Control session, so a phone can reach the harness |
| `rule.sh` | enacting a statute writes the beads KV store, which is the harness's substrate |
| `spira/archive.sh` | keeps every session transcript and indexes it by time range and by the lineage id that survives a clear. The mechanism ships; the transcripts and the store they land in are the operator's own and stay out of every repository |
| `beads-push.sh` | pushes the beads database to its configured Dolt remote. The mechanism ships; the remote it is pointed at is the operator's own and is private |
| `spira.conf.example` | the annotated template an operator copies to spira.conf. Every key optional, every default derived from where the harness is installed |
| `README.md` | the harness's own entry point, carrying this table |
| `AGENTS.md`, `CLAUDE.md` | how an agent works ON the harness. Distinct from the wiki repository's own agent instructions, which are how an overseer works WITH it |

### Stays in `brain` — the wiki

Everything whose write target is a page. It may read the harness freely; the harness may not require it.

| path | what it is |
|---|---|
| `wiki/` | the operator's knowledge base: pages, journal, projects, notes |
| `raw/` | source documents, and any JSONL mirror of the database kept in a PRIVATE repository |
| the wiki's own agent instructions | its catalog, its chronological log, and how an overseer works with the harness |
| a tasks generator | regenerates a page listing the beads that need the operator |
| a statute-book generator | regenerates the readable copy of the statutes in force |
| its cron wrapper | runs that generator on a timer and commits only on substantive change |
| a beads exporter | writes the JSONL mirror into a private repository |
| a bead-table generator | regenerates a plan table on a wiki page from the bead graph |
| that repository's own gate | one repository's landing gate, named by its row in repo-map. Every repository declares its own |
| a checkbox ticker | ticks a checkbox on the wiki page that holds it — the one cockpit tool that writes a page |
| its session guards | PreToolUse fences for the overseer's own session. A guard binds the actor who broke the rule, so they live with that actor |
| its session settings | that session's own hooks and environment |
| its skills | whatever lands its output in the wiki |

### In neither repository — data

It belongs to whoever runs the harness. No shared repository holds it, and no beads database is ever public.

| path | what it is |
|---|---|
| the beads database | served by Dolt, addressed as a path. It accumulates internal working notes and agent memories, so it is never public and never in a shared repo |
| the statutes in force | rows in that database's KV store, per-installation. A wiki may render a read-only copy; the harness ships SEED statute text an installer writes into a fresh database |
| `spira.conf`, `repo-map` | the operator's real paths, repositories and personas. The examples ship; these do not. Both are gitignored, and spira.conf is looked for outside the checkout first for that reason |
| the systemd units in force | rendered from systemd/ templates by install.sh, filled from spira.conf. Never edited in place — `install.sh --diff` is how you find out somebody did |
| the transcript archive | compressed session logs plus their index, written by archive.sh. They carry paths, credentials read aloud and everything anyone ever said, so they live outside every checkout and no shared repository holds them. Nothing deletes them: retention is the operator's decision |
| `.runtime/` | logs, worktrees, leases, cockpit state. Regenerated, machine-local, gitignored |

<!-- BOUNDARY:END -->

---

## Tests

`spira/test-*.sh`, discovered by glob and never from a list — adding one puts it in the timed
set automatically. `spira/gate-suites` names the few the landing gate runs on every branch, each
with the reason it earns the wait; everything the glob finds that the list does not name is run
by `suites.sh` on a schedule, which files a bead per failure and blocks nothing. The two sets
cannot be edited into overlapping, and a deleted suite stops being run with no edit anywhere.

Every suite declares what it covers on a `# covers:` line. Three properties the existing ones
have and a new one should too:

- **A check that finds nothing must first prove it could have found something.** Plant an
  offender, require the matcher to say so, and only then believe it when it is silent.
- **Test against the real dependency** on a throwaway instance (`spira/testdb.sh`), never a
  hand-written model of it. A stub reproduces the surface you remember, so its gaps surface as
  failures in correct code.
- **Run in an explicit, minimal environment.** `hermetic.sh` refuses a suite that reaches the
  real box: ambient configuration silently decides verdicts, and a suite that inherits a real
  config is asserting about one machine.

---

## Four facts that most often produce a wrong answer

- **A bead is closed when an agent says the work is done; it has landed when a commit on the
  base branch names its id.** Different claims. Verify with an ancestry check, never by
  comparing tip SHAs — a tip moves under you.
- **The base branch is not always `main`.** Ask for it; never assume.
- **Ready sees bead status, not merge state.** A bead can be ready while its prerequisite
  exists only in an open pull request, so ready-but-unstarted is often correct sequencing.
- **A check that reports success is not evidence the thing works.** Before believing a green
  signal, ask what it would look like if the check itself were broken. On the day this system
  took over, eleven of fourteen defects were in the checking machinery rather than the work.

---

## Prose, and why the comments are long

Every comment in this codebase exists because something failed in a way that was not obvious
from the code, and the next reader is entitled to know which. State the rule first, then the one
clause of why. Never leave a correction on top of a wrong statement — say the thing as it now
stands.

`CLAUDE.md` is the guide for an agent working *on* this harness. The brief an aeon gets when the
harness summons it comes from a persona in `spira/chamber/`, not from that file.
