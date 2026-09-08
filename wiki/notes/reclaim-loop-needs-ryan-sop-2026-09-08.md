---
type: note
created: 2026-09-08
updated: 2026-09-08
tags: [spira, ops, incident, sop, reclaim, needs-ryan]
sources: []
---

# Reclaim Loop on Needs-Ryan Block — SOP Amendment

**Incident:** sp-2k5a — Sentinel/reclaim cadence re-summons IN_PROGRESS beads blocked purely on an unanswered needs-ryan dependency.

**Previous incident:** [[sp-9zpm]] — sp-mfa4 reclaimed 6 times while waiting for operator decision on sp-rmnw.

## Mechanism

An IN_PROGRESS bead whose only open blocker is a `needs-ryan`-labelled ask is in a **stable waiting state**, not abandoned work. However:

1. The reaper/sentinel lease logic treats short-lived leases (e.g., 4 minutes) uniformly — no exemption for needs-ryan dependencies
2. When the lease expires, the bead is reclaimed and re-summoned
3. Each aeon session re-derives the identical diagnosis (blocked on an unanswered ask, nothing actionable), but burn resources and labels

## SOP Application

**SOP:** `sop-reclaim-loop-on-needs-ryan-block`

**Check:** Confirm the bead is IN_PROGRESS with `sp-reclaim-N-refused` labels, all citing the same diagnosis and an unanswered needs-ryan blocker still open.

**Fix:** 
- If the blocking needs-ryan ask has already closed, close this bead and note it
- If still open, do not re-diagnose; link to [[sp-rzyl]] (the systemic fix) and stop

## Systemic Fix

[[sp-rzyl]] adds a sentinel CHECK 2 exemption: IN_PROGRESS beads with unanswered needs-ryan sub-dependencies are protected from reclaim. This prevents the re-summon cycle.

**Verification:** sp-rzyl landed on spira-harness main (after commit 75a6e92) and prevents recurrence.

## Related

- [[sp-9zpm]] — the original reclaim loop incident 
- [[sp-mfa4]] — the bead that was repeatedly reclaimed
- [[sp-rmnw]] — the needs-ryan decision that was blocking
- [[sp-rzyl]] — the systemic fix (sentinel/reclaim protection)
