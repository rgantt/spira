# sp-gsmx final verification report

Epic: Un-conflating landing: review, release units, QA and test lifecycle  
Bead: sp-gsmx.9  
Reviewer: aeon-ixion  
Date: 2026-09-08

---

## Tiers run and results

Suites run: all nine suites that cover deliverables named in the design's test strategy,
plus test-unit-drift.sh (covers dev/prod split) and test-groomer.sh.

| suite | result | verdict |
|---|---|---|
| test-deploy.sh | 1 FAIL | BLOCK bead filing: count=0, want ≥1 |
| test-promote.sh | 23/23 | PASS |
| test-release.sh | 22/22 | PASS |
| test-released-defects.sh | 5 FAIL (6/11) | positive control entirely fails; output empty |
| test-review.sh | 3 FAIL (22/25) | BLOCK bead filing: count=0, want ≥1 |
| test-qa.sh | 30/30 | PASS |
| test-groomer.sh | 23/23 | PASS |
| test-citations.sh | 20/20 | PASS |
| test-unit-drift.sh | 16/16 | PASS |

The gate was not run (review-only per bead rules). No code change is made in this commit.

---

## Common root cause of all three failing suites

`run_review` (test-review.sh, test-deploy.sh) and `rds` (test-released-defects.sh) call
`env -i` without forwarding `SPIRA_PATH`. When `lib.sh` sources `conf.sh`, line 726 does:

```
export PATH="${SPIRA_PATH:+$SPIRA_PATH:}$HOME/.local/bin:..."
```

With `SPIRA_PATH` absent, PATH becomes `$HOME/.local/bin:...`. On this system
`$HOME/.local/bin/bd` is version 1.1.0 built with `CGO_ENABLED=0`. Every `bdq` call
(which expands to `bd -C "$SPIRA_DB"`) then exits non-zero with:

> Error: failed to open database: embedded Dolt requires a CGO build

Stderr is silenced by `2>/dev/null` throughout the `_file_findings` call chain, so the
failure is invisible: `_file_one_finding` returns 1, count stays 0, and the verdict file
records `findings: 0`. The same failure empties `released-defects.sh`'s output entirely,
making the `rds` function return nothing, so the positive control never fires and every
`want` assertion fails vacuously.

Fix (not applied here — review-only): add `SPIRA_PATH="$SPIRA_PATH"` to the `env -i`
invocations in `run_review`, `run_deploy`, and `rds`. testdb_up prepends `$TESTDB_BIN`
to `SPIRA_PATH` specifically for this reason; not forwarding it undoes that preparation.

---

## Per-bead verdicts

**sp-gsmx.1 — released-defects.sh (PARTIALLY SERVED)**  
The script exists, the logic is correct (commits found via `--grep`, ordering checked with
`merge-base --is-ancestor`, caught/same-unit cases excluded). But `test-released-defects.sh`
fails entirely on this system because the test helper doesn't forward `SPIRA_PATH`, so the
embedded Dolt db is unreadable. The released-defect query row in the test strategy is
effectively untested on this box.

**sp-gsmx.2 — dev/prod split + promote.sh (INTENT SERVED)**  
`test-promote.sh` passes 23/23. promote.sh correctly: (1) clones on first call, (2)
fast-forwards on subsequent calls, (3) refuses non-fast-forwards, (4) restarts only units
whose ExecStart changed, (5) supports dry-run without touching production. The production
checkout is an independent git directory pointed to by `SPIRA_PROD`; systemd units rendered
by `install.sh` template `SPIRA_PROD` into their ExecStart paths.

Gap: no explicit test asserts "a change landed on development does not appear in production
until promoted." The mechanism guarantees it (promote.sh is the only mover), but there is no
fail-first assertion for this specific property.

**sp-gsmx.3 — release units (INTENT SERVED)**  
`test-release.sh` passes 22/22. Tags correctly: include only beads landed since the prior
tag; record `prev:` pointer; produce nothing when zero beads landed. Suite uses 'trunk' as
base branch, verifying no hardcoded 'main'.

**sp-gsmx.4 — reviewer (PARTIALLY SERVED)**  
`test-review.sh` passes 22/25. SHIP path is fully verified: verdict file written with all
cost fields, verdict command works, promote gate honours stored verdicts. BLOCK path: verdict
is correctly stored as 'block', but bead filing (`_file_one_finding → bdq create`) fails
silently on this system (SPIRA_PATH issue above). The deduplication and `_file_findings`
logic is not verified for the BLOCK case.

**sp-gsmx.5 — deployment controller (PARTIALLY SERVED)**  
`test-deploy.sh` passes 19/20. The self-change guard fires correctly (exit 1, production
unchanged). BLOCK verdict refuses correctly (exit 1, systemctl not called). SHIP advances
production (exit 0, correct SHA). Dry-run does not advance production. 

**Publication invariant: VERIFIED.**  
`test-deploy.sh` asserts directly against `landing.sh`:

```
grep -qE '\bpromote\.sh\b|\bdeploy\.sh\b' landing.sh
```

This fails (no match), confirming landing.sh has no path to promote.sh or deploy.sh.
Two-publisher state is unreachable. This is the most critical non-goal and it holds.

The one failure: BLOCK findings are not filed as beads on this system (same SPIRA_PATH
issue). The test expects count ≥1, observes 0.

**sp-gsmx.6 — QA fayth with SPIRA_QA_DEPTH (INTENT SERVED)**  
`test-qa.sh` passes 30/30. Depth isolation (scars < modules < wide) verified by reading
`qa.md` and `qa-sweep.sh`. Pool isolation verified: qa.fayth declares `FAYTH_LANE=qa`,
does not use `FAYTH_ROLE=party`, and appears only in lane fayths (not task pool). The
closing rule ("silence is what is outlawed") is in the brief. Systemd timer unit wired.

Note: the test is static analysis of persona and config files, not execution of
`qa-sweep.sh` against a live database. The slider mechanism is in the brief; its runtime
behaviour is unverified.

**sp-gsmx.7 — test citations (INTENT SERVED)**  
`test-citations.sh` passes 20/20. citations.sh correctly reports three distinct states:
resolved (bead found in db), unresolved (cited id not found), and uncited (no declaration).
States are non-collapsing; the suite uses a real bd on a throwaway database.

**sp-gsmx.8 — groomer (PARTIALLY SERVED)**  
`test-groomer.sh` passes 23/23. The groomer correctly: refuses `unwanted` (exit 2); handles
`supersede`, `close`, `correct-lane`; refuses close without `--evidence`; is in SPIRA_LANES;
declares FAYTH_LANE=groomer. SPIRA_GROOMER_LABEL is a conf key defaulting to 'groom'.

**Finding: `test-groomer.sh` has no `# defect:` citation.**  
Every new test in this epic should cite the bead it exists for (`law-seen-red-must-be-seen-in-ci`,
design test strategy). The expected citation is `# defect: sp-gsmx.8`. Its absence means
citations.sh reports this suite as "uncited" — which is exactly the retirement-undecidable
state the test lifecycle mechanism exists to prevent. The design's test lifecycle section
says "every test QA proposes cites the defect it exists for"; the groomer test was filed
by this epic and should carry that citation.

---

## Coverage delta

New suites added by this epic (9 total):

| suite | citation | status |
|---|---|---|
| test-deploy.sh | `# defect: sp-gsmx.5` | present |
| test-promote.sh | `# defect: sp-gsmx.2` | present |
| test-release.sh | `# defect: sp-gsmx.3` | present |
| test-released-defects.sh | `# defect: sp-gsmx.1` | present |
| test-review.sh | `# defect: sp-gsmx.4` | present |
| test-qa.sh | `# defect: sp-gsmx.6` | present |
| test-groomer.sh | *(none)* | **MISSING — should be sp-gsmx.8** |
| test-citations.sh | `# defect: sp-gsmx.7` | present |

Eight of nine new suites carry citations. test-groomer.sh is the exception.

---

## Findings summary

1. **SPIRA_PATH not forwarded in test helpers** (affects test-review.sh, test-deploy.sh,
   test-released-defects.sh). Root cause: `env -i` invocations in `run_review`, `run_deploy`,
   `rds` omit `SPIRA_PATH`. System bd (CGO_ENABLED=0) cannot read embedded Dolt. Bead filing
   and the released-defect query are untested on this system.

2. **test-groomer.sh missing defect citation** (sp-gsmx.8). The groomer test violates the
   test lifecycle rule the epic introduced.

3. **No explicit test for "dev change does not appear in prod until promoted"**. The mechanism
   implies it; there is no fail-first assertion.

4. **SPIRA_QA_DEPTH runtime behaviour untested**. test-qa.sh only reads persona file content.

---

## What could not be verified

- Whether review.sh's bead-filing path (`_file_one_finding → bdq create`) works in
  production, where the system bd supports embedded Dolt. The path looks correct in code;
  the test failure is an environment issue, not a logic issue.
- Whether qa-sweep.sh produces correct output at different depth settings (no execution test).
