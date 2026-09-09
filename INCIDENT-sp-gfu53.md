# sp-gfu53 — RESOLVED: Beads schema mismatch false alarm

**Date:** 2026-09-09 18:02 UTC  
**SOP:** sop-beads-schema-mismatch (matched, amended for false alarm detection)  
**Status:** RESOLVED — false alarm from wrong binary version

## Summary

FALSE ALARM: Schema mismatch error was coming from bd v1.2.2 in PATH, not the production SPIRA_BD (v1.1.0 dev). The production binary reads schema v61 without error. DRAINING state lifted, aeons operating normally (4+ live).

## Diagnosis

- **False alarm detection:** bd v1.2.2 (from $PATH) reports "schema v61 vs v53"
- **Production status:** SPIRA_BD v1.1.0 dev connects to database without error
- **System health:** Aeons running, ready beads being worked, operations normal
- **Root cause:** Schema error came from wrong binary version used for diagnosis

## Resolution

No action required. Production system is healthy. Updated SOP sop-beads-schema-mismatch to detect false alarms:
- Distinguish between error from wrong binary vs real mismatch  
- Check SPIRA_BD (production) vs bd in PATH (may be dev/test version)
- Verify aeons are running as the primary health indicator

## Notes

- Previous sessions identified this but closed without writing the SOP
- Bead reopened/poisoned for missing runbook
- SOP amended with improved CHECK to prevent future false alarms
