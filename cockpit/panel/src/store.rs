//! One fetch, many views.
//!
//! The panel used to call `load()` for every view on every tab switch: two identical
//! `bd list --all` queries (decisions and insights read the same rows) plus a mail query.
//! Measured — `bd` 1134 ms, `gt mail` 816 ms — that is over three seconds of subprocess
//! before spawn overhead, on a keypress. the operator: *"almost 5 seconds to switch tabs."*
//!
//! So the process boundary is crossed on a TIMER, never on a keystroke. A background thread
//! owns refreshing; the UI thread only ever reads the last snapshot and filters it in
//! memory. Switching tabs costs nothing, and a slow or hung `bd` can never freeze the pane —
//! it just means the snapshot is a few seconds old, which the header says out loud.
//!
//! The two fetches run concurrently, so a refresh costs max(1134, 816) rather than the sum.

use crate::model::{Item, View};
use serde_json::Value;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// The predecessor harness this panel still reads mail from: where `gt mail` lives and the
/// working directory every `gt` call needs, because `gt` resolves its world from the cwd and
/// reports an empty one from anywhere else without erroring. It is NOT a beads database this
/// panel reads — see `db()`.
///
/// `None` is the ORDINARY case and every caller must handle it: an operator who never ran the
/// predecessor has no such directory, and the notifications section simply has no source. A
/// hardcoded path here made the panel unbuildable for anyone but one box.
pub fn town() -> Option<String> {
    match std::env::var("SPIRA_TOWN") {
        Ok(t) if !t.is_empty() => Some(t),
        _ => None,
    }
}

/// Directories prepended to every child's PATH, from `SPIRA_PATH` in `spira.conf`. `bd` and
/// `gt` live in a different place on every box, and this panel is started by tmux, whose
/// global PATH has neither.
fn extra_path() -> Vec<String> {
    std::env::var("SPIRA_PATH")
        .unwrap_or_default()
        .split(':')
        .filter(|d| !d.is_empty())
        .map(str::to_string)
        .collect()
}

/// THE beads database this panel raises, reads, answers and closes in.
///
/// (the operator, verbatim: "let's just use the spira one for everything from here on out. i
/// don't want this migration/deprecation to bake a bunch of complexity and modality into our
/// tools.")
///
/// There was a walk here — the town, one entry per rig, then Spira — with a precedence order,
/// a per-row `_db` tag and a dedupe by id. All four existed because two live databases held
/// the same beads, and all four are gone with that. They were not free while they lasted: the
/// shell tools were switched to Spira before the panel was, which split one conversation
/// across two databases within the hour. Their 18:54 comment landed in the town because the
/// pane wrote there, while `unanswered.sh` read Spira and reported nothing waiting. A
/// half-migrated tool is worse than either end of the migration, because each half is
/// individually correct and together they lose messages.
pub fn db() -> String {
    // No hardcoded fallback. conf.sh exports COCKPIT_DB, defaulting it to SPIRA_DB, and a
    // panel that guessed a database instead would read someone else's conversation.
    std::env::var("COCKPIT_DB")
        .or_else(|_| std::env::var("SPIRA_DB"))
        .unwrap_or_default()
}

/// The label that means "waiting on the operator" — the same one the escalation gate defers
/// on, every persona's predicate excludes, and the shell tools read. It is a configured key
/// rather than a literal in five files, because five literals is how the panel and the
/// predicates come to disagree about which beads are waiting on anyone, and the panel is the
/// half nobody notices is wrong: it simply shows fewer.
pub fn ask_label() -> String {
    std::env::var("SPIRA_ASK_LABEL").unwrap_or_else(|_| "needs-operator".to_string())
}

/// Raw rows plus when they were fetched, and what went wrong if anything did.
#[derive(Clone, Default)]
pub struct Snapshot {
    /// Bumped on every completed refresh. The UI derives its lists from the snapshot and
    /// caches the result against this number, so a keypress re-filters nothing.
    pub gen: u64,
    pub beads: Option<Vec<Value>>,
    /// issue id -> comment rows, for the beads that have any.
    pub threads: std::collections::HashMap<String, Vec<Value>>,
    pub mail: Option<Vec<Value>>,
    pub beads_err: Option<String>,
    pub mail_err: Option<String>,
    pub at: Option<Instant>,
    pub refreshing: bool,
}

impl Snapshot {
    /// Seconds since this snapshot was taken, or None if nothing has landed yet.
    pub fn age(&self) -> Option<u64> {
        self.at.map(|t| t.elapsed().as_secs())
    }
}

pub type Shared = Arc<Mutex<Snapshot>>;

/// Every id the snapshot currently holds, across both stores.
///
/// `pending` — the ids hidden optimistically after a keypress — has to be pruned against
/// this. Left to grow it eventually hides live items: after eight keypresses the panel
/// reported NOTIFICATIONS 0 against a real 17 unread, because entries from earlier actions
/// were still filtering. A count that reads zero when the answer is seventeen is the exact
/// reassuring lie this panel exists to prevent.
pub fn present_ids(s: &Snapshot) -> Vec<String> {
    let mut v = Vec::new();
    for rows in [&s.beads, &s.mail].into_iter().flatten() {
        for r in rows {
            if let Some(id) = r["id"].as_str() {
                v.push(id.to_string());
            }
        }
    }
    v
}

/// Resolve a tool to an absolute path, because PATH cannot be trusted here.
///
/// WHY. The pane came up reading `bd: No such file or directory`. `bd` and `gt`
/// live in ~/.local/bin, and tmux's GLOBAL environment carries a PATH without it — so the
/// panel worked when launched from an interactive shell and broke the moment layout.sh
/// respawned it. Same class as hunk needing node on a login-shell PATH, and as the
/// gt-dashboard unit having to set PATH explicitly because systemd does not inherit one.
///
/// A tool that only works when started by hand is not installed, it is coincidental.
pub fn bin(cmd: &str) -> String {
    if cmd.contains('/') {
        return cmd.to_string();
    }
    let home = std::env::var("HOME").unwrap_or_default();
    // SPIRA_PATH comes FIRST, deliberately, and the operator decides what is in it. On this
    // kind of installation it holds a shim directory whose `gt` is not a duplicate of the
    // real binary: it refuses `gt mail send` to a live agent, and sets BEADS_ACTOR for
    // `gt mail` so mark-read and archive satisfy the mailbox's assignee check. Resolving
    // straight to ~/.local/bin looked like a tidier fix and would have silently broken `d`
    // on a notification.
    let mut dirs = extra_path();
    dirs.extend([
        format!("{home}/.local/bin"),
        "/usr/local/bin".into(),
        "/usr/bin".into(),
    ]);
    for dir in dirs {
        let p = format!("{dir}/{cmd}");
        if std::path::Path::new(&p).is_file() {
            return p;
        }
    }
    cmd.to_string() // let PATH try, and let the error say so
}

/// Always run inside the town: `gt` resolves the town from its working directory and
/// reports an empty world from anywhere else, without erroring.
/// The PATH our children get.
///
/// Resolving `gt` absolutely is not enough: the shim execs the real `gt`, and `gt` shells out
/// to `bd` BY NAME. So a child inherits our PATH and fails one level down, which is how
/// NOTIFICATIONS rendered `?` while DECISIONS worked. Hand them a PATH that has the tools.
pub fn child_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let inherited = std::env::var("PATH").unwrap_or_default();
    let mut dirs = extra_path();
    dirs.extend([
        format!("{home}/.local/bin"),
        "/usr/local/bin".into(),
        "/usr/bin".into(),
        "/bin".into(),
    ]);
    if !inherited.is_empty() {
        dirs.push(inherited);
    }
    dirs.join(":")
}

fn run(cmd: &str, args: &[&str]) -> Result<String, String> {
    let mut c = Command::new(bin(cmd));
    c.args(args).env("PATH", child_path());
    // Only when there IS one. `current_dir` on a path that does not exist fails the spawn
    // outright, so defaulting it would turn "no predecessor configured" into "gt is broken".
    if let Some(t) = town() {
        c.current_dir(t);
    }
    match c.output() {
        Err(e) => Err(format!("{cmd}: {e}")),
        Ok(o) if !o.status.success() && o.stdout.is_empty() => Err(format!(
            "{cmd}: {}",
            String::from_utf8_lossy(&o.stderr)
                .lines()
                .next()
                .unwrap_or("failed")
                .to_string()
        )),
        Ok(o) => Ok(String::from_utf8_lossy(&o.stdout).to_string()),
    }
}

/// `bd --json` and `gt --json` can print human warnings on stdout before the payload.
fn rows(text: &str, key: &str) -> Result<Vec<Value>, String> {
    let start = text.find(['[', '{']).ok_or("no JSON in output")?;
    let v: Value = serde_json::from_str(&text[start..]).map_err(|e| format!("bad JSON: {e}"))?;
    Ok(if v.is_array() {
        v.as_array().cloned().unwrap_or_default()
    } else {
        v[key].as_array().cloned().unwrap_or_default()
    })
}

/// `--all` is required: insights are created CLOSED and `bd list` hides closed issues.
///
/// One call against one database. An error here is a real error and reaches the pane as one:
/// there is no other database whose rows could stand in for these, so silently returning an
/// empty list would render "nothing is waiting" over an unread queue.
fn fetch_beads() -> Result<Vec<Value>, String> {
    let out = run("bd", &["-C", &db(), "list", "--all", "--limit", "0", "--json"])?;
    rows(&out, "issues")
}

/// Comment threads for every bead reporting `comment_count > 0`.
///
/// A thread is fetched, not counted, because the pane has to SHOW the conversation: a count
/// tells the operator something was said and then makes them go elsewhere to read it, which is the
/// thing that pushed replies into the chat transcript in the first place.
fn fetch_threads(beads: &[Value]) -> std::collections::HashMap<String, Vec<Value>> {
    let ask = ask_label();
    let wanted: Vec<String> = beads
        .iter()
        .filter(|r| r["comment_count"].as_u64().unwrap_or(0) > 0)
        // ONLY the beads a view can actually show. The first version filtered on
        // comment_count alone, and `fetch_beads` returns every bead there is — ~1700 rows,
        // of which hundreds carry comments. It spawned 307 concurrent `bd`
        // processes every refresh and drove the load average to 274 on four cores, which is
        // precisely the failure law-fence-loops-on-shared-hardware was written about, from
        // the same hand, the same day. A panel that fetches what it cannot display is not
        // caching, it is a denial of service with a nice UI.
        .filter(|r| {
            let l = labels(r);
            let waiting = l.contains(&ask.as_str()) || l.contains(&"overseer");
            if !waiting {
                return false;
            }
            // A DISMISSED INSIGHT KEEPS ITS THREAD, because `h` brings it back and a
            // retrieved item that silently lost its conversation is the reassuring lie this
            // panel exists to avoid. The cost is bounded by construction: only insights, only
            // ones that already report comments — 4 dismissed insights on this box, 1 of them
            // with a comment. Everything else archived stays excluded, which is what keeps
            // this from becoming the 307-concurrent-`bd` fetch it was before.
            if l.contains(&"insight") {
                return true;
            }
            if l.contains(&"archived") {
                return false;
            }
            r["status"].as_str() != Some("closed")
        })
        .filter_map(|r| Some(r["id"].as_str()?.to_string()))
        .collect();

    let handles: Vec<_> = wanted
        .into_iter()
        .map(|id| {
            thread::spawn(move || {
                let out = run("bd", &["-C", &db(), "comments", &id, "--json"]).ok()?;
                Some((id, rows(&out, "comments").ok()?))
            })
        })
        .collect();

    handles
        .into_iter()
        .filter_map(|h| h.join().ok().flatten())
        .collect()
}

fn fetch_mail() -> Result<Vec<Value>, String> {
    rows(&run("gt", &["mail", "inbox", "--unread", "--json"])?, "messages")
}

/// A FROZEN SNAPSHOT, for verifying the pane without a human and without the beads.
///
/// `PANEL_FIXTURE=<file.json>` makes the store read that file instead of shelling out, and
/// `--dump` writes the live snapshot in that format. Both halves are needed together.
///
/// WHY. The bead asked for the pane to be verified by
/// capturing `--once` before and after and diffing. The first attempt did exactly that and
/// the diff was worthless: between the two captures a bead got answered, DECISIONS went
/// from 3 to 1, and every row moved for a reason that had nothing to do with the render.
/// A render regression test against a live database is not a test, it is a coin toss —
/// and the pane is now the surface every escalation is read in, so it needs one.
pub fn fixture() -> Option<String> {
    std::env::var("PANEL_FIXTURE").ok().filter(|s| !s.is_empty())
}

/// The snapshot in the shape `PANEL_FIXTURE` reads back.
pub fn dump(s: &Snapshot) -> String {
    serde_json::to_string_pretty(&serde_json::json!({
        "beads": s.beads.clone().unwrap_or_default(),
        "threads": s.threads.clone(),
        "mail": s.mail.clone().unwrap_or_default(),
    }))
    .unwrap_or_else(|e| format!("{{\"error\":\"{e}\"}}"))
}

/// Load a fixture into the snapshot. Synchronous and total: a fixture that will not parse is
/// an error on the pane rather than a silent fall back to the live database, which would
/// make a test quietly measure the wrong thing.
fn load_fixture(shared: &Shared, path: &str) {
    let mut s = shared.lock().unwrap();
    s.refreshing = false;
    match std::fs::read_to_string(path)
        .map_err(|e| format!("{path}: {e}"))
        .and_then(|t| serde_json::from_str::<Value>(&t).map_err(|e| format!("{path}: {e}")))
    {
        Err(e) => {
            s.beads_err = Some(e.clone());
            s.mail_err = Some(e);
        }
        Ok(v) => {
            s.beads = Some(v["beads"].as_array().cloned().unwrap_or_default());
            s.mail = Some(v["mail"].as_array().cloned().unwrap_or_default());
            s.threads = v["threads"]
                .as_object()
                .map(|m| {
                    m.iter()
                        .map(|(k, v)| (k.clone(), v.as_array().cloned().unwrap_or_default()))
                        .collect()
                })
                .unwrap_or_default();
            s.beads_err = None;
            s.mail_err = None;
        }
    }
    // A FIXED age, not `Instant::now()`. The header prints how stale the snapshot is, so a
    // live clock would put "live" / "<1m" / "3m" into a frame that is supposed to be
    // byte-identical across runs — the one thing a render diff cannot tolerate.
    s.at = Some(Instant::now() - Duration::from_secs(90));
    s.gen = s.gen.wrapping_add(1);
}

/// Refresh in the background. Never blocks the caller, and never runs two at once — a
/// second refresh while one is in flight would double the subprocess load for nothing.
pub fn refresh(shared: &Shared) {
    if let Some(path) = fixture() {
        load_fixture(shared, &path);
        return;
    }
    {
        let mut s = shared.lock().unwrap();
        if s.refreshing {
            return;
        }
        s.refreshing = true;
    }
    let shared = Arc::clone(shared);
    thread::spawn(move || {
        // Concurrently: a refresh costs max(bd, mail), not their sum.
        let h = thread::spawn(fetch_mail);
        let b = fetch_beads();
        let m = h.join().unwrap_or_else(|_| Err("mail thread panicked".into()));
        // Only for beads that actually have comments — `comment_count` is already in the
        // list payload, so this is usually two or three extra calls, not one per bead.
        let threads = match &b {
            Ok(v) => fetch_threads(v),
            Err(_) => Default::default(),
        };
        let mut s = shared.lock().unwrap();
        match b {
            Ok(v) => {
                s.beads = Some(v);
                s.beads_err = None;
                s.threads = threads;
            }
            Err(e) => s.beads_err = Some(e),
        }
        match m {
            Ok(v) => {
                s.mail = Some(v);
                s.mail_err = None;
            }
            Err(e) => s.mail_err = Some(e),
        }
        s.at = Some(Instant::now());
        s.gen = s.gen.wrapping_add(1);
        s.refreshing = false;
    });
}

pub fn spawn_refresher(shared: Shared, every: Duration) {
    thread::spawn(move || loop {
        refresh(&shared);
        thread::sleep(every);
    });
}

fn labels(r: &Value) -> Vec<&str> {
    r["labels"]
        .as_array()
        .map(|a| a.iter().filter_map(|x| x.as_str()).collect())
        .unwrap_or_default()
}

/// The recommended default, lifted from the description. An ask without one makes the operator
/// decide from scratch, so when it exists it belongs on screen.
fn lead(desc: &str) -> String {
    desc.lines()
        .find(|l| l.contains("Default"))
        .map(|l| {
            l.split_once(':')
                .map(|(_, v)| v)
                .unwrap_or(l)
                .replace("**", "")
                .trim()
                .to_string()
        })
        .unwrap_or_default()
}

/// An insight's body, with the escalation template's call to action taken off it.
///
/// (the operator, verbatim: *"these insights seem more like bug reports which means they're
/// implicitly asking me for feedback -- really they should be FYI only."*) They are describing
/// the text, not an impression of it. `ask.sh compose` wrote ONE body for all three kinds, so
/// every insight on this box opens with `**What is blocked:**` -- nothing is blocked, it is a
/// record -- and ends by instructing them to file a verdict:
///
/// ```text
/// _Filed by the brain session. Answer inline in the cockpit pane, or:_
/// `.claude/cockpit/ask.sh answered <id> "<verdict>"`
/// ```
///
/// That trailer is a bug report's clothing sewn on by the generator, and it is why the view
/// reads as one. `ask.sh` no longer writes it onto an insight; this strips it from the ones
/// already in the database, which cannot be rewritten -- Spira's aeons may not write to the
/// Gas Town beads databases, and editing a stored record to fix its presentation would be the
/// wrong repair anyway.
///
/// Only two things go: the trailer, and the false section LABEL. The prose itself is
/// untouched -- the reader names the section in chrome (`-- why it matters --`) rather than
/// substituting a different claim about what the author wrote.
fn fyi_body(desc: &str) -> String {
    let mut lines: Vec<&str> = desc.lines().collect();
    // The trailer, and everything after it: it is always last, and it is the only part of the
    // body that tells them to do something.
    // BOTH trailers. `ask.sh` now signs an insight "_Recorded by the brain session. Nothing is
    // owed_" — true, and worth having in the stored record, on the phone and in `bd show`. In
    // the pane it is two rows of boilerplate repeated on every item, saying what the footer
    // already says with a live key hint; the pane earns its rows.
    if let Some(i) = lines.iter().position(|l| {
        let t = l.trim_start();
        t.starts_with("_Filed by the brain session") || t.starts_with("_Recorded by the brain session")
    }) {
        lines.truncate(i);
    }
    while lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
        lines.pop();
    }
    let mut out: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
    // The label on the leading paragraph. "What is blocked" is the escalation template's and
    // is false here; "Why it matters" is the insight's own and is what the chrome now says.
    if let Some(first) = out.iter_mut().find(|l| !l.trim().is_empty()) {
        for label in ["**What is blocked:**", "**Why it matters:**"] {
            if let Some(rest) = first.trim_start().strip_prefix(label) {
                *first = rest.trim_start().to_string();
                break;
            }
        }
    }
    while out.first().map(|l| l.trim().is_empty()).unwrap_or(false) {
        out.remove(0);
    }
    out.join("\n")
}

/// A comment thread in reading order: oldest first, enforced rather than assumed.
///
/// The order is load-bearing twice over. The pane now renders the thread ABOVE the ask, so
/// it is the first thing read; and the list's turn marker asks `thread.last()` whose ball it
/// is — `↩` for me, `●` for the operator — which inverts outright if the newest comment is at the
/// front. `bd comments` returns oldest-first today (checked against a real thread,
/// three comments, ascending), but a display whose meaning flips with someone else's
/// `ORDER BY` should not rest on that.
///
/// Only sorted when every comment carries a full stamp: an empty one sorts before all the
/// others and would silently hoist an unstamped comment to the top of the conversation.
/// ISO-8601 UTC compares lexicographically, and the sort is stable, so equal stamps keep
/// the order the database returned them in.
fn oldest_first(mut t: Vec<(String, String, String)>) -> Vec<(String, String, String)> {
    if t.iter().all(|(_, when, _)| when.len() >= 16) {
        t.sort_by(|a, b| a.1.cmp(&b.1));
    }
    t
}

/// Filter the cached rows down to one view. Pure, in memory, instant.
///
/// `dismissed` only means anything in the FYI view, where it swaps the live insights for the
/// ones already read. It is a parameter rather than a second function because the list, the
/// tab count and the destructive key must all agree about which set is on screen: the tab
/// said 0 while the list showed twelve is exactly the reassuring-lie shape `present_ids`
/// exists to prevent, one layer up.
pub fn view_items(s: &Snapshot, view: View, dismissed: bool) -> Result<Vec<Item>, String> {
    match view {
        View::Notifications => match (&s.mail, &s.mail_err) {
            (_, Some(e)) => Err(e.clone()),
            (None, _) => Err("loading…".into()),
            (Some(rows), _) => Ok(rows
                .iter()
                .map(|m| Item {
                    id: m["id"].as_str().unwrap_or("?").to_string(),
                    title: m["subject"].as_str().unwrap_or("(no subject)").to_string(),
                    lead: String::new(),
                    body: m["body"].as_str().unwrap_or("").to_string(),
                    badge: m["from"].as_str().unwrap_or("?").to_string(),
                    when: m["timestamp"].as_str().unwrap_or("").to_string(),
                    thread: Vec::new(),
                })
                .collect()),
        },
        _ => match (&s.beads, &s.beads_err) {
            (_, Some(e)) => Err(e.clone()),
            (None, _) => Err("loading…".into()),
            (Some(all), _) => {
                let ask = ask_label();
                let want_insight = view == View::Insights;
                let mut out: Vec<Item> = all
                    .iter()
                    .filter(|r| {
                        let l = labels(r);
                        let is_insight = l.contains(&"insight");
                        if want_insight {
                            // Insights are a town-side record, created closed. `archived` is
                            // the dismissal: an insight the operator has read leaves the pane, and
                            // `h` is what brings the read ones back. Same label `ask.sh list
                            // insights` filters on, so the two paths cannot disagree.
                            if !(l.contains(&"overseer") && is_insight) {
                                return false;
                            }
                            let arch = l.contains(&crate::model::ARCHIVED);
                            if dismissed {
                                return arch;
                            }
                            // ARCHIVING ENDS A NOTICE, NOT A CONVERSATION. Dismissal is how a
                            // read FYI leaves the pane, which is right for a notice nobody
                            // replied to. But an insight the operator has COMMENTED on is a thread they
                            // is owed an answer in, and archiving it hid my replies from the
                            // only surface they read them in — they asked where the
                            // acknowledgement was, and it was behind this filter.
                            // Bounded by construction: only insights that already report a
                            // comment, a handful on this box.
                            return !arch || r["comment_count"].as_u64().unwrap_or(0) > 0;
                        }
                        if is_insight {
                            return false;
                        }
                        // DECISIONS is "what is waiting on the operator", and the label that
                        // means exactly that is the configured escalation label -- the same
                        // one the escalation gate defers on and every predicate excludes. An
                        // escalation raised by a worker carries only that label, never
                        // `overseer`, so requiring `overseer` hid every one of them.
                        let waiting = l.contains(&ask.as_str()) || l.contains(&"overseer");
                        if !waiting {
                            return false;
                        }
                        // An EPIC is a container for a branch of work, not a question, so it
                        // can never be a decision however it is labelled. Two reached the operator
                        // once reached the operator carrying the escalation label from a
                        // deferred-sweep triage, with nothing in them but two lines of branch
                        // metadata, and the answer to "what is the decision?" was: none.
                        // Structural exclusion, not a guess about content.
                        if r["issue_type"].as_str() == Some("epic") {
                            return false;
                        }
                        // And NOT `status == open`: an escalated bead is legitimately parked
                        // in `deferred` -- that is the one status the policy allows it to sit
                        // in, and filtering on `open` once hid every bead that was in it.
                        // Anything not closed is still awaiting an answer.
                        r["status"].as_str() != Some("closed")
                    })
                    .map(|r| {
                        let l = labels(r);
                        let badge = if l.contains(&"insight") {
                            "insight"
                        } else if l.contains(&"ask-decision") {
                            "decision"
                        } else if l.contains(&"ask-task") {
                            "task"
                        } else {
                            "question"
                        };
                        let desc = r["description"].as_str().unwrap_or("");
                        // AN INSIGHT HAS NO DEFAULT AND NO CALL TO ACTION. A `default:` line
                        // is a recommendation awaiting agreement, which is precisely the
                        // "implicitly asking me for feedback" shape; `lead` matches any line
                        // containing the word, so suppressing it here is what guarantees one
                        // can never appear on an FYI rather than merely usually not appearing.
                        let insight = badge == "insight";
                        Item {
                            id: r["id"].as_str().unwrap_or("?").to_string(),
                            title: r["title"].as_str().unwrap_or("").to_string(),
                            lead: if insight { String::new() } else { lead(desc) },
                            body: if insight { fyi_body(desc) } else { desc.to_string() },
                            badge: badge.to_string(),
                            when: r["created_at"].as_str().unwrap_or("").to_string(),
                            thread: oldest_first(
                                s.threads
                                    .get(r["id"].as_str().unwrap_or(""))
                                    .map(|cs| {
                                        cs.iter()
                                            .map(|c| {
                                                (
                                                    c["author"].as_str().unwrap_or("?").to_string(),
                                                    c["created_at"]
                                                        .as_str()
                                                        .or_else(|| c["timestamp"].as_str())
                                                        .unwrap_or("")
                                                        .to_string(),
                                                    c["text"].as_str().unwrap_or("").to_string(),
                                                )
                                            })
                                            .collect()
                                    })
                                    .unwrap_or_default(),
                            ),
                        }
                    })
                    .collect();
                out.reverse();
                Ok(out)
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The exact body `ask.sh` wrote for every insight before this change, verbatim from
    /// the long insight in `tests/fixture.json`. An insight that opens "what is blocked" and closes by
    /// asking for a verdict IS a bug report, whatever the label says, which is what the operator was
    /// reading. The prose in between is the author's and is left alone.
    #[test]
    fn an_insight_loses_the_escalation_templates_call_to_action() {
        let got = fyi_body(concat!(
            "**What is blocked:** The sentinel rebases branches onto master mechanically.\n",
            "\n",
            "The PR head a required check tests is a merge of the two.\n",
            "\n",
            "_Filed by the brain session. Answer inline in the cockpit pane, or:_\n",
            "`.claude/cockpit/ask.sh answered <id> \"<verdict>\"`",
        ));
        assert_eq!(
            got,
            "The sentinel rebases branches onto master mechanically.\n\nThe PR head a required check tests is a merge of the two."
        );
    }

    /// The trailer `ask.sh` writes now is true and belongs in the stored record — and it is
    /// still boilerplate the pane will not spend two of nineteen rows repeating.
    #[test]
    fn the_recorded_trailer_goes_too() {
        let got = fyi_body(concat!(
            "**Why it matters:** a box over the disk threshold with a dead alert channel reads green.\n",
            "\n",
            "_Recorded by the brain session. Nothing is owed — this is a record, not a_\n",
            "_request. Press `d` in the cockpit pane to dismiss it; `h` brings it back._",
        ));
        assert_eq!(
            got,
            "a box over the disk threshold with a dead alert channel reads green."
        );
    }

    /// Evidence is not boilerplate: it is the finding. It sits above the trailer and stays.
    #[test]
    fn the_evidence_block_survives() {
        let got = fyi_body(concat!(
            "**Why it matters:** 37 pipelines are exposed.\n",
            "\n",
            "**Evidence**\n```\ngit log | grep -q foo\n```\n",
            "\n",
            "_Recorded by the brain session. Nothing is owed._",
        ));
        assert!(got.contains("**Evidence**"), "{got:?}");
        assert!(got.contains("grep -q foo"), "{got:?}");
        assert!(!got.contains("Recorded by"), "{got:?}");
    }

    /// A body with neither label nor trailer is returned untouched — most insights written
    /// from now on by anything other than `ask.sh` will look like this.
    #[test]
    fn a_plain_body_is_left_alone() {
        let b = "one line.\n\nand another.";
        assert_eq!(fyi_body(b), b);
    }

    fn c(author: &str, when: &str) -> (String, String, String) {
        (author.into(), when.into(), format!("{author}@{when}"))
    }

    /// The pane leads with the thread and the list's turn marker reads its last entry, so a
    /// thread arriving newest-first would both read backwards and put the wrong arrow on the
    /// row. Enforced here rather than trusted to `bd comments`.
    #[test]
    fn a_thread_is_ordered_oldest_first() {
        let got = oldest_first(vec![
            c("claude", "2026-09-05T16:00:00Z"),
            c("operator", "2026-09-05T15:00:00Z"),
            c("operator", "2026-09-04T09:00:00Z"),
        ]);
        let whens: Vec<&str> = got.iter().map(|(_, w, _)| w.as_str()).collect();
        assert_eq!(
            whens,
            ["2026-09-04T09:00:00Z", "2026-09-05T15:00:00Z", "2026-09-05T16:00:00Z"]
        );
    }

    /// An unstamped comment sorts before every stamped one, which would hoist it to the top
    /// of the conversation. Better to keep the order the database gave us than to invent one.
    #[test]
    fn an_unstamped_comment_leaves_the_order_alone() {
        let got = oldest_first(vec![
            c("claude", "2026-09-05T16:00:00Z"),
            c("operator", ""),
            c("operator", "2026-09-05T15:00:00Z"),
        ]);
        let whens: Vec<&str> = got.iter().map(|(_, w, _)| w.as_str()).collect();
        assert_eq!(whens, ["2026-09-05T16:00:00Z", "", "2026-09-05T15:00:00Z"]);
    }

    /// Equal stamps keep the order they arrived in — two comments in the same second are
    /// common enough, and a reshuffle there is a conversation reordered for no reason.
    #[test]
    fn equal_stamps_keep_their_arrival_order() {
        let got = oldest_first(vec![
            c("operator", "2026-09-05T15:00:00Z"),
            c("claude", "2026-09-05T15:00:00Z"),
        ]);
        let who: Vec<&str> = got.iter().map(|(a, _, _)| a.as_str()).collect();
        assert_eq!(who, ["operator", "claude"]);
    }
}
