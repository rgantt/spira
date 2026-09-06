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
