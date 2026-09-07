//! What the panel shows, and what acting on each kind actually means.
//!
//! Four views, because there are four genuinely different things and collapsing them
//! loses what makes each useful:
//!
//! | view | what it is | lives in | acting on it |
//! |---|---|---|---|
//! | DECISIONS | open work on the operator | beads, the escalation label + `overseer` | close it; the reason IS the verdict |
//! | FYI | something already true | beads, `insight`+`overseer` | dismiss it — read and move on |
//! | NOTIFICATIONS | something already happened | Gas Town mail, `overseer` | mark it read |
//! | ALERTS | a condition that is true NOW | beads, `event`+`alert`+`overseer` | acknowledge it, or silence it for an hour |
//!
//! An INSIGHT is closed by construction: there is nothing to do, only something to know. It
//! exists because an answer that scrolls off screen is lost. A NOTIFICATION is neither work
//! nor a keepsake — mail is a PULL medium, so nothing announces one, and 80 had accumulated
//! unread including "CI failed" and "HOLLOW-CLOSE: 1 bead(s) closed with an open dependency".
//!
//! WHY THE INSIGHTS TAB SAYS "FYI" (the operator, verbatim: *"these insights seem more like bug
//! reports which means they're implicitly asking me for feedback -- really they should be FYI
//! only"*). The view rendered in the same shape as DECISIONS — a `default:` line, a turn
//! marker saying whose ball it was, a footer offering `⏎ decide` — and the bodies themselves
//! were written by `ask.sh` from the ESCALATION template, so an insight opened with
//! "**What is blocked:**" and closed by telling them to record a verdict. Nothing about it
//! said "record". Every one of those affordances is now view-aware, and the tab is named for
//! what the view is rather than for the label the beads carry.
//!
//! AN ALERT IS NOT A DECISION, and the discriminator is LIFECYCLE, not urgency: an alert is a
//! condition that SELF-CLEARS, a decision is one that gets ANSWERED. If the loop unwedges on
//! its own the alert must vanish with nobody touching it. Everything in the other three tabs
//! persists until the operator acts on it, and that property is what makes DECISIONS worth
//! trusting — nothing leaves unless they moved it. Mixing in items that disappear by
//! themselves teaches that not acting is sometimes fine, which is corrosive to the one list
//! where acting is the point. Two more differences follow: an alert may fire, clear and
//! re-fire for one cause, while a decision asked twice is a defect the statute book exists to
//! prevent; and an alert carries no recommended default, because there is nothing to choose
//! until they have looked.
//!
//! IT IS CALLED "ALERTS", NOT "ESCALATIONS". Escalation already means something exact in the
//! escalation policy and in several statutes — a bead carrying the escalation label, a
//! decision, a default, and what is blocked. Reusing the word for a machine-generated
//! condition would blur the one term that policy rests on.
//!
//! AND AN ALERT DOES NOT CARRY THE ESCALATION LABEL, which is why the DECISIONS filter has to
//! exclude it explicitly rather than merely not matching it: an alert bead carries `overseer`,
//! and DECISIONS admits the escalation label OR `overseer`, so without that exclusion every
//! firing alert would appear in the one list this whole design exists to keep self-clearing
//! items out of. The label is withheld deliberately — the escalation label is excluded from
//! every fayth predicate and from the guard that forbids closing through a resolve, so
//! carrying it would stop the writer clearing its own alert when the condition passes.
//!
//! AND A DISMISSED INSIGHT LEAVES THE PANE, but stays reachable: `d` adds `archived`, `h`
//! shows the archived ones and `d` there takes the label back off. An acknowledged item that
//! stays put teaches the operator to ignore the pane, which is law-alerts-must-be-actionable wearing
//! a different hat; an acknowledged item that vanishes irrecoverably makes dismissing it a
//! decision, which is the cost this view exists to avoid.
//!
//! Reading lives in `store`; this module only defines the vocabulary and the writes.

use std::process::Command;

/// The actor name this session writes comments under.
///
/// It has to differ from the operator's. Both were `overseer` at first -- the Gas Town human
/// mailbox -- so a reply of mine was indistinguishable from one of theirs: the answer watcher
/// announced the agent's own comment back to it as an operator reply, and the pane could not have
/// shown whether a thread was waiting on them or on me.
pub const ME: &str = "claude";

/// The actor name the OPERATOR's own comments are recorded under, from `SPIRA_OPERATOR_ACTOR`.
///
/// The pane and the agent both write into the same thread, so the two have to be tellable
/// apart or the turn marker claims it is the operator's move on a reply the agent just wrote.
/// A literal here would be one installation's name, and every other installation would see
/// its own replies as somebody else's.
pub fn operator_actor() -> String {
    std::env::var("SPIRA_OPERATOR_ACTOR").unwrap_or_else(|_| "operator".to_string())
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum View {
    Decisions,
    Insights,
    Notifications,
    Alerts,
}

impl View {
    pub const ALL: [View; 4] = [
        View::Decisions,
        View::Insights,
        View::Notifications,
        View::Alerts,
    ];

    pub fn title(self) -> &'static str {
        match self {
            View::Decisions => "DECISIONS",
            View::Insights => "FYI",
            View::Notifications => "NOTIFICATIONS",
            View::Alerts => "ALERTS",
        }
    }

    /// What the destructive key does HERE. Closing a decision records a verdict; dismissing
    /// an insight only means "read"; marking mail read changes nothing but the inbox;
    /// acknowledging an alert says "seen" and changes NOTHING about the condition. One
    /// word for all four is how a keypress silently does nothing — `bd close` on an
    /// insight is a no-op, because an insight was created closed.
    ///
    /// `dismissed` is the history toggle. In FYI the same key UNDOES the dismissal; in
    /// ALERTS it lifts a silence. Saying "dismiss" over a list of already-dismissed items is
    /// the same silent no-op one layer along.
    pub fn verb(self, dismissed: bool) -> &'static str {
        match self {
            View::Decisions => "close",
            View::Insights if dismissed => "restore",
            View::Insights => "dismiss",
            View::Alerts if dismissed => "unsilence",
            View::Alerts => "ack",
            View::Notifications => "mark read",
        }
    }

    /// Whether this view keeps a set of items behind `h`.
    ///
    /// FYI hides what has been dismissed; ALERTS hides what has cleared or been silenced.
    /// DECISIONS has none — a closed decision is a verdict, not a hidden row — and mail has
    /// `gt mail`. Asked rather than open-coded so the key, the tab name and the footer
    /// cannot come to disagree about which views have a history.
    pub fn has_history(self) -> bool {
        matches!(self, View::Insights | View::Alerts)
    }

    pub fn next(self) -> View {
        let i = Self::ALL.iter().position(|v| *v == self).unwrap_or(0);
        Self::ALL[(i + 1) % Self::ALL.len()]
    }

    pub fn prev(self) -> View {
        let i = Self::ALL.iter().position(|v| *v == self).unwrap_or(0);
        Self::ALL[(i + Self::ALL.len() - 1) % Self::ALL.len()]
    }
}

/// The labels an alert bead carries, and what each one means.
///
/// The contract is sp-auron's: `issue_type: event`, plus `alert` and `overseer`. Open means
/// FIRING; closed means the condition cleared and the writer retracted its own statement.
/// Everything else the tab needs is a label, because a label is what a writer can set and
/// unset in one `bd update` without rewriting a description it did not compose.
pub mod alert {
    /// Present on every alert bead. The DECISIONS view excludes on this too — see the module
    /// header for why not matching is not enough.
    pub const LABEL: &str = "alert";
    /// The operator has seen it. Says nothing about the condition, which is why an acked alert STAYS
    /// on the tab: hiding a firing alert because someone looked at it is the reassuring lie
    /// this pane exists to prevent.
    pub const ACKED: &str = "acked";
    /// `silent-until:<ISO-8601 UTC>` — hidden from the tab until that instant, then back on
    /// its own if the condition is still true. The deadline is IN the label rather than in a
    /// timer somewhere, so the silence expires with nobody running: a silence that needs a
    /// process to lift it is a silence that outlives the process.
    pub const SILENT: &str = "silent-until:";
    /// `flaps:<n>` — how many times this one condition has fired. A condition that clears and
    /// returns reopens THIS bead and bumps the count; ten beads for one cause is how a pane
    /// becomes wallpaper (law-alerts-must-be-actionable).
    pub const FLAPS: &str = "flaps:";
    /// How long `s` silences for. One hour: long enough to be working on it, short enough
    /// that forgetting costs one hour of blindness rather than a day of it.
    pub const SILENCE_SECS: i64 = 3600;
}

/// Has the operator seen this alert?
pub fn acked(it: &Item) -> bool {
    it.labels.iter().any(|l| l == alert::ACKED)
}

/// How many times this condition has fired, 1 if the bead does not say.
pub fn flaps(it: &Item) -> u32 {
    it.labels
        .iter()
        .find_map(|l| l.strip_prefix(alert::FLAPS)?.trim().parse().ok())
        .unwrap_or(1)
}

/// The whole `silent-until:...` label, which is what `bd update --remove-label` needs.
pub fn silence_label(it: &Item) -> Option<&String> {
    it.labels.iter().find(|l| l.starts_with(alert::SILENT))
}

/// When the silence lifts, in unix seconds. `None` if it is not silenced or the deadline
/// will not parse — an unparseable deadline is treated as no silence at all, because the
/// alternative is an alert silenced forever by a typo.
pub fn silenced_until(it: &Item) -> Option<i64> {
    crate::render::epoch(silence_label(it)?.strip_prefix(alert::SILENT)?.trim())
}

/// Silenced AS OF `now`. The deadline is compared, never merely present: a silence whose
/// hour has passed is over whether or not anything ran to take the label off.
pub fn silenced(it: &Item, now: i64) -> bool {
    silenced_until(it).map(|t| t > now).unwrap_or(false)
}

/// Which write a keypress means. `d` is the view's primary key and `s` exists only in
/// ALERTS, where the two acts differ in the one way that matters to the pane: silencing
/// takes the row off the list, acknowledging does not.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Act {
    /// close / dismiss / restore / mark read / acknowledge / unsilence.
    Primary,
    /// Hide a firing alert until a deadline.
    Silence,
}

/// Does this act take the item off the list currently on screen?
///
/// The pane hides an acted-on row optimistically, so getting this wrong either leaves a
/// closed decision sitting there for a second or — the damaging direction — makes a FIRING
/// ALERT disappear because someone acknowledged it. Acknowledging is not clearing.
pub fn act_hides(view: View, what: Act) -> bool {
    !(view == View::Alerts && what == Act::Primary)
}

#[derive(Clone, PartialEq)]
pub struct Item {
    pub id: String,
    pub title: String,
    /// The one line worth seeing without opening it — a recommended default, usually.
    pub lead: String,
    pub body: String,
    /// question | decision | task | insight, or the sender for mail.
    pub badge: String,
    /// When the item was opened, ISO-8601 UTC.
    ///
    /// It is rendered as an AGE — "26m", "7h", "6d" — never as the wallclock time it holds.
    /// (the operator, verbatim: *"i want to know how long the item has been open, not the
    /// wallclock time it was opened."*) The age is what says a thing is rotting, and it is
    /// why this column beat the id to the list in the first place; the id, and the absolute
    /// timestamp with it, live on the rule below. See `render::age_since`.
    pub when: String,
    /// The comment thread, oldest first: (author, ISO time, text).
    ///
    /// The thread IS the conversation. the operator: "the conversation in the beads pane is already
    /// threaded -- or it should be." Before this, a reply lived in the chat transcript and
    /// the pane showed only a comment COUNT, so answering them meant they had to go somewhere
    /// else to read it -- and twice I answered by filing a NEW bead instead, which forked
    /// the context rather than continuing it.
    ///
    /// It renders ABOVE the ask on both surfaces, because it is the newest and most
    /// decision-relevant thing on the item (the operator, verbatim: "i want threaded replies
    /// at the top"). "Oldest first" is therefore an invariant rather than a description:
    /// `store::oldest_first` enforces it, and the list's turn marker reads `last()`.
    pub thread: Vec<(String, String, String)>,
    /// The bead's labels, verbatim. Empty for mail, which has none.
    ///
    /// Carried rather than pre-digested into flags because the ALERTS view has to WRITE them
    /// back: lifting a silence means handing `bd update --remove-label` the exact string on
    /// the bead, and a flag that only recorded "silenced: true" could not name it. The
    /// readers — `acked`, `flaps`, `silenced_until` — all live here beside the constants they
    /// parse, so the pane and the writer cannot drift into disagreeing about the vocabulary.
    pub labels: Vec<String>,
}

fn run(cmd: &str, args: &[&str]) -> Result<(), String> {
    run_as(cmd, args, None)
}

/// `actor` sets BEADS_ACTOR, which is the name a comment is recorded under.
fn run_as(cmd: &str, args: &[&str], actor: Option<&str>) -> Result<(), String> {
    // Absolute path: tmux's global PATH has no ~/.local/bin, so a respawned pane cannot
    // find `bd` or `gt` by name. See store::bin.
    let mut c = Command::new(crate::store::bin(cmd));
    c.args(args);
    c.env("PATH", crate::store::child_path());
    if let Some(a) = actor {
        c.env("BEADS_ACTOR", a);
    }
    // Inside the predecessor's directory when there is one: `gt` resolves its world from the
    // working directory. When there is none, do not set one — a nonexistent cwd fails the
    // spawn and would read as a broken binary.
    if let Some(t) = crate::store::town() {
        c.current_dir(t);
    }
    match c.output() {
        Err(e) => Err(format!("{cmd}: {e}")),
        Ok(o) if !o.status.success() => Err(format!(
            "{cmd}: {}",
            String::from_utf8_lossy(&o.stderr)
                .lines()
                .next()
                .unwrap_or("failed")
        )),
        Ok(_) => Ok(()),
    }
}

/// A VERDICT IS NEVER BLOCKED, AND IS NEVER DISCARDED. Both halves were learned from one
/// bead: sp-wok.5, an operator task decomposed out of an epic and therefore carrying a
/// `blocks` edge onto a sibling that had not landed. `bd close` refuses a blocked issue —
/// *"cannot close blocked issue: sp-wok.5 is blocked by [sp-wok.3] (use --force to
/// override)"* — so every answer typed into this pane failed, and because the text lived
/// only in the argument list of a command that exited 1, each one was thrown away. The
/// operator answered it more than three times and it came back untouched, with no comment on
/// the bead to show any of it had happened.
///
/// `--force`, because beads' blocked-close guard is aimed at an AGENT closing work whose
/// prerequisite is unbuilt, and this pane is the one place where the human who owns the
/// decision is the one pressing the key. Their dependency edges order the WORK; they do not
/// order the answer. `resolve.sh` has always closed this way; only the pane and `ask.sh`
/// were left behind.
///
/// NOTHING CURRENTLY CATCHES THE HOLLOW CLOSE THIS PERMITS, and that is stated here rather
/// than assumed because the first version of this comment asserted the opposite. HOLLOW-CLOSE
/// was a Gas Town check — `settings/watch-town.sh` mailed it to the Mayor — and Gas Town was
/// decommissioned. Spira has no equivalent: `bd list --label alert` returns 0 rows because
/// the ALERTS tab shipped its reader and no writer (sp-alerts, closed, says so in as many
/// words), and sp-auron, the designated first writer, watches loop staleness and dead leases
/// rather than the bead graph. So forcing here genuinely does drop a signal that used to
/// exist. It is still the right trade — the alternative was destroying the operator's typed
/// verdict, every time — but the missing check is sp-hollow, not a fact about this function.
///
/// And should the close fail anyway, the typed text is written to the bead as a comment
/// before the error is returned. Whatever else goes wrong, the answer survives in the one
/// place the next reader will look.
fn close_decision(db: &str, id: &str, reason: &str) -> Result<(), String> {
    let actor = operator_actor();
    let e = match run_as(
        "bd",
        &["-C", db, "close", id, "--reason", reason, "--force"],
        Some(&actor),
    ) {
        Ok(()) => return Ok(()),
        Err(e) => e,
    };
    match run_as("bd", &["-C", db, "comments", "add", id, reason], Some(&actor)) {
        Ok(()) => Err(format!("{e} — still open; your answer is kept as a comment")),
        Err(_) => Err(format!("{e} — AND THE ANSWER WAS NOT SAVED: {reason}")),
    }
}

/// Mark every notification read in one call. `gt mail mark-read` costs ~3.8s per message;
/// at 80 unread that is five minutes of keypresses to clear an inbox nobody had read. The
/// bulk form is a single call.
pub fn act_all(view: View) -> Result<(), String> {
    match view {
        View::Notifications => run("gt", &["mail", "mark-read", "--all"]),
        // Deliberately unavailable elsewhere: closing every decision at once would discard
        // verdicts, and there is no undo.
        _ => Err("bulk clear is only for notifications".into()),
    }
}

/// The label a dismissed insight carries. `store` filters on it and `ask.sh list insights`
/// already honours it, so the pane and the shell path agree on what "read" means.
pub const ARCHIVED: &str = "archived";

/// `dismissed` says the FYI view is showing its history, where the same key RESTORES.
///
/// Dismissal is reversible on purpose. The bead asked for an insight to "leave the pane ...
/// retrievable but not cluttering", and a one-way key turns glance-and-move-on into a
/// decision -- which is the friction that left every insight sitting there in the first place.
pub fn act(
    view: View,
    item: &Item,
    reason: &str,
    dismissed: bool,
    what: Act,
    now: i64,
) -> Result<(), String> {
    let db = crate::store::db();
    match (view, what) {
        // CLOSED AS THE OPERATOR, for the same reason a comment is. beads records the
        // closing actor in its audit events and nowhere else -- the issue row has no
        // `closed_by` -- so that event is the only thing that can tell their verdict
        // from an agent's close. Left unstamped, the actor was whatever git identity
        // the pane inherited, and a watcher announced an agent's OWN close back to it
        // as an answer the operator never gave. A session that acts on that is acting
        // on its own echo, and it is silent because the text reads exactly like a
        // real verdict.
        (View::Decisions, _) => close_decision(&db, &item.id, reason),
        (View::Insights, _) => run(
            "bd",
            &[
                "-C",
                &db,
                "update",
                &item.id,
                if dismissed { "--remove-label" } else { "--add-label" },
                ARCHIVED,
            ],
        ),
        (View::Notifications, _) => run("gt", &["mail", "mark-read", &item.id]),

        // SILENCING WRITES A DEADLINE, NOT A FLAG. `silent-until:<ISO>` expires by being read,
        // so nothing has to run to lift it. Re-silencing replaces the old label rather than
        // adding a second one — two deadlines on one bead is a question with two answers, and
        // `silence_label` would return whichever `bd` happened to list first.
        (View::Alerts, Act::Silence) => {
            if let Some(old) = silence_label(item) {
                run("bd", &["-C", &db, "update", &item.id, "--remove-label", old])?;
            }
            let until = format!(
                "{}{}",
                alert::SILENT,
                crate::render::iso(now + alert::SILENCE_SECS)
            );
            run("bd", &["-C", &db, "update", &item.id, "--add-label", &until])
        }

        // `d` IN THE HISTORY LIFTS A SILENCE — and a CLEARED alert has none to lift. Saying so
        // out loud rather than running a no-op `bd` that exits 0: the history holds both kinds
        // side by side, and a key that appears to work on the wrong one teaches the operator that the
        // footer is decoration. Same defect `verb` exists to prevent, one layer along.
        (View::Alerts, Act::Primary) if dismissed => match silence_label(item) {
            Some(old) => run("bd", &["-C", &db, "update", &item.id, "--remove-label", old]),
            None => Err("this one has cleared — a record, with no silence to lift".into()),
        },

        // ACKNOWLEDGING SAYS "SEEN" AND NOTHING ELSE. It must never close the bead: closing is
        // the writer's retraction of its own statement, and a hand-closed alert whose condition
        // is still true is reopened on the next pass — so the pane would have taught the operator that
        // acting on an alert does nothing. See `act_hides`: the row STAYS.
        (View::Alerts, Act::Primary) => {
            if acked(item) {
                return Err("already acknowledged".into());
            }
            run(
                "bd",
                &["-C", &db, "update", &item.id, "--add-label", alert::ACKED],
            )
        }
    }
}

/// A comment is never a completion. Replying used to mark things done, which once recorded
/// the operator's clarifying question as the evidence that the work was finished.
pub fn comment(view: View, item: &Item, text: &str) -> Result<(), String> {
    match view {
        View::Notifications => Err("notifications take no comment — d marks it read".into()),
        // An alert DOES take a comment. There is nothing to decide, but "known, chasing it"
        // belongs on the bead the next reader will open, not in a transcript
        // (law-reply-in-the-thread). It is a comment and never a verdict: the condition
        // clears when it clears.
        // Typed in the pane, so the author is the operator — not `overseer`, which the agent
        // also wrote under, and not the git identity. The pane and the agent must be
        // tellable apart, or a reply of the agent's reads as an answer.
        _ => {
            let db = crate::store::db();
            run_as(
                "bd",
                &["-C", &db, "comments", "add", &item.id, text],
                Some(&operator_actor()),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn an_alert(labels: &[&str]) -> Item {
        Item {
            id: "sp-a1".into(),
            title: "the loop is wedged".into(),
            lead: String::new(),
            body: "no completed pass in 40m".into(),
            badge: "alert".into(),
            when: "2026-09-05T10:00:00Z".into(),
            thread: Vec::new(),
            labels: labels.iter().map(|s| s.to_string()).collect(),
        }
    }

    /// THE ONE THAT MATTERS. The pane hides an acted-on row optimistically, and acknowledging
    /// an alert changes nothing about the condition — so a `true` here is a FIRING alert
    /// vanishing from the pane because someone looked at it, which is the reassuring lie the
    /// whole surface exists to prevent. Every other act does remove its row.
    #[test]
    fn acknowledging_an_alert_does_not_remove_it_from_the_pane() {
        assert!(!act_hides(View::Alerts, Act::Primary));
        assert!(act_hides(View::Alerts, Act::Silence));
        for v in [View::Decisions, View::Insights, View::Notifications] {
            assert!(act_hides(v, Act::Primary), "{v:?}");
        }
    }

    /// The vocabulary, read the way the pane reads it. A missing `flaps:` label means the
    /// condition has fired once — not zero times, which would render "×0" on a live alert.
    #[test]
    fn the_alert_labels_read_back_as_written() {
        let plain = an_alert(&["alert", "overseer"]);
        assert!(!acked(&plain));
        assert_eq!(flaps(&plain), 1);
        assert_eq!(silenced_until(&plain), None);
        assert!(!silenced(&plain, 0));

        let marked = an_alert(&[
            "alert",
            "overseer",
            "acked",
            "flaps:7",
            "silent-until:2026-09-05T17:20:00Z",
        ]);
        assert!(acked(&marked));
        assert_eq!(flaps(&marked), 7);
        assert_eq!(silenced_until(&marked), Some(1_788_628_800));
        assert!(silenced(&marked, 1_788_625_200), "before the deadline it is quiet");
        assert!(!silenced(&marked, 1_788_628_800), "at the deadline it is back");

        // The whole label, because that is the string `bd update --remove-label` needs; a
        // flag saying only "silenced: true" could not name it.
        assert_eq!(
            silence_label(&marked).map(String::as_str),
            Some("silent-until:2026-09-05T17:20:00Z")
        );
    }

    /// A deadline that will not parse is NO silence, never an eternal one. The failure
    /// direction has to be "you still see it": an alert silenced forever by a typo is a
    /// condition removed from the pane with nothing anywhere saying it is still true.
    #[test]
    fn an_unparseable_deadline_silences_nothing() {
        let junk = an_alert(&["alert", "overseer", "silent-until:whenever"]);
        assert_eq!(silenced_until(&junk), None);
        assert!(!silenced(&junk, 1_788_625_200));
        // And it is still nameable, so `d` in the history can take the bad label off.
        assert!(silence_label(&junk).is_some());
    }
}
