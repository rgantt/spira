# sp-o6zkx: Root cause of dedup failure confirmed

## Finding

When SPIRA_INCIDENT_REF is NOT set, incident.sh generates ref from full title:
- "DEDUP: duplicate incident refs (5 refs, 12 surplus)" → incident:DEDUP--duplicate-incident-refs--5-refs--12-surplus-
- "DEDUP: duplicate incident refs (5 refs, 11 surplus)" → incident:DEDUP--duplicate-incident-refs--5-refs--11-surplus-

These are DIFFERENT refs for the SAME logical incident. Dedup cannot find the prior bead.

## Mystery Caller Still Not Found

Searched all callers:
- watchtower.sh line 580: Sets SPIRA_INCIDENT_REF=incident:dedup-meter-nonzero ✓
- watchtower.sh lines 522, 539: Set stable SPIRA_INCIDENT_REF for SENDING and unadopted ✓
- suites.sh: Sets stable SPIRA_INCIDENT_REF ✓
- install-intake.sh: Uses incident.sh systemd, not file ✓

Unknown caller producing "Spira sweep" and "Spira sweep — is the pipeline moving?" variants
remains unidentified. Must be a third-party caller or wrapper.

## Recommendation

1. Continue search for mystery caller (likely in cockpit or monitoring code)
2. Add enforcement: incident.sh should REFUSE to file if SPIRA_INCIDENT_REF is unset
   (or at minimum warn loudly to stderr with the unset ref)
3. This would surface any missing callers immediately
