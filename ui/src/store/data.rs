//! The catalog as the script reports it (TSV contract, Revision 5, plus `Readme-skip`):
//! `snapshot --tsv` (which carries the `list --tsv`, `info --tsv` and `update --check --tsv
//! --offline` shapes, one line type each, plus the assets already cached), `update --check
//! --tsv`, and the progress stream.

use std::collections::HashMap;
use std::path::PathBuf;

/// One visible item, from `tlstore list --tsv`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    /// Catalog order, 1-based (the "NN").
    pub no: usize,
    pub name: String,
    pub version: String,
    /// Installed version, when installed.
    pub installed: Option<String>,
    pub kind: String,
    pub summary: String,
    pub category: String,
    pub featured: bool,
}

/// One update, from `tlstore update --check --tsv`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Update {
    pub name: String,
    pub have: String,
    pub new: String,
    pub note: String,
}

/// A row's status word on Front.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    /// The featured item, not installed yet.
    New,
    /// Installed, with a newer version waiting.
    Update(String),
    Installed,
    None,
}

impl Status {
    pub fn label(&self) -> String {
        match self {
            Status::New => "new".into(),
            Status::Update(v) => format!("↑ {v}"),
            Status::Installed => "installed".into(),
            Status::None => String::new(),
        }
    }
    /// New and update statuses are drawn in the accent.
    pub fn hot(&self) -> bool {
        matches!(self, Status::New | Status::Update(_))
    }
}

/// One `list --tsv` row (its fields, `name` first) as an item numbered `no`.
fn item_from(f: &[&str], no: usize) -> Item {
    let get = |k: usize| f.get(k).copied().unwrap_or("").to_string();
    let dash = |s: String| if s == "-" { String::new() } else { s };
    Item {
        no,
        name: get(0),
        installed: (get(1) == "installed").then(|| get(3)),
        version: dash(get(2)),
        kind: get(4),
        summary: dash(get(5)),
        category: dash(get(6)),
        featured: get(7) == "1",
    }
}

pub fn parse_list(tsv: &str) -> Vec<Item> {
    tsv.lines()
        .filter(|l| !l.trim().is_empty())
        .enumerate()
        .map(|(i, l)| {
            let f: Vec<&str> = l.split('\t').collect();
            item_from(&f, i + 1)
        })
        .filter(|it| !it.name.is_empty())
        .collect()
}

pub fn parse_updates(tsv: &str) -> Vec<Update> {
    tsv.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f.len() >= 3 && !f[0].is_empty()).then(|| Update {
                name: f[0].to_string(),
                have: f[1].to_string(),
                new: f[2].to_string(),
                note: f.get(3).copied().unwrap_or("").to_string(),
            })
        })
        .collect()
}

/// `tlstore info --tsv <name>`: key/value lines.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Info {
    fields: Vec<(String, String)>,
}

impl Info {
    pub fn parse(tsv: &str) -> Info {
        Info {
            fields: tsv
                .lines()
                .filter_map(|l| l.split_once('\t'))
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }
    fn push(&mut self, key: &str, value: &str) {
        self.fields.push((key.to_string(), value.to_string()));
    }
    /// True when the script printed this key at all (even as `-`).
    pub fn has(&self, key: &str) -> bool {
        self.fields.iter().any(|(k, _)| k == key)
    }
    /// The value for `key`, None when missing, empty or `-`.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.fields
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
            .filter(|v| !v.is_empty() && *v != "-")
    }
    pub fn setup(&self) -> bool {
        self.get("Setup") == Some("1")
    }
    /// `owner/repo`, never for a setup.
    pub fn upstream(&self) -> Option<&str> {
        if self.setup() {
            None
        } else {
            self.get("Upstream").filter(|u| u.contains('/'))
        }
    }
    /// The one-line standfirst (the summary when the catalog has none).
    pub fn standfirst(&self) -> &str {
        self.get("Standfirst").or(self.get("Summary")).unwrap_or("")
    }
    /// The line the item's page shows before install when the Termux packages it pulls in are
    /// large (`Packages`, Revision 15): "Also installs …: about N MB to download, M MB on disk
    /// (…)". The script sends it only above its threshold, so its presence is the signal.
    pub fn packages(&self) -> Option<&str> {
        self.get("Packages")
    }
    /// The two figures in that line (`Packages-size`, `<download MB>,<disk MB>`).
    pub fn packages_size(&self) -> Option<(u32, u32)> {
        let (dl, disk) = self.get("Packages-size")?.split_once(',')?;
        Some((dl.trim().parse().ok()?, disk.trim().parse().ok()?))
    }
    /// README section titles the catalog asks to leave out (`Readme-skip`, `|`-separated).
    pub fn readme_skip(&self) -> Vec<String> {
        self.get("Readme-skip")
            .map(|n| n.split('|').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect())
            .unwrap_or_default()
    }
}

/// What kind of asset a snapshot `cached` line or a prefetch line names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssetKind {
    Picture,
    Demo,
    Readme,
    /// A picture the README refers to (its first image, for the header).
    Asset,
}

impl AssetKind {
    pub fn parse(word: &str) -> Option<AssetKind> {
        Some(match word {
            "picture" => AssetKind::Picture,
            "demo" => AssetKind::Demo,
            "readme" => AssetKind::Readme,
            "asset" => AssetKind::Asset,
            _ => return None,
        })
    }
}

/// What the last check of one signed channel (the item list, or tlstore itself) found:
/// `newer`, `current`, `offline`, `cannot-verify` or `refused`, and why (empty for none).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Channel {
    pub outcome: String,
    pub reason: String,
}

impl Channel {
    /// The engine's words as they come; a `-` reason is none.
    pub fn new(outcome: &str, reason: &str) -> Channel {
        let reason = reason.trim();
        Channel {
            outcome: outcome.trim().to_string(),
            reason: if reason == "-" { String::new() } else { reason.to_string() },
        }
    }

    /// The check could not be trusted: nothing to verify with, or what was offered was
    /// refused. Offline is normal on a phone and does not count.
    pub fn failed(&self) -> bool {
        matches!(self.outcome.as_str(), "cannot-verify" | "refused")
    }
}

/// Both channels, as the snapshot's `channel` lines (and the self-check) report them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Channels {
    pub catalog: Option<Channel>,
    /// tlstore itself (`self` in the engine's words).
    pub tlstore: Option<Channel>,
}

impl Channels {
    /// Why updates could not be checked, when either channel failed: the item list's
    /// reason first, then tlstore's. None while both are fine or merely offline.
    pub fn problem(&self) -> Option<String> {
        [&self.catalog, &self.tlstore].into_iter().flatten().find(|c| c.failed()).map(|c| {
            if c.reason.is_empty() {
                "what was offered could not be verified".to_string()
            } else {
                c.reason.clone()
            }
        })
    }
}

/// Everything `tlstore snapshot --tsv` says, parsed: the list, every item's info, the
/// offline updates, the assets whose verified copy is already on disk, and what the last
/// check of each signed channel found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub items: Vec<Item>,
    pub infos: HashMap<String, Info>,
    pub updates: Vec<Update>,
    /// `(name, kind, path)`; only pictures, demos and readmes appear here.
    pub cached: Vec<(String, AssetKind, PathBuf)>,
    pub channels: Channels,
}

impl Snapshot {
    /// Reads the line-typed stream. Comment lines (`#`) and unknown types are skipped; an
    /// `item` line is the `list --tsv` row after the type word, a `field` line one
    /// `info --tsv` row for its item, an `update` line one `update --check --tsv` row, a
    /// `channel` line `catalog|self`, its outcome and its reason.
    pub fn parse(text: &str) -> Snapshot {
        let mut s = Snapshot::default();
        for line in text.lines() {
            if line.starts_with('#') || line.trim().is_empty() {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            match f[0] {
                "item" if f.len() >= 2 && !f[1].is_empty() => {
                    let no = s.items.len() + 1;
                    s.items.push(item_from(&f[1..], no));
                }
                "field" if f.len() >= 4 => {
                    s.infos.entry(f[1].to_string()).or_default().push(f[2], f[3]);
                }
                "update" if f.len() >= 4 && !f[1].is_empty() => s.updates.push(Update {
                    name: f[1].to_string(),
                    have: f[2].to_string(),
                    new: f[3].to_string(),
                    note: f.get(4).copied().unwrap_or("").to_string(),
                }),
                "cached" if f.len() >= 4 => {
                    if let Some(kind) = AssetKind::parse(f[2]).filter(|k| *k != AssetKind::Asset) {
                        s.cached.push((f[1].to_string(), kind, PathBuf::from(f[3])));
                    }
                }
                "channel" if f.len() >= 3 => {
                    let c = Channel::new(f[2], f.get(3).copied().unwrap_or(""));
                    match f[1] {
                        "catalog" => s.channels.catalog = Some(c),
                        "self" => s.channels.tlstore = Some(c),
                        _ => {}
                    }
                }
                _ => {}
            }
        }
        s
    }
}

static NO_INFO: Info = Info { fields: Vec::new() };

/// Everything the screens read, as the last snapshot said it.
#[derive(Default)]
pub struct Catalog {
    pub items: Vec<Item>,
    pub updates: Vec<Update>,
    infos: HashMap<String, Info>,
    /// Set when the last load failed (no catalog yet, script missing).
    pub error: Option<String>,
    /// True until the first snapshot has arrived (or failed).
    pub loading: bool,
}

impl Catalog {
    /// An empty catalog waiting for its first snapshot.
    pub fn loading() -> Catalog {
        Catalog { loading: true, ..Catalog::default() }
    }

    /// Takes a snapshot's list, info and updates.
    pub fn apply(&mut self, s: Snapshot) {
        self.items = s.items;
        self.infos = s.infos;
        self.updates = s.updates;
        self.error = None;
        self.loading = false;
    }

    /// A job reported `name` done: the list says so at once (installed at the catalog's
    /// version, or not at all; either way no update is left for it) until the snapshot that
    /// follows the job tells the truth.
    pub fn mark(&mut self, name: &str, installed: bool) {
        if let Some(it) = self.items.iter_mut().find(|i| i.name == name) {
            it.installed = installed.then(|| it.version.clone());
        }
        self.updates.retain(|u| u.name != name);
    }

    /// The snapshot could not be read at all.
    pub fn fail(&mut self) {
        self.items.clear();
        self.infos.clear();
        self.error = Some("The list could not be read. Check your connection and try again.".into());
        self.loading = false;
    }

    pub fn item(&self, name: &str) -> Option<&Item> {
        self.items.iter().find(|i| i.name == name)
    }

    pub fn update_for(&self, name: &str) -> Option<&Update> {
        self.updates.iter().find(|u| u.name == name)
    }

    pub fn status(&self, it: &Item) -> Status {
        if let Some(u) = self.update_for(&it.name) {
            return Status::Update(u.new.clone());
        }
        match (&it.installed, it.featured) {
            (Some(_), _) => Status::Installed,
            (None, true) => Status::New,
            (None, false) => Status::None,
        }
    }

    /// The item's `info --tsv` rows as the snapshot carried them; empty for an unknown name.
    pub fn info(&self, name: &str) -> &Info {
        self.infos.get(name).unwrap_or(&NO_INFO)
    }
}

/// What `tlstore self-update --check --tsv` said: the version in place, the newest one
/// offered (`-` when none could be read), whether the update can be had, and (from an
/// engine that says it) what the check of the channel found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelfCheck {
    pub have: String,
    pub new: String,
    pub available: bool,
    /// Fields 5 and 6, outcome and reason; None from an older engine's four fields.
    pub channel: Option<Channel>,
}

/// Parses the one line `self\t<installed>\t<latest>\t<available 0|1>[\t<outcome>\t<reason>]`.
pub fn parse_self_check(text: &str) -> Option<SelfCheck> {
    text.lines().find_map(|l| {
        let f: Vec<&str> = l.split('\t').collect();
        (f.len() >= 4 && f[0] == "self").then(|| SelfCheck {
            have: f[1].to_string(),
            new: f[2].to_string(),
            available: f[3].trim() == "1",
            channel: f
                .get(4)
                .filter(|o| !o.trim().is_empty())
                .map(|o| Channel::new(o, f.get(5).copied().unwrap_or(""))),
        })
    })
}

/// The four step words every item goes through, in order.
pub const STEPS: [&str; 4] = ["fetched", "signature checked", "putting files in place", "ready"];

/// The word a Front row shows while its step is in progress (`step` indexes [`STEPS`];
/// 4 = all done).
pub fn step_word(step: usize) -> &'static str {
    match step {
        0 => "fetching…",
        1 => "checking…",
        2 => "placing…",
        _ => "ready",
    }
}

/// One line of the `--progress` stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Progress {
    /// One row of the plan, announced before any step (Revision 17): `row name action kind
    /// version by why`; an empty field is `-`.
    Row { name: String, action: String, kind: String, version: String, by: String, why: String },
    Step { name: String, pct: u8, words: String },
    Done { name: String, ok: bool, message: String },
    /// A job-level error (`error<TAB>text`): not scoped to one row, at any point of the stream.
    Error { text: String },
}

pub fn parse_progress(line: &str) -> Option<Progress> {
    let f: Vec<&str> = line.split('\t').collect();
    match *f.first()? {
        "row" if f.len() >= 2 && !f[1].is_empty() => {
            let at = |i: usize| {
                f.get(i).map(|s| s.trim_end()).filter(|s| !s.is_empty()).unwrap_or("-").to_string()
            };
            Some(Progress::Row {
                name: f[1].to_string(),
                action: at(2),
                kind: at(3),
                version: at(4),
                by: at(5),
                why: at(6),
            })
        }
        "step" if f.len() >= 3 => Some(Progress::Step {
            name: f[1].to_string(),
            pct: f[2].trim().parse::<u32>().ok()?.min(100) as u8,
            words: f.get(3).copied().unwrap_or("").to_string(),
        }),
        "done" if f.len() >= 3 => Some(Progress::Done {
            name: f[1].to_string(),
            ok: f[2] == "ok",
            message: f.get(3).copied().unwrap_or("").to_string(),
        }),
        "error" if f.len() >= 2 && !f[1].trim().is_empty() => {
            Some(Progress::Error { text: f[1].trim_end().to_string() })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_rows_parse() {
        let tsv = "dawn\tavailable\t0.1.3\t\tbinary\ta quiet place\tNote taking\t1\n\
                   kitten\tinstalled\t0.49\t0.48.2\tbinary\tpictures\tTools\t0\n";
        let v = parse_list(tsv);
        assert_eq!(v.len(), 2);
        assert_eq!(v[0].no, 1);
        assert!(v[0].featured && v[0].installed.is_none());
        assert_eq!(v[1].installed.as_deref(), Some("0.48.2"));
        assert_eq!(v[1].category, "Tools");
    }

    #[test]
    fn info_and_updates_parse() {
        let i = Info::parse(
            "Kind\tbinary\nUpstream\tkovidgoyal/kitty\nSetup\t0\nSummary\tsum\nReadme-skip\tPortability | Faq\n",
        );
        assert_eq!(i.upstream(), Some("kovidgoyal/kitty"));
        assert_eq!(i.readme_skip(), vec!["Portability", "Faq"]);
        assert_eq!(i.standfirst(), "sum");
        assert!(Info::parse("Setup\t1\nUpstream\tfish/fish\n").upstream().is_none());
        assert!(Info::parse("Readme-skip\t-\n").readme_skip().is_empty());
        let u = parse_updates("kitten\t0.48.2\t0.49\t\nclaude-code\t1.0\tlatest\tlatest\n");
        assert_eq!(u[1].new, "latest");
    }

    #[test]
    fn packages_line_and_its_figures() {
        let i = Info::parse("Packages\tAlso installs Termux's Electron: about 153 MB\nPackages-size\t153,862\n");
        assert_eq!(i.packages(), Some("Also installs Termux's Electron: about 153 MB"));
        assert_eq!(i.packages_size(), Some((153, 862)));
        let none = Info::parse("Kind\tbinary\n");
        assert!(none.packages().is_none() && none.packages_size().is_none());
        assert!(Info::parse("Packages-size\t153\n").packages_size().is_none());
    }

    #[test]
    fn snapshot_parses_every_line_type() {
        let text = "# tlstore snapshot\tkey=abc\n\
                    item\tdawn\tavailable\t0.1.3\t\tbinary\ta quiet place\tNote taking\t1\n\
                    field\tdawn\tKind\tbinary\n\
                    field\tdawn\tUpstream\tandrewmd5/dawn\n\
                    field\tdawn\tSetup\t0\n\
                    field\tdawn\tReadme-skip\tPortability\n\
                    item\tkitten\tinstalled\t0.49\t0.48.2\tbinary\tpictures\tTools\t0\n\
                    field\tkitten\tSetup\t0\n\
                    update\tkitten\t0.48.2\t0.49\t\n\
                    cached\tdawn\tpicture\t/c/pictures/aa.jpg\n\
                    cached\tdawn\tasset\t/c/x.png\n\
                    cached\tkitten\treadme\t/c/readme/kitten-0.49.md\n\
                    something\telse\n";
        let s = Snapshot::parse(text);
        assert_eq!(s.items.len(), 2);
        assert_eq!((s.items[0].no, s.items[1].no), (1, 2));
        assert!(s.items[0].featured && s.items[0].installed.is_none());
        assert_eq!(s.items[1].installed.as_deref(), Some("0.48.2"));
        assert_eq!(s.infos["dawn"].upstream(), Some("andrewmd5/dawn"));
        assert_eq!(s.infos["dawn"].readme_skip(), vec!["Portability"]);
        assert!(s.infos["kitten"].upstream().is_none());
        assert_eq!(s.updates.len(), 1);
        assert_eq!(s.updates[0].new, "0.49");
        assert_eq!(
            s.cached,
            vec![
                ("dawn".to_string(), AssetKind::Picture, PathBuf::from("/c/pictures/aa.jpg")),
                ("kitten".to_string(), AssetKind::Readme, PathBuf::from("/c/readme/kitten-0.49.md")),
            ],
            "a README's picture is never in a snapshot"
        );
        let mut c = Catalog::loading();
        assert!(c.loading);
        c.apply(s);
        assert!(!c.loading && c.error.is_none());
        assert_eq!(c.info("dawn").standfirst(), "");
        assert!(c.info("dawn").has("Upstream") && !c.info("nobody").has("Kind"));
        assert_eq!(c.status(&c.items[1].clone()), Status::Update("0.49".into()));
        c.fail();
        assert!(c.items.is_empty() && c.error.is_some());
    }

    #[test]
    fn progress_lines_parse() {
        assert_eq!(
            parse_progress("step\tkitten\t60\tsignature checked"),
            Some(Progress::Step { name: "kitten".into(), pct: 60, words: "signature checked".into() })
        );
        assert_eq!(
            parse_progress("done\tkitten\tok\tkept your config.fish"),
            Some(Progress::Done { name: "kitten".into(), ok: true, message: "kept your config.fish".into() })
        );
        assert_eq!(parse_progress("Installing: kitten"), None);
        assert_eq!(
            parse_progress("error\tcould not install what is needed to build: patchelf"),
            Some(Progress::Error { text: "could not install what is needed to build: patchelf".into() })
        );
        assert_eq!(parse_progress("error"), None, "an error needs its sentence");
        assert_eq!(parse_progress("error\t"), None);
        let row = |name: &str, action: &str, kind: &str, version: &str, by: &str, why: &str| Progress::Row {
            name: name.into(),
            action: action.into(),
            kind: kind.into(),
            version: version.into(),
            by: by.into(),
            why: why.into(),
        };
        assert_eq!(
            parse_progress("row\tmusl-loader\tinstall\tbinary\t1.2.5\tauto\tneeded by dawn"),
            Some(row("musl-loader", "install", "binary", "1.2.5", "auto", "needed by dawn"))
        );
        assert_eq!(
            parse_progress("row\tdawn\tinstall\tbinary\t0.1.3\trequested\t-"),
            Some(row("dawn", "install", "binary", "0.1.3", "requested", "-"))
        );
        assert_eq!(parse_progress("row\tdawn"), Some(row("dawn", "-", "-", "-", "-", "-")), "short: dashes");
        assert_eq!(parse_progress("row\t\tinstall"), None, "a row needs a name");
        assert_eq!(
            parse_self_check("self\t0.6\t0.7\t1\n"),
            Some(SelfCheck { have: "0.6".into(), new: "0.7".into(), available: true, channel: None })
        );
        let refused = "tlstore: the tlstore that was offered is not signed\nself\t0.6\t-\t0";
        assert_eq!(
            parse_self_check(refused),
            Some(SelfCheck { have: "0.6".into(), new: "-".into(), available: false, channel: None })
        );
        assert_eq!(parse_self_check("self\t0.6\n"), None);
        assert_eq!(parse_self_check(""), None);
        assert_eq!(step_word(0), "fetching…");
        assert_eq!(step_word(2), "placing…");
        assert_eq!(step_word(4), "ready");
    }

    #[test]
    fn snapshot_reads_channel_lines() {
        let text = "# tlstore snapshot\tkey=abc\n\
                    item\tdawn\tavailable\t0.1.3\t\tbinary\ta quiet place\tNote taking\t1\n\
                    channel\tcatalog\tcannot-verify\tminisign is not installed (pkg install minisign)\n\
                    channel\tself\tcurrent\t-\n\
                    channel\tsomething\trefused\tnot a channel\n";
        let s = Snapshot::parse(text);
        assert_eq!(s.items.len(), 1, "a channel line is not an item");
        assert_eq!(
            s.channels.catalog,
            Some(Channel {
                outcome: "cannot-verify".into(),
                reason: "minisign is not installed (pkg install minisign)".into()
            })
        );
        assert_eq!(s.channels.tlstore, Some(Channel { outcome: "current".into(), reason: String::new() }));
        assert_eq!(s.channels.problem().as_deref(), Some("minisign is not installed (pkg install minisign)"));
        let none = Snapshot::parse("item\tdawn\tavailable\t1\t\tbinary\t-\t-\t0\n");
        assert_eq!(none.channels, Channels::default());
    }

    #[test]
    fn channel_problems_leave_offline_alone() {
        let ch = |o: &str, r: &str| Some(Channel::new(o, r));
        let mut c = Channels { catalog: ch("offline", "the release could not be reached"), tlstore: ch("current", "-") };
        assert_eq!(c.problem(), None, "offline is normal on a phone");
        c.tlstore = ch("refused", "the tlstore that was offered is not signed by the launcher");
        assert_eq!(c.problem().as_deref(), Some("the tlstore that was offered is not signed by the launcher"));
        c.catalog = ch("cannot-verify", "the trusted key is missing — reopen the app to put it back");
        assert_eq!(
            c.problem().as_deref(),
            Some("the trusted key is missing — reopen the app to put it back"),
            "the item list's reason comes first"
        );
        c.catalog = ch("newer", "-");
        c.tlstore = ch("refused", "-");
        assert_eq!(c.problem().as_deref(), Some("what was offered could not be verified"));
        assert_eq!(Channels::default().problem(), None);
    }

    #[test]
    fn self_check_reads_the_channel_fields() {
        let six = "self\t0.11\t-\t0\tcannot-verify\tminisign is not installed (pkg install minisign)\n";
        assert_eq!(
            parse_self_check(six),
            Some(SelfCheck {
                have: "0.11".into(),
                new: "-".into(),
                available: false,
                channel: Some(Channel {
                    outcome: "cannot-verify".into(),
                    reason: "minisign is not installed (pkg install minisign)".into()
                }),
            })
        );
        let newer = parse_self_check("self\t0.11\t0.12\t1\tnewer\t-").unwrap();
        assert!(newer.available);
        assert_eq!(newer.channel, Some(Channel { outcome: "newer".into(), reason: String::new() }));
        let four = parse_self_check("self\t0.11\t0.11\t0\n").unwrap();
        assert_eq!((four.new.as_str(), four.available, four.channel), ("0.11", false, None));
        let five = parse_self_check("self\t0.11\t-\t0\toffline").unwrap();
        assert_eq!(five.channel, Some(Channel { outcome: "offline".into(), reason: String::new() }));
    }
}
