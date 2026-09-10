# sp-b1wcd: Incident Dedup Failures — Investigation and Collapse

## Summary
Identified and collapsed 15 duplicate incident beads caused by dedup failure in incident.sh.
Root cause: Python variable expansion bug in subprocess.run calls.

## Duplicates Collapsed
- incident:Spira-sweep: 8 beads → 1 primary (sp-1kx47)
- incident:Spira-sweep-----is-the-pipeline-moving-: 3 beads → 1 primary (sp-4t3s)
- incident:SENDING--oldest-unsent-branch-*: 2 each for three time ranges
- incident:sending-oldest-unsent: 3 beads → 1 primary (sp-5ffn6)
- incident:dedup-meter-nonzero: 2 duplicates superseded to sp-lv616

Total: 12 surplus beads consolidated using bd supersede.

## Root Cause
File: spira/incident.sh lines 141 and 170
Issue: Python subprocess.run calls use literal '$SPIRA_BD' and '$SPIRA_DB' instead of expanded values
Because: Python code is in single-quoted bash strings where variables are NOT expanded

Example broken code:
```python
subprocess.run(["'$SPIRA_BD'", "-C", "'$SPIRA_DB'", "show", bid, "--json"], ...)
```
This passes the literal string `'$SPIRA_BD'` (with quotes!) to subprocess, which fails with ENOENT.

## Solution
Change to double-quoted Python strings:
```python
subprocess.run(['$SPIRA_BD', '-C', '$SPIRA_DB', 'show', bid, '--json'], ...)
```
This allows bash to expand variables before Python parses the string.

## Related Beads
- sp-xp059: Root-cause finding filed in spira-harness repo (builders own the fix)

## SOP Applied
- sop-incident-dedup-collapsed: CHECK passed, duplicates collapsed, held=yes
- No new SOP needed (existing SOP covered this pattern)

## Verification
After the fix is applied:
- incident.sh will correctly find open/closed beads by external_ref
- Duplicate beads will no longer be filed for recurring events
- Recurrence counts will properly increment on existing beads
