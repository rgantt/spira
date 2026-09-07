# Spira

A small agent harness. Beads is the substrate, statutes are the shared spine, systemd is the
outer loop. It runs one or two coding agents plus standing role personas across every
repository you point it at, rather than one crew per repository.

A timer wakes every couple of minutes and runs a short list of deterministic checks over the
bead graph — is anything ready, is a lease dead, did a branch land, did a gate go red — and
reaches for a model only when every check has passed and the world is still wrong. Work is
claimed by an *aeon*: a stateless session summoned from a persona file, holding one bead
under a lease, doing the work, opening the pull request, and exiting. Nothing sits watching
CI; the sweep does that, and brings the bead back when there is something to decide.

## What you need

| program | why | without it |
|---|---|---|
| `bd` ([beads](https://github.com/steveyegge/beads)) | the substrate — every unit of work, every statute | nothing runs |
| `git` | every repository operation | nothing runs |
| `python3` | every JSON payload the harness parses | nothing runs |
| `dolt` | the SQL server beads stores its database in | `bd` cannot reach a database |
| `gh` | opening and landing pull requests | repositories whose land mode is `pr` cannot land |
| `claude` | the agent an aeon is a session of | no work is done, only reported |
| `tmux` | the cockpit panes | no attention surface |
| `cargo` | building the attention panel, once | no panel; the loop is unaffected |
| `node` | gating the browser page's view model | that one suite skips; the loop is unaffected |

**Run `spira/doctor.sh` first.** It is read-only, it names every one of these that is missing
and what that costs you, and it goes on to check the database, the repository map and the
cockpit in the same pass. A harness that fails on a missing binary with a bare shell error is
not shareable, and finding them one restart at a time is the alternative.

## Getting started

```sh
mkdir -p ~/.config/spira                           # the config lives outside the checkout
cp spira.conf.example ~/.config/spira/spira.conf   # and edit it
cp spira/repo-map.example spira/repo-map           # and write your own rows
spira/exclude.sh install .                        # arm the pre-commit fence
bd -C <your SPIRA_DB> init                         # if you have no database yet
spira/doctor.sh                                    # until it says 0 fatal
spira/seed.sh                                      # write the shipped statutes in
systemd/install.sh                                 # render the units and start the timers
```

## Configuration

**One file.** `spira.conf` — copy `spira.conf.example`, set the paths for your machine, and
nothing else should need editing. The code carries a default for every key, derived from
where the harness is installed, so a clean clone runs; the config carries your box.

It is looked for in `$SPIRA_CONF`, then `<the checkout>/spira.conf`, then
`${XDG_CONFIG_HOME:-$HOME/.config}/spira/spira.conf`, then `/etc/spira/spira.conf` — first
hit wins. Outside the checkout is the better home: these are your paths, and none of them
belong in a repository you might push.

Three properties are load-bearing.

- **It is not shell.** `KEY = value` lines, parsed, with an allowlist of keys; `~` and
  `$HOME` expand and nothing else does. This file is read by the process that summons agents,
  so `$( )` in it would be a command run as you. An unrecognised key is reported on stderr and
  ignored, because a typo silently accepted is a setting you believe is in force.
- **The environment wins over the file.** That is what keeps the test suites isolated: a suite
  points `SPIRA_DB` at a throwaway database and no config file can point it back at yours.
- **`SPIRA_HOME` and `SPIRA_REPO` are not settable.** Where the harness *is* is a fact about
  where `conf.sh` sits, not a configuration question. Letting a file answer it breaks the
  landing gate, which extracts a branch to a scratch tree and runs that tree's own suites: the
  config would point them back at the installed copy, so the gate would test the code already
  in force instead of the code being judged — and pass.

**The repository a bead belongs to comes from a `repo:` label on the bead**, resolved through
your own `repo-map`. The shipped one is `repo-map.example`; its rows name repositories that do
not exist, and the harness falls back to it only so a clean clone resolves to something. An
unmapped `repo:` value is *refused, never guessed* — a default of the home repository is how
another repository's bead gets "fixed" in the wrong tree while the aeon reports success.

**Do not assume `main`.** Each row declares the ref its work is cut from and lands on, because
every automatic source for it is a local cache that can be stale, absent or answering whatever
branch a human last looked at. On the box this harness was written for, three of seven
repositories had no ref named `main` at all.

## Statutes

Agents read their law from the beads KV store at summon, and that store is per-installation —
so a clone of this repository carries the mechanism and none of the law that makes it behave.
`spira/statutes/` holds the seed text, one file per statute, and `spira/seed.sh` writes them
into your database. It never overwrites one already in force: an operator who amended a
statute meant it.

What ships is law about the **machinery** — how a tool actually behaves, which approach failed
and why, the shape of a recurring hazard. Law that names a repository, a deploy path or an
operator's own preferences stays in that operator's database. Every statute here carries its
scar, stated generically, because the scar is the reason anyone believes the rule.

## systemd

`systemd/` holds **templates**, not units: every path in them is a placeholder filled from
`spira.conf` by `systemd/install.sh`. A unit with a path baked in runs on exactly one box, and
systemd gives no clue when the path is wrong — an `ExecStart=` that fails with a bare "No such
file or directory" into a journal nobody is watching.

Never edit an installed unit. Edit the template and re-run the installer; `install.sh --diff`
is how you find out that somebody did.

### One copy, and a check that says so

The units execute one checkout. **Landed is not in effect** — a bead is judged against the
branch it named, and nothing in that judgement asks whether the tree systemd runs is that
branch. Keep exactly one copy of this harness on a box. If a second exists — vendored into
another repository, left behind by a move — work aimed at the harness lands in one of them and
the other goes on running, and nothing reports a fault: the tree that was edited is
self-consistent, so its suites pass, its gate is satisfied, and its bead closes naming a real
commit on a real branch.

Two mechanisms, because a convention nobody can see is not one:

- `spira/skew.sh check` runs hourly from `spira-skew.timer`, rendered to the copy systemd
  actually executes, so it reports on itself. It escalates when that copy is behind the ref it
  lands on, carries changes on no branch, or is not the only harness the repository map
  reaches — once per distinct finding, never once per pass.
- The landing gate refuses any branch that changes a copy of the harness in a repository that
  is not this one, and names where the work belongs instead. Override it, if the vendored copy
  is genuinely what you meant to change, with `SPIRA_ALLOW_FOREIGN_HARNESS=1`.

`spira/doctor.sh` reports the count as part of its preflight, and `spira/skew.sh copies` names
every copy the map can reach.

## Watchers

A watcher is a process that polls something and prints a line when it finds news. The
temptation is to start one inside a coding-agent session, and that is the mistake: the session
owns it, so it is made by hand, restarted by nobody, killed by the next context reset, and
nothing outside that transcript knows it should exist. One here went on reading a database that
had been retired underneath it for three days, looking perfectly healthy in every process
listing, while a real answer given in the meantime reached nobody.

So **systemd owns every watcher process, and a session latches onto two files**:

```
$SPIRA_RUN/watchd/<name>.log      newline-delimited events, append-only
$SPIRA_RUN/watchd/<name>.cursor   an integer: lines already delivered
```

That is the whole contract, and it is deliberately dumb enough that `tail -n +$((cursor+1)) -F
<log>` is a conforming client. Nothing about it is specific to one agent, one client or one
machine — the unit's `StandardOutput=append:` writes the same file a reader indexes, which is
the hinge that lets systemd own the process without a session needing anything but a filename.

`spira/watchers` is the single source of truth for what should be watching — `name|kind|target`
rows, where `daemon` is a process we own and `log` names a file something else already writes
and therefore gets no unit. Adding a watcher is a row plus an install run, never a new unit
file. `spira/watchd.sh` is the face over all of it:

```
watchd.sh status                 unit state and unread count, one line per watcher
watchd.sh drain [name] [--all]   print what nobody has read, and mark it read
watchd.sh tail <name> [--all]    replay from the cursor, then stream; this is a Monitor command
watchd.sh restart [name]         restart the unit behind a watcher
watchd.sh manifest | units       what the rows say, and the units they render
```

It owns no process. `status` asks systemd what is running and `restart` asks systemd to restart
it; there is deliberately no second supervision scheme beside systemd's, because a second one
is how the original defect survived being looked at.

**`drain` is filtered by default, and that is the point of it.** It is what you run into a
context window that has just opened, so an unfiltered drain puts the whole backlog in the most
expensive place it could go — one real session was offered a replay of 283 raw lines as the
first thing in it. `SPIRA_ACTIONABLE` is the expression that decides, `tail` uses the same one
so the two cannot disagree, and `--all` is how you ask for everything on purpose. The header
carries both numbers — `(30 actionable of 300 new)` — because the suppressed lines are the cost
of the filter, and a filter whose cost is invisible is one nobody can tell has gone wrong.

Both commands advance the cursor by what was **read**, not by what was printed: a filtered line
has been considered and rejected, not missed. Leaving it unread would keep every reader
reporting a backlog that no amount of draining could clear.

## Parking on a CI run

An aeon that has opened a pull request labels its bead with `SPIRA_CI_LABEL` and exits, rather
than paying a model session to sit on a test suite. The sweep watches the run and brings the
bead back: green, it lands; red, it clears the label and raises the priority so the next aeon
is handed the failure.

That label is excluded from every persona's predicate **and** from the stranded-work report,
which is what stops parked work looking abandoned — and is exactly why a park nothing can end
is worse than a stall. It is not claimable, not reported, and shown as "in CI", the one
description that stops anybody looking for the real cause.

Two conditions end a park that would otherwise be permanent, and the `land` column in your
`repo-map` decides the first. Only `pr` opens a pull request, so only `pr` has a run; under
`push` and `hold` the landing gate is the whole gate and the sweep strips the label as soon as
it sees it — which also covers a bead that moved repository while parked, a case no check made
at the moment of parking could catch. The second is `SPIRA_CI_PARK_MAX`: past the longest run
your CI can plausibly take, the promise that something else is watching is false, so the bead
goes back into the report that would have found it.

The ops pane reports the two populations separately, because "waiting on a run" is routine and
"parked with no run to wait for" is a fault.

## The browser page

`loom/` is a browser surface over the live bead graph: where the work is, what blocks what,
and how it has proceeded. `loom/src/` is the server and its one route; `loom/static/` is the
page. Open `loom.html` beside that route, or point it at a saved payload with `?api=<path>`
and no server at all.

**The server returns beads; the page computes everything else.** No coordinates, no connected
components, no execution layers, no histograms, no counts. That was the other way round in the
prototype this grew from, and a measurement reversed it: the whole pass — treemap, packing,
edge routing, components, layering and every bucket — is single-digit milliseconds at a few
hundred beads and tens of milliseconds at twenty thousand, in the browser. Server-side layout
buys nothing at that price and costs a rendering stack.

| file | what it is |
|---|---|
| `static/model.js` | the derivation. No document, no network — which is what lets a suite load the shipped file under a bare JS runtime |
| `static/app.js` | the painting, and the only thing that fetches |
| `static/loom.html` | markup and style |
| `static/fixture.py` / `fixture.json` | a synthetic corpus reproducing the shapes a real graph makes; the generator states the shapes, so a reader need not count records |
| `static/render-check.sh` | drives the page in a headless browser and asserts it painted |

The dependency records reach the page one of two ways and both give the same graph: on each
bead, as the tracker writes them, or lifted into one flat `edges` array by a server that does
not want to write each one twice. One parser reads both, because a second reader for the
second arrangement is how the two come to disagree about which relations count.

Two things it deliberately does not do. It has **no attention list** — whatever surface you
already answer questions on keeps that job, because two surfaces answering "is anything wrong"
differently is how one becomes wallpaper. And it shows **arrivals, never completions**: the
read path is bounded to work in flight, which is what makes reading it on every request
affordable, so completions per day and created-to-closed cycle time have no source in it. They
are absent and labelled absent rather than approximated from the open population, where the
number would be wrong and would still read as the number it is named after.

`test-loom.sh` gates the server, `test-loom-page.sh` gates the model and the page's structure,
and they are separate because they fail for different reasons and skip on different machines —
one wants a Rust toolchain, the other a JS runtime. `render-check.sh` is run by hand, because a
browser is not something a clone has any reason to have. Every assertion in it is
one the static markup cannot satisfy — an earlier version looked for a tag the legend supplies
either way, and reported greens over a page whose render call the port had dropped.

## Clearing a session without losing it

Context is re-read in full on every turn, so a long session costs many times a fresh one for
identical work. The fix is to clear it — and a session near the ceiling is also the one
carrying the most that was never written down: questions asked and never answered, findings
stated and never filed, verdicts acted on and never recorded. The expensive state is the
sticky one, which is why nobody clears.

The **archivist** makes clearing cheap. `spira-archivist.timer` sweeps the live sessions every
five minutes, computes what each is carrying, and when one crosses `SPIRA_ARCHIVIST_AT` it
summons an agent whose entire input is that session's transcript. The agent reads the log,
rescues what is loose into asks, insights, notes and — sparingly — beads, and exits.

**It reads the transcript, not the conversation.** Everything it needs is already on disk, so
it costs the session it is rescuing nothing: no turn, no tokens, no interruption. That is a
design constraint rather than an optimisation. A persistence step that adds turns makes the
problem it exists to solve slightly worse every time it runs, and would be worst in the
sessions that need it most.

It is deliberately **not** a fayth. An aeon's subject is a bead — claimed under a lease,
worked on a branch, judged by whether a commit names it. The archivist's subject is a
transcript, and giving it a bead per session would have the machinery for rescuing unfinished
business manufacture one unfinished bead per session.

    spira/archivist.sh list        every live session, what it carries, what would happen
    spira/archivist.sh now         archive the session you are in, right now — hibernate
    spira/archivist.sh sweep       what the timer runs

`now` is the manual path, for a deliberate clear: same machinery, no threshold, no high-water
mark, because you asking is the trigger.

### What you see while it happens

One small file per session, `$SPIRA_RUN/archivist/<session>.state`, read by the status line
and by the dashboard:

    state=sweeping|archiving|safe|failed
    at_turn=<the session's turn count when this state was computed>
    items_filed=<how many items were written>

**`at_turn` is load-bearing.** "Safe to clear" is a statement about the session as the
archivist saw it; forty turns later it describes a session that no longer exists, and acting on
it discards everything said since. Both readers demote a stale verdict to "safe as of N turns
ago" rather than repeating a green one. A verdict that cannot go stale is one that will
eventually lie.

For any of it to be visible, the status line needs a **`refreshInterval`**. The client re-runs
a status-line command on a session starting, a new assistant message, a compaction finishing, a
mode change and a refresh timer — clearing is not on that list, and neither is anything the
archivist does, all of which happens while the session is idle. Without the timer the pane can
only show what was already true at the last assistant message, so a cleared session goes on
displaying the discarded context: the instrument that exists to say whether clearing was worth
doing, reporting that the clear did not work. That setting lives in the client's own settings
file, outside every repository, so nothing here can set it — `spira/doctor.sh` reports its
absence as a finding with the one-line fix.

Four keys, all with defaults: `SPIRA_ARCHIVIST_AT` (which of the three context thresholds
summons it), `SPIRA_ARCHIVIST_IDLE` (how recently a transcript must have been written to count
as live), `SPIRA_ARCHIVIST_MODEL` and `SPIRA_ARCHIVIST_TIMEOUT`.

## Escalations, and their answers

An escalation has two halves — the ask and the answer — and both need a mechanism. Build the
second when you build the first: a verdict that reaches nobody is worse than an unanswered
question, because the decider believes they replied and the next session asks again.

The ask half is a bead labelled with `SPIRA_ASK_LABEL`. Every predicate that decides what an
aeon may claim excludes it — the sentinel's ready count, the personas in `spira/chamber/`, and
the stall sweep — so a question can never be claimed as if it were work, nor reported as work
that has stalled. `cockpit/panel/` is the attention surface it renders on: a Rust TUI, built
with `cargo build --release`, run from a tmux pane by `cockpit/layout.sh`.

The answer half is `spira/verdicts.sh`. The panel writes a verdict **into the bead** — the
close reason for a decision, a comment for a reply — so there is no file to tail, and a
session watching one concludes that nothing was answered. Run `spira/verdicts.sh loop` as a
watcher in any session that escalates anything; it polls for asks closed since its cursor,
prints one line each, keeps its high-water mark under `.runtime/`, and is therefore silent
when nothing has been answered and never replays a verdict twice.

**Launch the panel through `cockpit/panel-run.sh`, never the binary.** tmux gives a new pane
the environment of the tmux *server*, not of the process that ran `split-window`, so a bare
binary starts without the database path or the ask label. The label's absence is the dangerous
half: unset, it falls back to a default the installation does not use, matches nothing, and
renders an **empty list** rather than an error. The launcher reads the configuration at
launch, so every respawn picks up the current one.

## The transcript archive

The client writes each session to a transcript under its own directory, unversioned, on
whatever volume the home directory sits on, with no retention promise to anyone. That file is
the only record of every decision taken in conversation that never became a bead — which is
exactly the material nothing else here keeps. `spira/archive.sh` copies it somewhere durable
and indexes it, so a later "what did we decide that afternoon" is a command.

```
archive.sh sweep [--force]        archive what has changed and rewrite the index
archive.sh hook                   a session-end payload on stdin; archive that one transcript
archive.sh query --since T --until T [--lineage <id>] [--slug <glob>] [--json]
archive.sh lineage <session-id>   the whole chain that session belongs to, oldest first
archive.sh restore <id|path>      the original bytes on stdout, checked against their digest
archive.sh verify [id|path ...]   re-hash every archived body against the index
archive.sh where                  the root, the row count, and what it costs on disk
```

**Index the lineage, or every consumer re-implements the same guess.** Clearing the context
starts a *new* transcript with a new session id, so "the current session log" is only ever the
tail of the conversation. The client records a stable `bridgeSessionId` in the first lines of
every file in a lineage, unchanged across those clears — one field that turns a chain of files
into one queryable conversation, which is what `lineage` reads. Subagent transcripts carry
their parent session instead of a lineage id, so the index joins them onto it; without that
they are in the archive and in no answer about it, which is the same as not having them.

`spira-archive.timer` sweeps every twenty minutes, and a pass that finds nothing changed
writes nothing at all — no body recompressed, no index rewritten, no mtime touched, so "has
anything happened since?" stays answerable from the archive itself. The fast path is the
source's size and mtime; `verify` is what re-hashes the stored bytes, and `sweep --force` is
what repairs whatever it finds, because a check with no remedy only produces alarm.

For the ordinary case, archive at session end too, from the client's own hook:

```json
{ "hooks": { "SessionEnd": [ { "hooks": [
    { "type": "command", "command": "/path/to/spira/archive.sh hook" } ] } ] } }
```

**The bodies never go in a shared repository.** A transcript carries paths, credentials read
aloud, and everything anyone ever said in it. `SPIRA_ARCHIVE` defaults under the runtime
directory, which is gitignored for the same reason a beads database is. If something derived
is ever wanted in git it is the *index* — metadata, no message content, and it is asserted to
hold none — and even then only where a reader can see that it is derived.

**Retention is a decision, not a default.** Nothing here deletes anything. When the volume
eventually says otherwise that is yours to decide, and the index is what makes it answerable
rather than a guess: bytes per lineage, per month, per project directory.

## Sharing it back

Two fences guard what leaves this repository, and both run from the landing gate.

`spira/exclude.sh` keeps the **beads database** out — the store, an export of it, a `.beads/`
directory pointing at your server. It holds internal working notes and agent memories, none of
which are code, and a commit that publishes it cannot be undone by deleting the commit. Arm it
once with `exclude.sh install .`; it also writes the ignore rules and the pre-commit hook.

`spira/inventory.sh` keeps **one operator's infrastructure** out — a repository name, a deploy
path, a host, a person, the date an incident happened. It is not tidiness: a comment naming a
box teaches somebody else's agent to reason about a machine that does not exist, and sometimes
to act on it. Add your own names to `spira/inventory-deny`.

What ships instead is the rule with its scar stated generically. *"A remote need not be called
`origin`"* is worth reading anywhere; the same sentence naming three repositories is worth
reading nowhere but the box it happened on. Keep every rule and every trap — a harness whose
correctness looks arbitrary is one whose guards the next person deletes for being unexplained.

## The boundary

Spira was extracted from a personal wiki repository, and the line between the two is worth
stating because it is the line between *the mechanism* and *one operator's use of it*.

**Two rules decide every case, including the ones not in the table.**

1. **The write target decides ownership.** A program belongs to the repository whose files it
   writes, whatever it reads. Reading across the boundary is free; writing across it is what
   makes ownership arguable.
2. **Dependency runs one way — the wiki may depend on the harness, never the reverse.** This
   repository must start from a clean clone with no wiki present anywhere on the machine.
   Where the harness wants an effect on a wiki it calls a *configured* hook and carries on
   when that hook is absent. An optional call is not a dependency; a hard path is.

**Nothing in the third group ever enters this repository.** A beads database accumulates
internal working notes and agent memories, so it is never public and never committed — not
the database, not an export of it, not a `.beads/` directory pointing at your Dolt server.
The harness checkout and the beads project directory are deliberately separate checkouts, and
a pre-commit hook refuses a commit that touches either.

The table below is generated from `boundary`, which is the single source for it and for the
copy in the wiki. **Editing this region does nothing** — the next run overwrites it. Amend
`boundary` and run `boundary.sh write`.

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
| `spira/skew.sh` | is the harness in force the harness that landed — the hourly check that the executing copy is current, clean and the only one, and the landing gate's fence against work landing in a copy nothing executes |
| `spira/doctor.sh` | read-only preflight — every missing program, unreadable database, unmapped repository and unbuilt panel, named in one pass |
| `spira/statutes/` | the SEED statute book, one file per statute. Statutes live in the beads KV store, which is per-installation, so a clone gets the mechanism and none of the law unless it ships as text |
| `spira/seed.sh` | writes those statutes into a fresh database, and never over one already in force |
| `cockpit/` | the decisions panel (Rust) and the ops pane — how a human sees what the harness is doing and answers what it asks. Generic; it reads whatever database it is pointed at |
| `systemd/` | unit TEMPLATES plus install.sh. The units in force on a machine are generated from these, never edited in place |
| `concierge.sh` | one named Remote Control session, so a phone can reach the harness |
| `rule.sh` | enacting a statute writes the beads KV store, which is the harness's substrate |
| `spira/archive.sh` | keeps every session transcript and indexes it by time range and by the lineage id that survives a clear. The mechanism ships; the transcripts and the store they land in are the operator's own and stay out of every repository |
| `beads-push.sh` | pushes each database that has a configured Dolt remote. The mechanism ships; the remote it is pointed at is the operator's own and is private |
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

## Statutes

The rules every agent obeys are rows in the beads KV store, which the harness injects into
every session it starts. They are therefore **per-installation**: cloning this gets you the
mechanism and none of the law that makes it behave, including the rules that exist because a
check here was confidently wrong. The harness ships seed statutes — the ones about the
machinery, true on any machine — for an installer to write into a fresh database. Statutes
naming a particular operator's repositories, deploy paths and preferences stay with that
operator.

Enact one with `rule.sh enact <slug> "<statute>"`. Write them to be read a thousand times:
one paragraph, imperative, about seventy words, with the scar that produced the rule as a
single clause rather than a narrative. Every agent pays that context on every session.
