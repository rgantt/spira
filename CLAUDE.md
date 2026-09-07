# Working on Spira

This file is for an agent working **on** the harness — changing its code. It is not the brief
an aeon gets when the harness summons it to work a bead; that comes from a persona in
`spira/chamber/`.

Read `README.md` first for what the thing is. This is what is different about editing it.

## The one rule that decides most questions

**This repository is cloned by people whose infrastructure is not yours.** Everything below
follows from that.

Ship the **mechanism**: the rule, the trap, the reason a guard fails closed. Those are why the
code is correct, and a colleague who deletes a guard because it looked arbitrary is a cost you
paid by leaving it unexplained.

Do not ship the **inventory**: a repository name, a deploy path, a host, a person, a bead id,
the date an incident happened. Those teach a colleague's agent to reason about a machine that
does not exist, and sometimes to act on it. Keep the scar as one generic clause — *"a remote
need not be called `origin`"* — and leave the case history wherever your own notes live.

`spira/inventory.sh` is the fence, it runs from the landing gate, and `spira/inventory-deny`
is where you add your own names. It scans comments too, because that is where all of it was.

## Configuration, not constants

Every path, name and label belongs in `spira/conf.sh` with a default derived from where the
harness is installed. A literal in five files is how five programs come to disagree; the
escalation label was exactly that, and the panel is the half nobody notices is wrong, because
it simply shows fewer.

Two keys are deliberately **not** settable from the config file: `SPIRA_HOME` and
`SPIRA_REPO`. Where the harness *is* is a fact about where `conf.sh` sits. The landing gate
extracts a branch to a scratch tree and runs that tree's suites; a config that could point
them back at the installed copy would make the gate test the code already in force, and pass.

## Tests

`spira/test-*.sh`, discovered rather than listed — add one and it is gated. Run the suites
that cover what you changed while you work, and the whole gate once before you push.

**Every suite declares what it covers**, on a `# covers:` line just above its `set -uo
pipefail`, as space-separated path globs. The landing gate selects suites from the changed
files through those declarations and refuses a branch where a suite declares nothing, so this
is the one thing there is to remember when adding a suite. Err wide: a suite run needlessly
costs seconds, while a file no suite claims to cover forces the whole set on every branch that
touches it. Changing a shared file — `lib.sh`, `conf.sh`, `testdb.sh`, any `gate*.sh` — selects
everything, and so does any path no suite claims. `spira/gate-select.sh` is the selector and
`--lint` is what the gate runs; `gate-full.sh` runs the whole set against the base ref daily
and escalates on red, which is what makes a hole in the map a fact within a day rather than
never.

Three properties the existing suites have and a new one should too:

- **A check that finds nothing must first prove it could have found something.** Plant an
  offender and require the matcher to say so, then believe it when it is silent.
- **Test against the real dependency**, on a throwaway instance (`spira/testdb.sh`), not a
  hand-written model of it. A stub reproduces the surface you remember, so its gaps surface
  as failures in correct code.
- **Run in an explicit, minimal environment.** Ambient configuration silently decides
  verdicts: a suite that inherits a real `spira.conf` is asserting against one box, and one
  that inherits `SPIRA_WIKI` will write into a real wiki page.

Pin a configured value to a **non-default** in a fixture where you can. Asserting against the
shipped default passes just as well if the code has the literal written in, which is the thing
the key exists to stop.

## Prose

The comments are long on purpose. Each one exists because something failed in a way that was
not obvious from the code, and the next reader is entitled to know which. Keep them; strip
only what identifies whose machine it happened on.

Write for someone who has the code in front of them and not the history: state the rule first,
then the one clause of why. Never leave a correction on top of a wrong statement — say the
thing as it now stands.
