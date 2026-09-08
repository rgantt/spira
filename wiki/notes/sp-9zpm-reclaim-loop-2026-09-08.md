---
type: note
created: 2026-09-08
updated: 2026-09-08
tags: [spira, ops, incident, reclaim]
sources: []
---

# sp-9zpm: Escalated bead reclaimed 6 times while waiting for operator decision

**Incident:** sp-mfa4 (a BUG: "Nothing invokes suites.sh run") was reclaimed and re-summoned 6 times between 2026-09-08T02:05Z and 2026-09-08T02:54Z while IN_PROGRESS, waiting for an unanswered operator decision (sp-rmnw).

**SOP:** matched `sop-spira-suite-never-run`, check=pass, held=yes. The SOP correctly diagnosed the problem; no amendment needed.

**Root cause:** sp-mfa4 is IN_PROGRESS with a short-lived lease (4 minutes at session start). The reaper/sentinel logic treated it as abandoned work eligible for reclaim, without recognizing that an IN_PROGRESS bead waiting purely on an unanswered `needs-ryan` sub-decision (sp-rmnw) is in a **stable waiting state** — not stalled, not abandoned, but blocked until the operator decides.

The reclaim loop re-summoned aeons 6 times, each performing the same SOP CHECK (grep for suites.sh unit invocations), re-reading sp-rmnw, confirming no change, and exiting — at real session cost but no bead attempt charge (reclaim-refused means worker didn't survive to judge).

**What happened next:** The operator answered sp-rmnw on 2026-09-08T02:13Z: "install the default (a timer), capped at hourly." sp-mfa4 was then completed, landed on spira-harness main (commit 75a6e92), and closed with full evidence. But sp-9zpm (this incident) persisted because the previous aeon session was killed before it could commit.

**Design fix deployed:** sp-rzyl, landed on spira-harness main after 75a6e92, protects IN_PROGRESS beads with unanswered `needs-ryan` sub-dependencies from CHECK 2 reclaim. The reclaim loop is now prevented.

**Verification:** 
- sp-mfa4 is CLOSED with evidence: timer installed, verified operational (`systemctl --user list-timers spira-suites.timer`), pushed to origin/main.
- sp-rzyl landed and prevents recurrence.
- SOP applied and held.

**Related:** [[sp-mfa4]], [[sp-rmnw]], [[sp-rzyl]]
