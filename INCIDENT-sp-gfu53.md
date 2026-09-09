# sp-gfu53 — Beads schema mismatch

**Date:** 2026-09-09 18:02 UTC  
**SOP:** sop-beads-schema-mismatch (matched, CHECK passed)  
**Status:** ESCALATED — awaiting operator decision

## Summary

Database schema at v61 (from buggy beads v1.2.0/v1.2.1 release) vs binary at v1.2.2 (knows v53). All bd commands blocked by schema mismatch, causing world.sh to gate new aeon summons for 25+ minutes.

## Diagnosis

- **Match:** Schema mismatch error confirmed via bd output
- **Check:** `BD_IGNORE_SCHEMA_SKEW=1 bd --version` = v1.2.2 (correct)
- **Root:** Database migrated by buggy v1.2.0/v1.2.1 release to v61; 8 extra migrations ahead of binary

## Escalation

**Decision question:** Roll back schema to v53 (preferred, ~2 min) OR upgrade beads binary to v61?

**Ask:** sp-rfcrt · "Roll back beads schema v61 to v53, or upgrade beads binary?"

**Default:** Roll back schema (option 1) per beads v1.2.2 recovery guide

## Notes

- Recurrence 2 indicates previous session had the same unresolved escalation
- Operator decision is blocking pipeline clearance
- Bead remains OPEN pending decision (not closed)
