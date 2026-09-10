# Why timed-suite beads close while the suite is still red

Spike for sp-7bvay. Written 2026-09-10. Evidence preserved verbatim in
`sp-7bvay-evidence/`, cited below by file and section. Absolute paths in this document and
in the evidence are rewritten to their config keys, because this repository ships and
`spira/inventory.sh` gates it.

## The question

Asked by the operator, in his words:

> why the fuck are the beads being closed without actually having green tests (that's the
> actual bug here)

What would count as an answer: the mechanism by which a bead filed by the timed suite runner
reaches CLOSED while its suite is still failing, named with the specific beads as evidence —
and a decision about what to change.

## The answer in one paragraph

**They had green tests.** The runner's red was false. `test-gate-budget.sh` fails under the
timed runner and passes everywhere else, deterministically, because the runner's systemd unit
exports `SPIRA_HOME` into every suite it starts and that one variable redirects the suite's
repo-map lookup onto the shipped example map. The aeon that claims the resulting bead runs
the `reproduce` command printed in the bead's own body, gets 14/14 green, and closes the bead
truthfully, having found nothing to fix. It commits nothing. Its empty branch is then read as
"content landed" by an ancestry test that cannot distinguish an empty branch from a merged
one, which exempts the bead from the closed-is-not-landed verdict that would have reopened
it. The next pass files the same red again. Every actor in that loop behaves correctly and
the loop is stable: five beads for one fingerprint of one suite so far, `$17.49` of aeon
time, and it is still running. A second, independent defect files a killed suite as a red.

## What I found

### 1. The red is manufactured by the runner's own environment (OBSERVED)

`systemd/spira-suites.service` carries `Environment=SPIRA_HOME=@SPIRA_PROD@`. `suites.sh`
starts each suite with `setsid bash "$HERE/$s"` and never scrubs its environment, so every
suite in the timed set inherits `SPIRA_HOME` pointing at the installed harness.

`test-gate-budget.sh` copies the gate and its dependencies into a scratch tree and plants a
`repo-map` beside them so `_bdq_check_repo_label` will allow `repo:spira` when the gate files
its budget bead. Its `run_gate` strips `SPIRA_CONF` and pins `SPIRA_DB` — but not
`SPIRA_HOME`. `conf.sh`'s repo-map resolution branches on whether `SPIRA_HOME` was *answered
by the caller* or derived:

```
if [ -n "$_spira_conf_home_env" ]; then
    set -- "$SPIRA_HOME/repo-map" ${d:+"$d/repo-map"} "$SPIRA_HOME/repo-map.example"
else
    set -- ${d:+"$d/repo-map"} "$SPIRA_HOME/repo-map" "$SPIRA_HOME/repo-map.example"
fi
```

With `SPIRA_HOME` inherited, the fixture's own map loses to `$SPIRA_HOME/repo-map` — which
does not exist in the installed checkout — and resolution falls through to
`repo-map.example`. `repo_names` then returns `home legacy service vendor`, `repo:spira` is
refused, `bdq create` returns 1, no bead is filed, and three assertions fail.
[`sp-7bvay-evidence/b-repo-map-resolution.txt`, B1–B4]

Measured, three ways, same suite, same file, same fixture
[`sp-7bvay-evidence/a-spira-home-is-the-difference.txt`]:

| environment | result |
|---|---|
| runner's, with `SPIRA_HOME` | 11 passed, **3 failed** |
| runner's, `SPIRA_HOME` removed, nothing else changed | 14 passed, 0 failed |
| aeon's, with `SPIRA_HOME` injected (positive control) | 11 passed, **3 failed** |

The three failures are exactly the ones the production beads record, and they hash to the
same fingerprint, `3722960463212`. The runner's own log shows the suite red on nine
consecutive passes at 18–21 s, against 12–14 s green standalone: this is not flake.
[`$SPIRA_RUN/suites.log`]

This is `law-gates-run-in-a-clean-environment`, and `conf.sh`'s own comment on that branch
records the same scar from the other direction — four suites once silently read the real map
because the config-dir map led unconditionally.

**Blast radius, honestly bounded.** I tested the three other most-re-filed suites
(`test-spike.sh`, `test-hold.sh`, `test-sin-exempt.sh`) with and without `SPIRA_HOME` and
they are unaffected — same result both ways. So this is not the universal cause of re-filing;
it is the proven cause for `test-gate-budget.sh`. Seven suites in the tree read `SPIRA_HOME`
without setting it themselves and are therefore exposed to the same class:
`test-archivist.sh`, `test-conf.sh`, `test-doctor-schema.sh`, `test-freshclone.sh`,
`test-release.sh`, `test-review.sh`, `test-watch-refresh.sh`. I did not test those seven.

### 2. The aeon behaves correctly, and that is the problem (OBSERVED)

The bead's body carries `reproduce   bash spira/test-gate-budget.sh`. An aeon runs exactly
that, in an aeon's environment, where `SPIRA_HOME` is unset. `sp-htwlh`'s session log
contains `14 passed, 0 failed` eight times.
[`sp-7bvay-evidence/e-empty-branch-reads-as-landed.txt`, E5]

There is no instruction the aeon disobeyed. The bead asserts a red the aeon cannot reproduce,
using a command the bead itself supplied, and the aeon closes it. This is the whole answer to
the operator's question: nobody is being sloppy.

### 3. Nothing reopens the bead, because an empty branch reads as landed (OBSERVED)

`content_landed`'s first test is `git merge-base --is-ancestor "$br" "$base"`. A branch on
which nothing was committed *is* an ancestor of its base, so it returns 0 — the same answer
it gives for work that genuinely merged. The Sending then labels the bead `content-landed`,
and `sentinel.sh:446` reads `[ "${sentcontent:-0}" = 1 ] && continue`, skipping the
closed-is-not-landed check for that bead entirely.
[`sp-7bvay-evidence/e-empty-branch-reads-as-landed.txt`, E1–E4]

The harness half-noticed: the Sending logged
`ASSERT sp-l5l20 — content landed but no landstate/sp-l5l20` on three separate reaps, and
proceeded. That assertion is currently a log line with no consumer.

### 4. A killed suite is filed as a red, not as a timeout (OBSERVED — second, independent defect)

`suites.sh` maps `rc >= 128` to 124 and records a timeout with a fingerprint over
`killed at Ns`, deliberately not over the suite's output. That path never fires for a suite
that traps TERM — which is 43 of the 160 suites in the tree, because trapping TERM is how
they clean up their scratch directory.

`trap ... TERM` handles the signal; it does not end the script. The watchdog's
`kill -- -PGID` runs the cleanup handler — which has already `rm -rf`'d the scratch tree —
and **execution resumes**. The suite runs to completion against a deleted tree, every
remaining assertion fails on a missing file, and it exits 1. `suites.sh` sees rc=1, calls it
`red`, and fingerprints the file-not-found cascade.

Reproduced with the runner's own kill machinery copied verbatim; the output has the exact
shape `sp-3r97d` recorded in production — `Terminated`, then `No such file or directory` on
every subsequent line, rc=1.
[`sp-7bvay-evidence/c-term-trap-defeats-the-watchdog.txt`, C1–C5]

Because the fingerprint is taken over where the kill happened to land, two kills of the same
suite produce two different fingerprints and two beads. This is `law-charge-only-a-named-outcome`:
an exit nobody classified is being reported as knowledge.

### 5. A NULL close reason identifies a close that bypassed `bd close` (OBSERVED)

44 of 122 closed suite-filed beads have `close_reason = null`. That is not "the aeon omitted
a reason": `bd close` with no `--reason` stores the string `Closed`, and with `--reason ""`
also stores `Closed`. Only `bd update --status closed` leaves it NULL.
[`sp-7bvay-evidence/d-census-and-cost.txt`, D6]

So a third of these beads were closed through a path that has nowhere to put the evidence
`law-close-with-the-evidence-asked-for` requires, and nothing refuses it. I did not establish
*who* takes that path — see "What I could not establish".

### 6. What it has cost (OBSERVED)

From the bead store and the aeon ledger [`sp-7bvay-evidence/d-census-and-cost.txt`, D1–D4]:

| | |
|---|---|
| suite-filed beads | 131 |
| named by a commit on the base | 68 |
| named by no commit at all | **63** |
| refs filed more than once | 14, producing 38 surplus beads |
| total aeon spend on suite-filed beads | `$275.71` |
| — of which on beads producing no commit | **`$98.89` across 61 aeon sessions** |
| — of which on the one proven-false red | `$17.49` across 6 aeon sessions |

`$98.89` is an upper bound on waste: some of those 63 are legitimate no-ops (superseded, or a
red that had already been fixed by another bead). `$17.49` is the floor, and it is the part
that is proven false and still recurring.

## Options

### Option 1 — strip `SPIRA_HOME` in `test-gate-budget.sh`'s `run_gate`

One line beside the `SPIRA_CONF` it already strips, plus a regression assertion that runs the
suite with `SPIRA_HOME` set and requires it green.

- **Cost:** ~1 line of fix, ~15 lines of test, one suite run to see it red first.
- **Risk:** low. Closes one instance and leaves the class open — seven other suites read
  `SPIRA_HOME` without setting it, and the next suite that copies the harness into a scratch
  tree rebuilds the defect. Does nothing about defects 3, 4 or 5.

### Option 2 — run every suite under a fixed minimal environment

Make `suites.sh` start each suite with an explicit `env -i` allowlist.

- **Cost:** ~20 lines in `cmd_run`, plus a suite. Zero per-pass runtime cost.
- **Risk:** **high, and the reason I am not recommending it.** A pass runs ~65 suites in
  1800 s. Flipping the environment for all of them at once can turn an unknown number red
  simultaneously, and each red files a bead; because dedup keys on open beads only, each then
  re-files every cycle. The worst pass observed filed 7; this could file 65 and keep filing
  them. It is also a change to the property under test for any suite that legitimately reads
  an ambient value. Correct in principle, unlandable safely today because nothing measures
  which suites depend on the inherited environment.

### Option 3 — confirm a red before filing it

Before `file_red`, re-run the suite once in the environment the bead's own `reproduce` line
will be run in — an aeon's, i.e. without `SPIRA_HOME`. File the suite defect only if it fails
there too. If it passes there, file a *different* finding: the runner's environment produces a
failure an aeon cannot reproduce, naming the variables that differ. Skip the confirming run
and record `red-unconfirmed` when it does not fit the remaining budget.

- **Cost:** one extra suite run per red. Measured over the last 12 passes: median suite
  11 s, 2.2 reds per pass → **≈24 s of an 1800 s budget, 1.3 %**. Worst observed pass had 7
  reds; at the p90 suite time of 64 s that is 448 s, 25 % — hence the budget cap.
  Implementation ~30 lines plus a suite.
- **Risk:** a genuinely flaky suite that goes red then green is filed as an environment
  finding rather than as flake. Mitigated because the finding names the environment delta,
  which is empty for a flake.

### Option 4 — make an empty branch unable to read as landed

`content_landed` returns non-zero (unknown) when the branch has zero commits ahead of the
base, so the Sending does not label it `content-landed` and CHECK 5 performs the landing
check it was written to perform.

- **Cost:** ~4 lines plus a suite (~40 lines).
- **Risk:** low–medium. Beads that legitimately deliver no commit are already exempted
  earlier at `sentinel.sh:465` by `delivers:`, and by `superseded` and `dropped` above that,
  so the population this newly reopens is close to exactly the one it is aimed at. Expect
  churn on the first pass after it lands as the existing backlog of no-work closes reopens.

### Option 5 — disable the timed runner and do nothing

- **Cost:** `$0`/day, and the loop stops immediately. This is the state today: the timer was
  disabled at ~13:20Z on 2026-09-10 as a tourniquet.
- **Risk:** high. 56 non-gated suites then run nowhere at all, which is precisely the defect
  `suites.sh` was built to end and which measured five of nine suites executed by nothing.
  A tourniquet is not a fix.

## Recommendation

**Option 3.** Land the confirming re-run in `suites.sh`, and file Options 1 and 4 as separate
beads that do not compete with it.

Option 3 is the only one that stops the loop for *every* suite rather than for the one I
happened to diagnose, and it costs 1.3 % of a pass to do it. It converts a silent false red
into a named environment finding, which is `law-detection-outranks-rejection` — build the
watcher before the gate — and it is the meter that `law-take-the-simple-fix-with-a-meter`
asks for: the count of "red under the runner, green as an aeon would run it" is the number
that says how bad the environment divergence is and, once it reaches zero and stays there,
is what makes Option 2 landable as a deliberate act rather than a hopeful one.

Option 1 is a true fix and should land anyway; it is 1 line and it is not in tension with
Option 3. Option 4 closes a different hole — the one that lets a no-work close survive — and
is needed whatever happens to the runner, because it is not specific to suite beads at all.

**The load-bearing assumption:** that an aeon's environment does not carry `SPIRA_HOME`, so
"re-run as an aeon would" is a well-defined and stable thing to do. Verified directly:
`aeon.sh` uses `$SPIRA_HOME` internally but never exports it to the agent, and this spike —
which is an aeon — has it unset. If that ever changes, the confirming re-run reproduces the
false red and files it, and the loop resumes with an extra suite run per cycle for nothing.

## The falsifier

The recommendation is wrong if the confirming re-run's disagreements turn out to be flake
rather than environment. Checkable, after the change has run for a day:

> Count reds where the first run failed and the confirming run passed, grouped by suite. If
> that set is concentrated — a handful of suites disagreeing on most passes — it is
> environmental and Option 3 is doing its job. If it is spread thinly across many suites,
> each disagreeing once or twice, the runner is measuring flake, the confirming run is
> laundering it into an environment finding, and the right change is Option 2 plus a flake
> quarantine instead.

Two smaller ones:

- Option 4 is wrong if the population it newly reopens is dominated by beads that
  legitimately produced no commit. Checkable: after it lands, read the first pass's reopens
  and count how many carry a `delivers:` label or a close reason describing real work.
- The whole diagnosis is wrong if `SPIRA_HOME` is not in fact what the production unit
  exports. Checkable in one command: `systemctl --user show spira-suites.service -p Environment`.
  I read the unit file in the repository, not the installed unit — see below.

## What I could not establish

- **Whether the installed `spira-suites.service` matches the unit file in the repository.** I
  read the repository's copy. `law-detect-drift-never-install` says a check may detect drift
  but not repair it, and I did not want to touch a disabled unit while a tourniquet is in
  force. The reproduction does not depend on it — I injected `SPIRA_HOME` by hand and it
  reproduced — but the claim "the unit is what sets it" rests on the repository file.
- **Who closes beads with `bd update --status closed`.** I established that a NULL
  `close_reason` can only come from that path, and that 44 of 122 have one. I did not find
  the caller. Candidates worth grepping: the aeon's own close path, the reaper, and the
  restore machinery that ran after the mass-reopen incident.
- **Why the other 13 re-filed refs re-filed.** I ruled out `SPIRA_HOME` for three of them by
  direct test. The dedup hole on sp-srgr6 explains re-filing after a close; it does not
  explain why each was red at the time. Each needs its own reproduction.
- **Why `test-gate-budget.sh` took 604 s on the pass that produced `sp-3r97d`**, when it runs
  in 12–21 s otherwise. The kill cascade explains what was *recorded*; it does not explain
  what made the suite slow enough to be killed. Load on the box is the obvious guess and I
  did not verify it.

## Provenance

No external sources were fetched; every citation is to this repository, the bead store, or
the runner's own logs on the operator's box, and each is preserved under
`sp-7bvay-evidence/`. No proof-of-concept branch was left: the reproductions are shell
transcripts, captured into the evidence files rather than as code changes, and this branch
carries nothing outside `docs/spikes`.

## The work this spike filed

| bead | P | what |
|---|---|---|
| sp-ezs7o | 1 | **The recommendation.** `suites.sh` confirms a red in an aeon's environment before filing it. |
| sp-qc4kn | 1 | `content_landed`: an empty branch must not read as landed. Option 4. |
| sp-rgao1 | 2 | `test-gate-budget.sh`: `run_gate` must strip `SPIRA_HOME`. Option 1, one line. |
| sp-ay171 | 2 | `suites.sh`: a suite killed by the watchdog is filed as a red, not a timeout. Finding 4. |
| sp-ic4jc | 2 | A NULL `close_reason` means `bd close` was bypassed — find the caller. Finding 5. |

None of the eight open timed-suite beads were closed, and none of the closed ones were
reopened; sp-srgr6 owns that population. sp-3r97d is left open deliberately — it is the
instance of the killed-suite defect that sp-ay171 fixes.

**Re-enabling the timed runner before sp-ezs7o lands resumes the loop.** sp-srgr6's
acceptance item 5 owns the re-enable; a note on it points here.
