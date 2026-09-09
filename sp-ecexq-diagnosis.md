# sp-ecexq: Spira pipeline sweep — sentinel summon logic failure

## Summary
Sentinel timer was disabled and re-enabled by aeon-ifrit. Timer is firing correctly on 2-min cadence, but summon logic silently fails to create aeons. Pipeline remains stalled: 85+ minutes since last landing, 0 aeons alive, 14 beads ready.

## Root Cause
Sentinel.sh executes normally every 2 minutes but the summon logic silently fails to dispatch aeon subprocesses.

## Evidence
- Sentinel timer: Re-enabled 2026-09-09 21:47:57 UTC
- Sentinel execution: Firing every ~2 minutes, completing in 17-25s
- Journal: Clean "Finished" exits with no error logs
- Aeons: Still 0 alive despite ready beads

## Next Steps
1. Capture sentinel.sh stdout/stderr to find silent failure point
2. Verify aeon pool capacity and predicate logic
3. Check summon pathway in sentinel.sh

## References
- sp-f683y: Investigation incident for summon logic failure
- sop-spira-no-aeons: Amended with silent failure diagnosis
