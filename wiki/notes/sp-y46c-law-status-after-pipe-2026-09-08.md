---
type: note
created: 2026-09-08
updated: 2026-09-08
tags: [spira, statute, pipeline, exit-status]
sources: []
---

# sp-y46c: Enacted law-status-after-a-pipe-is-the-last-command

Ryan approved the statute text on sp-98f8 (closed 2026-09-08). The archivist noted the enactment had not occurred and filed sp-y46c.

**Statute enacted:** `law-status-after-a-pipe-is-the-last-command` via `rule.sh enact`.

**Text:** The exit status after a pipeline belongs to the LAST command in it, so reading it after piping into head, tail, grep or sed reports the pager's status and never the program's. Capture the output first and read the status of the bare command, or address PIPESTATUS explicitly. A check that reports success it did not measure is worse than no check.

**Scar:** A gate run piped into tail reported rc=0 while the landing gate was red; the spira repo stayed unlandable until a bead came back with rc=1 (sp-98f8, 2026-09-08).

**Wiki page:** `brain:wiki/notes/common-law.md` regenerated and pushed (commit 3410c83).
