---
bead: sp-wp5v
title: retire the sweep-bead debris — eleven beads poisoned for succeeding
resolved: 2026-09-09
---

# sp-wp5v — sweep-bead debris retired

Twelve sweep beads (11 "Spira sweep — is the pipeline moving?" + 1 QA sweep)
accumulated `spira-poison`, `sp-attempt-N-closed-not-landed`, `sp-recur-N`, and
`sp-requeue-N-sop-silent` labels from retry machinery built for work that lands a commit.
A sweep that succeeds has no commit to offer, so every clean pass was penalised as a failure.

## Counts retired

| label class | beads affected |
|---|---|
| `spira-poison` | 12 |
| `sp-attempt-N-closed-not-landed` | 12 |
| `sp-recur-N` | 4 (sp-m0s7, sp-i1x0, sp-hx9k, and one recur on sp-m0s7 reaching sp-recur-8) |
| `sp-requeue-N-sop-silent` | 7 |

Two beads were open at cleanup time (sp-m0s7, sp-637b); both carried the `spira`
partition label, making them dispatchable and able to draw summons on every reopen.

## Procedure applied (sop-spira-verdict-not-executed sequence)

For each bead:
1. Drop all `sp-attempt-N-closed-not-landed`, `sp-recur-N`, `sp-requeue-N-*` labels first.
   (Clearing poison while attempt labels remain re-poisons the bead in one pass.)
2. Remove `spira-poison`.
3. For open beads: close with reason, remove `spira` partition label, add `retired`.

## Precondition confirmed

`sp-z93c` (watchtower stops filing sweep bead) had landed before this ran.
Verified: `ba18dbe feat: watchtower writes sweep prompt instead of filing bead (sp-z93c)` is
on `origin/main`. No new sweep beads will be filed to refill what was retired.

## Result

All 12 sweep beads: closed, de-listed from the dispatchable set, and free of poison debris.
`bd list --label spira-poison --status all` returns 0 sweep-titled beads.
