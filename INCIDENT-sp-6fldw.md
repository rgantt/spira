# sp-6fldw: Spira Pipeline Sweep — Schema Mismatch

**Date:** 2026-09-09
**Status:** Waiting on operator decision (sp-y3irn)

## Root Cause
Database schema version mismatch (v61 vs v53) blocking all bd commands, preventing aeon summoning.

## SOP Applied
`sop-spira-no-aeons` correctly identified this as an escalation case.

## Escalation
`sp-y3irn`: Operator decision required on database migration strategy.

## Lesson Learned
Amended SOP to clarify: When an escalation requires operator decision, leave the bead OPEN while waiting for the decision to be executed, rather than closing prematurely.

## Resolution Path
1. Operator makes decision (sp-y3irn)
2. Execute decision (migrate or downgrade)
3. Verify aeons resume
4. Close bead with evidence
