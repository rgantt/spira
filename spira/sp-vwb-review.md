# sp-vwb: Final verification — epic sp-39f alignment and test coverage

Reviewed 2026-09-08. This file exists to land sp-vwb; the full report is in the
bead's close reason.

## Tiers run

- `spira/test-watch-refresh.sh` — 71 passed, 8 failed (install-section failures;
  see below)
- `spira/test-watch-notify.sh` — 79 passed, 5 failed (same cause plus one path
  validation gap)
- `spira/test-session-hook.sh` — 93 passed, 0 failed
- `spira/test-watchtower.sh` — 67 passed, 0 failed
- `spira/test-conf.sh` — 9 passed, 0 failed

## Per-bead verdicts

| Bead | Title | Verdict |
|---|---|---|
| sp-ozl | Manifest + template + install wiring | Intent served |
| sp-x8c | Rewrite watchd.sh as CLI | Intent served |
| sp-gys | Staleness refresh timer | Intent served; tests have 8 install-section failures |
| sp-3ax | Health assertions, DEGRADED, LAST EVENT, restart meter | Intent served; test-watchd.sh deleted by 7357fb3 |
| sp-6z5 | Fold verdicts.sh, delete it | Intent served |
| sp-4vp | Session hook, off Gas Town path | Intent served; 93/93 passing |
| sp-ee4 | Notify timer | Intent served; tests have 5 failures |
| sp-0ee | cockpit-remote watch on manifest | Intent served |
| sp-400 | Retire Gas Town watcher processes | Intent served for processes; harness-only commit adds doctor.sh check |

## Findings

**Finding 1 — test-watchd.sh deleted, load-bearing test gone.**
sp-3ax wrote `test-watchd.sh` (135–174 lines) covering manifest parsing, cursor
arithmetic, health assertions, and the discriminating DEGRADED test with a
Gas-Town-only state fixture. Ryan's 7357fb3 commit (2026-09-07, "delete the gate")
swept it with 43 other suites. The test the bead description called "must fail
against today's code" no longer exists. The mechanism is correct; the proof-test
is absent. No Gas Town-only state fixture was captured as a repo file.

**Finding 2 — test-watch-refresh.sh and test-watch-notify.sh have 8+5 failures.**
Cause: sp-syub (landed 2026-09-08) added an aeon-live check to `install.sh` —
`systemctl --user list-units --state=active --no-legend spira-aeon-*.service`. The
test stubs in those two files echo all arguments to stdout; this makes install.sh
interpret the stub's output as a live-aeon list and refuse to run daemon-reload.
The logic under test is correct; the stubs pre-date the guard. Additionally,
test-watch-notify.sh has one assertion that checks `every path in it came from
configuration` but does not include the SPIRA_PROD-derived path (`$CLONE-prod/`)
in its allowed set, causing a false failure.

The sp-400 commit message noted "pre-existing test-watch-refresh.sh FAIL is a
clone-path assertion unrelated to this bead" — this was the same symptom, slightly
misdiagnosed. The root cause is the stub not suppressing stdout for the aeon query.

**Finding 3 — integration tier tests not written.**
The design called for: start a daemon watcher against a temp db, write an event,
assert it reaches the log, cursor advances, drain replays once; detach/re-latch
replays exactly N; staleness restart within one period. None were written by any
epic bead.

**Finding 4 — non-goals maintained.**
Gas Town log files at /workspaces/gt/.runtime/watchd/*.log untouched ✓. Cockpit
panel and collect.sh unchanged ✓. ask.sh/reply.sh unchanged ✓. cockpit-ensure not
replaced ✓. Wiki not used for watcher state ✓. No general pub/sub ✓.

## What could not be verified without prod

The actual latch path (a live session consuming hook stdout and re-attaching a
Monitor) was not verified end-to-end — this requires a running session and a real
context reset. The hook's stdout was verified to contain the correct latch commands
by test-session-hook.sh; the hand-off after that is not exercised in any suite.

## Overall alignment

The four measurable outcomes from the Intent are structurally present:

1. **Continuity across reset**: log is append-only, cursor is a file, drain replays
   the gap — correct by construction. Not integration-tested.
2. **Delivery without a session**: notify timer with once-per-backlog semantics
   implemented and tested (via log rows).
3. **No watcher outlives its configuration**: refresh timer implemented, cheap
   (2 execs, no db), restart counter present. 71/79 assertions pass; failures
   are in the install-section stubs, not in the guard logic.
4. **Blindness reported as DEGRADED**: health-ids command correct, manifest uses
   it for the answers watcher, DEGRADED rendering tested through session hook
   suite. Load-bearing regression test absent (Finding 1).

The code serves the intent. The test gap is real and should be restored.
