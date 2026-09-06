//! What the panel shows, and what acting on each kind actually means.
//!
//! Three views, because there are three genuinely different things and collapsing them
//! loses what makes each useful:
//!
//! | view | what it is | lives in | acting on it |
//! |---|---|---|---|
//! | DECISIONS | open work on the operator | beads, the escalation label + `overseer` | close it; the reason IS the verdict |
//! | FYI | something already true | beads, `insight`+`overseer` | dismiss it — read and move on |
//! | NOTIFICATIONS | something already happened | Gas Town mail, `overseer` | mark it read |
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

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum View {
    Decisions,
    Insights,
    Notifications,
}

impl View {
    pub const ALL: [View; 3] = [View::Decisions, View::Insights, View::Notifications];

    pub fn title(self) -> &'static str {
        match self {
            View::Decisions => "DECISIONS",
            View::Insights => "FYI",
            View::Notifications => "NOTIFICATIONS",
        }
    }

    /// What the destructive key does HERE. Closing a decision records a verdict; dismissing
    /// an insight only means "read"; marking mail read changes nothing but the inbox. One
    /// word for all three is how a keypress silently does nothing — `bd close` on an
    /// insight is a no-op, because an insight was created closed.
    ///
    /// `dismissed` is the FYI view's history toggle. There the same key UNDOES the dismissal,
    /// and saying "dismiss" over a list of already-dismissed items is the same silent no-op
    /// one layer along.
    pub fn verb(self, dismissed: bool) -> &'static str {
        match self {
            View::Decisions => "close",
            View::Insights if dismissed => "restore",
            View::Insights => "dismiss",
            View::Notifications => "mark read",
        }
    }

    pub fn next(self) -> View {
        match self {
            View::Decisions => View::Insights,
            View::Insights => View::Notifications,
            View::Notifications => View::Decisions,
        }
    }

    pub fn prev(self) -> View {
        self.next().next()
    }
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
pub fn act(view: View, item: &Item, reason: &str, dismissed: bool) -> Result<(), String> {
    match view {
        View::Decisions => {
            let db = crate::store::db();
            // CLOSED AS THE OPERATOR, for the same reason a comment is. beads records the
            // closing actor in its audit events and nowhere else -- the issue row has no
            // `closed_by` -- so that event is the only thing that can tell their verdict
            // from an agent's close. Left unstamped, the actor was whatever git identity
            // the pane inherited, and a watcher announced an agent's OWN close back to it
            // as an answer the operator never gave. A session that acts on that is acting
            // on its own echo, and it is silent because the text reads exactly like a
            // real verdict.
            run_as(
                "bd",
                &["-C", &db, "close", &item.id, "--reason", reason],
                Some(&operator_actor()),
            )
        }
        View::Insights => {
            let db = crate::store::db();
            run(
                "bd",
                &[
                    "-C",
                    &db,
                    "update",
                    &item.id,
                    if dismissed { "--remove-label" } else { "--add-label" },
                    ARCHIVED,
                ],
            )
        }
        View::Notifications => run("gt", &["mail", "mark-read", &item.id]),
    }
}

/// A comment is never a completion. Replying used to mark things done, which once recorded
/// the operator's clarifying question as the evidence that the work was finished.
pub fn comment(view: View, item: &Item, text: &str) -> Result<(), String> {
    match view {
        View::Notifications => Err("notifications take no comment — d marks it read".into()),
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
