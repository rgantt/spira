# Seed statutes

The statutes a fresh installation starts with. One file per statute, `<slug>.txt`, whose
whole content is the statute text.

**Why they ship as text.** Statutes live in the beads KV store, which is per-installation —
so a colleague cloning this harness gets the mechanism and none of the law that makes it
behave. `seed.sh` writes these into their database on install; without that step every rule
below has to be rediscovered the expensive way, which is how each of them was written.

**What belongs here.** Statutes about the MACHINERY — how a tool actually behaves, which
approach failed and why, the shape of a recurring hazard. A statute that names a repository,
a deploy path, a host's disks or an operator's own preferences stays in that operator's own
database and does not ship (`law-harness-ships-mechanism-not-inventory`). The line is not
scar-versus-clean: every rule here carries its scar, stated generically, because the scar is
the reason anyone believes the rule.

**Write them to be read a thousand times.** One paragraph, imperative, ~70 words, the scar as
a single clause rather than a narrative. Every agent pays this context on every session, and
`rule.sh enact` refuses anything over 130 words for that reason.

**Seeding never overwrites.** `seed.sh` skips a key already in the database, because an
operator who amended a statute meant it. `--force` overrides, one key at a time.
