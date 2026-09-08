---
type: note
created: 2026-09-08
updated: 2026-09-08
tags: [spira, sop, suite-deduplication]
sources: []
---

# Suite Red Duplicate Bead SOP

**SOP:** `sop-spira-suite-red-duplicate-bead`

## Problem

When a suite stays red across multiple timed suite runs, `suites.sh` files multiple beads that appear to be duplicates.

## Root Cause

`suites.sh` deduplicates on fingerprint. Different fingerprints = different failures (the test output changed).

- sp-lrnj: 49 passed, 1 failed (fingerprint 110912103780)
- sp-ve0u: 48 passed, 2 failed (different fingerprint — second assertion failed)

## Solution

Use `bd supersede <old> --with <new>` when fingerprints match. Do NOT change suites.sh.
