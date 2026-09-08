---
type: note
created: 2026-09-08
updated: 2026-09-08
tags: [spira, ops, incident, watchtower]
sources: []
---

# sp-aapz: Watchtower sweep duplicated 33 times

**Incident:** sp-aapz is a Spira watchtower sweep ("is the pipeline moving?") that duplicated 33 times between 2026-09-07T22:30Z and 2026-09-08T16:20Z.

**SOP:** matched `sop-spira-sweep`, check=pass, held=yes. The sweep is operational: it reads vital signs, not a failure.

**Vital signs:** All normal.
- Minutes since last landing: ? (database schema mismatch reading; last recorded landing showed pipeline moving)
- Branches finished but not landed: 2
- Aeons alive: 0 (expected when no work is in progress)
- Ready beads: 79
- Poisoned: 1 (sp-637b, related to root cause)
- Stranded: 1

**Root cause:** sp-ail7 — the closed-is-not-landed check (law-closed-is-not-landed) requires all closed beads to name a commit by bead ID. This is correct for work that produces code. It is unsatisfiable for beads whose deliverable is not a commit, like QA sweeps and diagnostic passes.

The collision manifests as:
- sp-637b (QA sweep) is closed after examining 45 incidents and filing three beads (sp-w6bw, sp-isj1, sp-bjzj)
- Sentinel reopens it: "closed, but no commit names it"
- sp-637b is re-claimed and re-run, producing the same beads
- Repeat until poisoned
- Meanwhile, the reopen loop generates 33 copies of this watchtower sweep, all asking "is the pipeline moving?" when it is.

**Operational fix:** Ops closed the 33 sweeps and removed them from dispatch (preventing reclaim and re-run), but the root cause persists.

**Design fix required:** sp-ail7 proposes labels like `delivers:beads` or `delivers:report` so beads can declare a non-commit deliverable. The verdict check would then accept a close (with evidence: beads created, or a note written) without requiring a commit name.

**Related:** [[spira-sweep-clean-close-reopen-2026-09-08]], [[sp-ail7]]
