# sp-o6zkx closure — incident dedup investigation

## Summary
Incident recurred 9 times due to duplicate refs being filed with title-based keys.

## Root Cause
Caller invokes `incident.sh file` WITHOUT setting stable `SPIRA_INCIDENT_REF`, causing:
- "Spira sweep" vs "Spira sweep — is the pipeline moving?" → two different refs
- incident.sh generates: `incident:$(title | tr | cut)`

## Verified Callers
- **watchtower.sh**: ✓ Sets stable refs (lines 522, 539, 579)
- **suites.sh**: ✓ Sets stable refs (lines 211, 265)

## Actions Taken
1. Collapsed 12 duplicate beads to 5 primaries via `bd supersede`
2. Identified mystery caller as root cause (still unknown caller)
3. Filed sp-xo4xl investigation bead to audit remaining callers
4. Amended sop-incident-duplicates-unstable-ref with findings

## Next
Find caller producing "Spira sweep" variants, add SPIRA_INCIDENT_REF="incident:spira-sweep".
