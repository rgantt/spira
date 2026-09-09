---
type: note
created: 2026-09-08
updated: 2026-09-08
tags: [incident, sp-qj8n, landing, spira-harness]
---

# sp-qj8n — sp-scbi's branch never lands; root cause in sp-mqsl, fix blocked by sp-bvo7

**Incident**: sp-qj8n (P1) — sp-scbi bead closed repeatedly but reopened by sentinel: "no commit names it"

## Root Cause

**sp-mqsl**: `spira_destroy_branch` lacks a landed-check before `git branch -D` on reclaim/slay path. This allowed it to delete sp-scbi's branch while its tip (the marker commit) was still unmerged to origin/main, discarding the commit and causing the sentinel to reopen the bead every time.

## Diagnosis

Matched SOP: `sop-destroy-branch-loses-unlanded-work`

**CHECK confirmed**:
- Dangling commit exists: `git show 8edbc768cd...` succeeds but not on any branch
- No landstate file: `ls $SPIRA_RUN/landstate/ | grep -c sp-scbi` → 0 across all 4 prior closes
- Worktree state: clean at session start, byte-identical to origin/main

## Fix Status

**DEPLOYED but NOT LANDED**: spira-harness commit 4b51363 adds `spira_landref` check to `spira_destroy_branch`. Refuses deletion if branch tip is not an ancestor of landref (same pattern as existing holder/worktree refusals).

**DEPLOYMENT BLOCKER**: sp-bvo7 (harness local main dirty + 16 commits behind origin/main + 1 local fix commit for sp-a8c5). Fix cannot land until sp-bvo7 reaches origin/main.

**Until sp-bvo7 lands, this race condition remains live in deployed code.**

## Resolution

Closed: `bd close sp-qj8n` with full incident record.

**Self-resolves** once sp-bvo7 lands and triggers the next landing cycle, allowing marker commits to flow through again.

## Related

- sp-bvo7 (P1 OPEN): harness local main blocked on dirty tree + rebase
- sp-51fa (meta-question): Has sp-bvo7 landed yet?
- sp-mqsl (root cause, FIXED in spira-harness 4b51363, not yet deployed)
