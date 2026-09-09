---
incident: sp-cl00
title: test-now.sh duplicate beads fingerprint dedup
resolved: 2026-09-09T04:58Z
sop: sop-spira-suite-red-duplicate-bead
---

# Resolution

SOP `sop-spira-suite-red-duplicate-bead` matched and held. The incident was closed in a prior session without recording the SOP application, causing it to be reopened and poisoned.

## Root Cause Analysis

The fingerprint deduplication mechanism works correctly within a single repo context (repo:spira beads dedupe together with sp-recur-2..9 labels). The issue occurs across repo boundaries:

- Same suite (e.g., test-now.sh) fails identically
- Filed under repo:spira on one timed run, repo:brain on another
- `incident.sh:open_incident()` filters beads by incoming `LABELS` (line 98) before matching `external_ref`
- When `SPIRA_INCIDENT_LABELS` includes `repo:spira` but existing bead is labeled `repo:brain`, the label filter prevents finding the existing bead
- Result: duplicate beads with different external_ref fingerprints for the same failure

## Findings Filed

- **sp-i33ee**: Code fix needed to either:
  1. Remove `repo:` from `SPIRA_INCIDENT_LABELS`, or
  2. Change `open_incident()` to match `external_ref` without repo label constraint

## Cost

Two aeons currently in_progress doing redundant work (sp-kteb, sp-yfie) on the same failing suites under different repo attributions. Full aeon cost per duplicate.
