//! End to end, in real jj repositories: random stories of commits normalized
//! by the whole pipeline and checked from outside, and the guide's own
//! examples.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

use hegel::TestCase;
use hegel::generators as gs;
use jj_graph::apply::{Options, Outcome, normalize};
use jj_graph::diff::patch_signature;
use jj_graph::jj::{Jj, change, commit};
use jj_graph::load::{Scope, load};
use jj_graph::{dot, skeleton};

const SLOTS: usize = 6;

/// A scratch repository with its own jj configuration.
struct Repo {
    dir: tempfile::TempDir,
}

impl Repo {
    fn new() -> Repo {
        let dir = tempfile::tempdir().expect("a scratch directory");
        std::fs::write(
            dir.path().join("config.toml"),
            "[user]\nname = \"Test\"\nemail = \"test@example.com\"\n[ui]\npaginate = \"never\"\n",
        )
        .unwrap();
        std::fs::create_dir(dir.path().join("repo")).unwrap();
        let r = Repo { dir };
        r.jj(&["git", "init"]);
        r
    }

    fn root(&self) -> PathBuf {
        self.dir.path().join("repo")
    }

    fn config(&self) -> PathBuf {
        self.dir.path().join("config.toml")
    }

    fn jj(&self, args: &[&str]) -> String {
        let out = Command::new("jj")
            .current_dir(self.root())
            .env("JJ_CONFIG", self.config())
            .args(["--no-pager", "--color=never"])
            .args(args)
            .output()
            .expect("jj runs");
        assert!(
            out.status.success(),
            "jj {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }

    fn write(&self, path: &str, text: &str) {
        let p = self.root().join(path);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    fn read(&self, path: &str) -> String {
        std::fs::read_to_string(self.root().join(path)).unwrap()
    }

    fn current_change(&self) -> String {
        self.jj(&["log", "--no-graph", "-r", "@", "-T", "change_id"])
            .trim()
            .to_owned()
    }

    fn handle(&self) -> Jj {
        Jj::discover(&self.root())
            .unwrap()
            .with_env("JJ_CONFIG", self.config())
    }

    /// The jj-graph binary, as a command in this repository.
    fn jj_graph(&self, args: &[&str]) -> std::process::Output {
        Command::new(env!("CARGO_BIN_EXE_jj-graph"))
            .current_dir(self.root())
            .env("JJ_CONFIG", self.config())
            .args(args)
            .output()
            .expect("jj-graph runs")
    }

    /// A first commit outside the scope, with a file of empty slots that
    /// changes on different branches can fill without conflicting.
    fn base(&self) -> String {
        let mut shared = String::new();
        for k in 0..SLOTS {
            shared.push_str(&format!("// slot {k}\n//\n//\n"));
        }
        self.write("src/shared.rs", &shared);
        self.jj(&["describe", "-m", "base"]);
        self.current_change()
    }
}

fn options(revset: &str, hoist: bool) -> Options {
    Options {
        scope: Scope {
            revset: revset.into(),
            anchors: None,
            allow_conflicts: false,
        },
        cosmetic: false,
        hoist,
        editor: PathBuf::from(env!("CARGO_BIN_EXE_jj-graph")),
        allow_new_combinations: false,
        allow_tree_changes: false,
        apply: true,
    }
}

#[derive(Clone, Debug)]
struct Step {
    parents: Vec<usize>,
    calls: Vec<usize>,
    uses_traits: Vec<usize>,
    defines_trait: bool,
    slot: Option<usize>,
    calls_shared: Vec<usize>,
    /// A parent whose file this commit re-indents with tabs: a cosmetic
    /// edit. Each file is re-indented at most once, so nothing conflicts.
    reformats: Option<usize>,
}

#[derive(Clone, Debug)]
struct Story {
    steps: Vec<Step>,
    working_copy_on_top: bool,
}

/// A story of up to six commits: each adds a file with a function that
/// calls other commits' functions (earlier or later ones) and uses their
/// traits, may define a trait of its own, and may fill a slot of the shared
/// file.
#[hegel::composite]
fn stories(tc: &TestCase) -> Story {
    let n = tc.draw(gs::integers::<usize>().min_value(1).max_value(6));
    let traits: Vec<bool> = (0..n)
        .map(|_| tc.draw(gs::weighted_booleans(0.4)))
        .collect();
    let slots: Vec<usize> = tc.draw(gs::permutations((0..SLOTS).collect::<Vec<_>>()));
    let mut steps = Vec::new();
    let mut reformatted = BTreeSet::new();
    for i in 0..n {
        let mut parents = tc.draw(gs::subsequences((0..i).collect::<Vec<_>>()).max_size(2));
        if parents.is_empty() && i > 0 && tc.draw(gs::weighted_booleans(0.6)) {
            parents.push(i - 1);
        }
        let fresh: Vec<usize> = parents
            .iter()
            .copied()
            .filter(|p| !reformatted.contains(p))
            .collect();
        let reformats = (!fresh.is_empty() && tc.draw(gs::weighted_booleans(0.4)))
            .then(|| tc.draw(gs::sampled_from(fresh)));
        if let Some(p) = reformats {
            reformatted.insert(p);
        }
        // Mostly calls into earlier commits; now and then one into a later
        // commit, as when a CLI is written before its engine.
        let earlier: Vec<usize> = (0..i).collect();
        let later: Vec<usize> = (i + 1..n).collect();
        let mut calls = tc.draw(gs::subsequences(earlier.clone()).max_size(2));
        if !later.is_empty() && tc.draw(gs::weighted_booleans(0.1)) {
            calls.push(tc.draw(gs::sampled_from(later)));
        }
        let trait_owners: Vec<usize> = earlier.iter().copied().filter(|j| traits[*j]).collect();
        let uses_traits = tc.draw(gs::subsequences(trait_owners).max_size(1));
        let slot = tc
            .draw(gs::weighted_booleans(0.35))
            .then_some(slots[i % SLOTS]);
        steps.push(Step {
            parents,
            calls,
            uses_traits,
            defines_trait: traits[i],
            slot,
            calls_shared: Vec::new(),
            reformats,
        });
    }
    // Calls into the shared file go to commits that fill a slot: earlier
    // ones, and now and then a later one.
    let fillers: Vec<usize> = steps
        .iter()
        .enumerate()
        .filter(|(_, s)| s.slot.is_some())
        .map(|(i, _)| i)
        .collect();
    for (i, step) in steps.iter_mut().enumerate() {
        let earlier: Vec<usize> = fillers.iter().copied().filter(|j| *j < i).collect();
        let later: Vec<usize> = fillers.iter().copied().filter(|j| *j > i).collect();
        let mut calls = tc.draw(gs::subsequences(earlier).max_size(1));
        if !later.is_empty() && tc.draw(gs::weighted_booleans(0.1)) {
            calls.push(tc.draw(gs::sampled_from(later)));
        }
        step.calls_shared = calls;
    }
    Story {
        steps,
        working_copy_on_top: tc.draw(gs::weighted_booleans(0.7)),
    }
}

fn source(i: usize, s: &Step) -> String {
    let mut out = String::new();
    if s.defines_trait {
        out.push_str(&format!("pub trait T{i} {{\n    fn run(&self);\n}}\n\n"));
    }
    out.push_str(&format!("pub fn c{i}() {{\n    let _id = {i};\n"));
    for j in &s.calls {
        out.push_str(&format!("    c{j}();\n"));
    }
    for k in &s.uses_traits {
        out.push_str(&format!("    let _t: Option<&dyn T{k}> = None;\n"));
    }
    for j in &s.calls_shared {
        out.push_str(&format!("    shared_{j}();\n"));
    }
    out.push_str("}\n");
    out
}

/// Build the story on a base commit; return the base and each commit's
/// change ID.
fn build(r: &Repo, story: &Story) -> (String, Vec<String>) {
    let base = r.base();
    let mut ids: Vec<String> = Vec::new();
    for (i, s) in story.steps.iter().enumerate() {
        let parents: Vec<String> = if s.parents.is_empty() {
            vec![change(&base)]
        } else {
            s.parents.iter().map(|p| change(&ids[*p])).collect()
        };
        let mut args = vec!["new".to_owned(), "-m".into(), format!("c{i}")];
        args.extend(parents);
        r.jj(&args.iter().map(String::as_str).collect::<Vec<_>>());
        r.write(&format!("src/c{i}.rs"), &source(i, s));
        if let Some(k) = s.slot {
            let shared = r.read("src/shared.rs").replace(
                &format!("// slot {k}\n"),
                &format!("pub fn shared_{i}() {{}}\n"),
            );
            r.write("src/shared.rs", &shared);
        }
        if let Some(p) = s.reformats {
            let file = format!("src/c{p}.rs");
            let tabs = r.read(&file).replace("    ", "\t");
            r.write(&file, &tabs);
        }
        ids.push(r.current_change());
    }
    if story.working_copy_on_top {
        r.jj(&["new", &change(ids.last().unwrap())]);
    }
    let conflicted = r.jj(&[
        "log",
        "--no-graph",
        "-r",
        "conflicts()",
        "-T",
        "change_id ++ \"\\n\"",
    ]);
    assert!(
        conflicted.trim().is_empty(),
        "the story itself conflicts: {conflicted}"
    );
    (base, ids)
}

/// Files by name, with their text.
type Files = [(String, String)];

fn files_on_disk(r: &Repo) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(r.root().join("src")).unwrap() {
        let p = entry.unwrap().path();
        out.push((
            p.file_name().unwrap().to_string_lossy().into_owned(),
            std::fs::read_to_string(&p).unwrap(),
        ));
    }
    out.sort();
    out
}

/// Check a finished normalization from outside jj-graph's own checks;
/// `opts` are the options it ran with. Without anchor growth the working
/// copy's files must be exactly `before_files`.
fn check_outcome(
    r: &Repo,
    jj: &Jj,
    opts: &Options,
    o: &Outcome,
    before_files: &[(String, String)],
) {
    check_outcome_with(r, jj, opts, o, &|after: &[(String, String)]| {
        assert_eq!(after, before_files, "files in the working copy changed");
    });
}

fn check_outcome_with(r: &Repo, jj: &Jj, opts: &Options, o: &Outcome, files_ok: &dyn Fn(&Files)) {
    let revset = opts.scope.revset.as_str();
    let head = jj.head_op().unwrap();
    let after = load(
        jj,
        &head,
        &Scope {
            revset: revset.into(),
            anchors: None,
            allow_conflicts: true,
        },
    )
    .unwrap();
    assert!(
        after.commits.values().all(|c| !c.conflict),
        "a change has conflicts"
    );
    assert_eq!(
        after.graph.parents, o.target.parents,
        "the repository is not in the planned normal form"
    );
    assert!(
        after.graph.is_normal(),
        "the repository is not in normal form when read back: {:?}",
        after.graph.check()
    );
    for v in o
        .before
        .anchors
        .keys()
        .filter(|v| !o.growth.contains_key(*v))
    {
        assert!(
            jj.same_tree(&head, &commit(o.before.commit_id(v)), &change(v))
                .unwrap(),
            "anchor {v} changed its tree"
        );
    }
    for v in o.start.graph.parents.keys() {
        let old = patch_signature(&jj.diff(&o.start.op, &commit(o.start.commit_id(v))).unwrap());
        let new = patch_signature(&jj.diff(&head, &change(v)).unwrap());
        assert_eq!(old, new, "{v}'s own diff changed");
    }
    files_ok(&files_on_disk(r));
    let again = normalize(jj, opts).expect("normalizing again works");
    assert!(
        again.steps.is_empty() && again.hoisted.is_empty() && again.precursors.is_empty(),
        "normalizing twice did more: precursors {:?}, hoisted {:?}, moved {:?}",
        again.precursors,
        again.hoisted,
        again.steps
    );
}

#[hegel::test(test_cases = 40)]
fn normalizing_a_story_reaches_a_stable_normal_form_without_changing_any_tree(tc: TestCase) {
    let story = tc.draw(stories());
    let hoist = tc.draw(gs::booleans());
    let cosmetic = tc.draw(gs::booleans());
    let allow = tc.draw(gs::weighted_booleans(0.3));
    let grow = tc.draw(gs::weighted_booleans(0.4));
    let r = Repo::new();
    let (base, _) = build(&r, &story);
    let jj = r.handle();
    let revset = format!("{}..", change(&base));
    let before_files = files_on_disk(&r);
    let before_op = jj.head_op().unwrap();
    let opts = Options {
        cosmetic,
        allow_new_combinations: allow,
        allow_tree_changes: grow,
        ..options(&revset, hoist)
    };
    match normalize(&jj, &opts) {
        Ok(o) => {
            tc.event(match (&o.integrated, o.growth.is_empty()) {
                (None, _) => "already normal",
                (Some(_), false) => "normalized, and an anchor grew",
                (Some(_), true) => "normalized",
            });
            if !o.precursors.is_empty() {
                tc.event("split a refactor precursor");
            }
            if !o.hoisted.is_empty() {
                tc.event("hoisted contracts");
            }
            // An anchor that grew keeps every file no gained change touches,
            // and any file it gains is one a gained change touches. The
            // files of each change are what jj's own diff lists.
            let touched: BTreeSet<String> = o
                .growth
                .values()
                .flatten()
                .flat_map(|x| &o.start.graph.info[x].files)
                .filter_map(|f| f.strip_prefix("src/").map(str::to_owned))
                .collect();
            let before_files = before_files.clone();
            check_outcome_with(&r, &jj, &opts, &o, &move |after: &[(String, String)]| {
                for (name, text) in &before_files {
                    let now = after.iter().find(|(n, _)| n == name).map(|(_, t)| t);
                    if !touched.contains(name) {
                        assert_eq!(now, Some(text), "{name} changed in the working copy");
                    }
                }
                for (name, _) in after {
                    let known = before_files.iter().any(|(n, _)| n == name);
                    assert!(
                        known || touched.contains(name),
                        "{name} appeared without a gained change"
                    );
                }
            });
        }
        Err(e) => {
            let msg = format!("{e:#}");
            if msg.contains("require each other") {
                tc.event("requirement cycle");
            } else if msg.contains("never merged before") {
                tc.event("new combination refused");
            } else if msg.contains("would change files that must stay") {
                tc.event("anchor growth refused");
            } else if allow && msg.contains("nothing was applied") {
                tc.event("allowed combination failed its checks");
            } else {
                panic!("unexpected failure: {msg}");
            }
            // A refusal or a failed check leaves the repository alone.
            assert_eq!(
                jj.head_op().unwrap(),
                before_op,
                "a refused normalization ran an operation"
            );
            assert_eq!(
                files_on_disk(&r),
                before_files,
                "a refused normalization changed files"
            );
        }
    }
}

/// Two branches fill slots of the same file; a change on one calls into
/// both. Its normal form merges their edits for the first time, which
/// jj-graph refuses by default; allowed, the merge is clean, and the result
/// is checked like any other.
#[test]
fn a_first_merge_of_one_files_edits_is_refused_unless_allowed() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "left"]);
    let shared = r
        .read("src/shared.rs")
        .replace("// slot 0\n", "pub fn left() {}\n");
    r.write("src/shared.rs", &shared);
    r.jj(&["new", "-m", "uses both"]);
    r.write("src/user.rs", "pub fn user() { left(); right(); }\n");
    r.jj(&["new", "-m", "right", &change(&base)]);
    let shared = r
        .read("src/shared.rs")
        .replace("// slot 5\n", "pub fn right() {}\n");
    r.write("src/shared.rs", &shared);
    r.jj(&["new", &change(&base)]);
    let jj = r.handle();
    let revset = format!("{}..", change(&base));
    let refused = normalize(&jj, &options(&revset, false)).unwrap_err();
    assert!(
        format!("{refused:#}").contains("never merged before"),
        "{refused:#}"
    );
    let before_files = files_on_disk(&r);
    let opts = Options {
        allow_new_combinations: true,
        ..options(&revset, false)
    };
    let o = normalize(&jj, &opts).unwrap();
    assert!(o.integrated.is_some());
    check_outcome(&r, &jj, &opts, &o, &before_files);
}

/// Pattern B: the auth client sits on the database adapter it does not use.
#[test]
fn orthogonal_changes_fork_and_their_consumer_merges() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "Add the database adapter"]);
    r.write("src/db.rs", "pub fn db() {}\n");
    r.jj(&["new", "-m", "Add the auth client"]);
    r.write("src/auth.rs", "pub fn auth() {}\n");
    r.jj(&["new", "-m", "Wire the engine"]);
    r.write("src/engine.rs", "pub fn engine() { db(); auth(); }\n");
    let engine = r.current_change();
    let jj = r.handle();
    let revset = format!("{}..", change(&base));
    let o = normalize(&jj, &options(&revset, false)).unwrap();
    assert!(o.integrated.is_some());
    let parents = r.jj(&[
        "log",
        "--no-graph",
        "-r",
        &change(&engine),
        "-T",
        "parents.map(|p| p.description().first_line()).join(\"|\")",
    ]);
    let parents: BTreeSet<&str> = parents.split('|').collect();
    assert_eq!(
        parents,
        BTreeSet::from(["Add the database adapter", "Add the auth client"])
    );
}

/// Pattern D: the CLI was written before the engine it calls.
#[test]
fn a_contract_written_later_moves_below_its_user() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "Add the CLI"]);
    r.write("src/cli.rs", "pub fn main() { let e = Engine::new(); }\n");
    let cli = r.current_change();
    r.jj(&["new", "-m", "Add the engine"]);
    r.write("src/engine.rs", "pub struct Engine;\n");
    r.jj(&["new"]);
    let jj = r.handle();
    let o = normalize(&jj, &options(&format!("{}..", change(&base)), false)).unwrap();
    assert!(o.integrated.is_some());
    let parent = r.jj(&[
        "log",
        "--no-graph",
        "-r",
        &change(&cli),
        "-T",
        "parents.map(|p| p.description().first_line()).join(\"|\")",
    ]);
    assert_eq!(parent, "Add the engine");
}

/// Pass 2 on a real file: the trait moves into a change of its own, and a
/// change that only uses the trait no longer waits for the implementation.
#[test]
fn hoisting_moves_a_trait_below_its_implementation() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "Add storage"]);
    r.write(
        "src/store.rs",
        "use std::fmt;\n\n/// The storage contract.\npub trait Storage {\n    fn get(&self) -> u8;\n}\n\npub struct Db;\n\nimpl Storage for Db {\n    fn get(&self) -> u8 { helper() }\n}\n\nfn helper() -> u8 { 1 }\n",
    );
    let storage = r.current_change();
    r.jj(&["new", "-m", "Add the client"]);
    r.write(
        "src/client.rs",
        "pub fn client(s: &dyn Storage) -> u8 { s.get() }\n",
    );
    let client = r.current_change();
    r.jj(&["new"]);
    let jj = r.handle();
    let revset = format!("{}..", change(&base));
    let before_files = files_on_disk(&r);
    let opts = options(&revset, true);
    let o = normalize(&jj, &opts).unwrap();
    let [(hoisted, twin)] = o.hoisted.as_slice() else {
        panic!("expected one hoist: {:?}", o.hoisted)
    };
    assert_eq!(hoisted, &storage);
    let twin_file = r.jj(&["file", "show", "-r", &change(twin), "src/store.rs"]);
    assert!(
        twin_file.contains("pub trait Storage") && twin_file.contains("/// The storage contract.")
    );
    assert!(twin_file.contains("pub struct Db"));
    // Nothing the contracts use comes from `std::fmt`, so its import stays.
    assert!(!twin_file.contains("use std::fmt;"), "{twin_file}");
    assert!(!twin_file.contains("impl Storage for Db") && !twin_file.contains("fn helper"));
    let client_parent = r.jj(&[
        "log",
        "--no-graph",
        "-r",
        &change(&client),
        "-T",
        "parents.map(|p| p.change_id()).join(\"|\")",
    ]);
    assert_eq!(&client_parent, twin);
    check_outcome(&r, &jj, &opts, &o, &before_files);
}

/// The working copy sits on a change that calls into a change it does not
/// descend from. Repairing that changes the working copy's files, so it is
/// refused by default; allowed, the working copy gains exactly that
/// change's files.
#[test]
fn a_working_copy_grows_only_when_allowed() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "Add the database"]);
    r.write("src/db.rs", "pub fn db() {}\n");
    r.jj(&["new", "-m", "Add the CLI", &change(&base)]);
    r.write("src/cli.rs", "pub fn cli() { db(); }\n");
    r.jj(&["new"]);
    let jj = r.handle();
    let revset = format!("{}..", change(&base));
    let before_op = jj.head_op().unwrap();
    let refused = normalize(&jj, &options(&revset, false)).unwrap_err();
    assert!(
        format!("{refused:#}").contains("would change files that must stay"),
        "{refused:#}"
    );
    assert_eq!(jj.head_op().unwrap(), before_op);
    let mut before_files = files_on_disk(&r);
    let o = normalize(
        &jj,
        &Options {
            allow_tree_changes: true,
            ..options(&revset, false)
        },
    )
    .unwrap();
    assert!(o.integrated.is_some());
    before_files.push(("db.rs".to_owned(), "pub fn db() {}\n".to_owned()));
    before_files.sort();
    assert_eq!(files_on_disk(&r), before_files);
    let head = jj.head_op().unwrap();
    let after = load(
        &jj,
        &head,
        &Scope {
            revset,
            anchors: None,
            allow_conflicts: false,
        },
    )
    .unwrap();
    assert!(after.graph.is_normal());
}

/// The guide's refactor precursor: a change re-indents a file and adds a
/// function. The re-indent moves into a change of its own below it, which
/// defines nothing and stays below it.
#[test]
fn cosmetic_edits_move_into_a_precursor() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "Add the store"]);
    r.write("src/store.rs", "pub fn get() -> u8 {\n    1\n}\n");
    r.jj(&["new", "-m", "Add put"]);
    r.write(
        "src/store.rs",
        "pub fn get() -> u8 {\n\t1\n}\n\npub fn put() {}\n",
    );
    let feature = r.current_change();
    r.jj(&["new"]);
    let jj = r.handle();
    let revset = format!("{}..", change(&base));
    let before_files = files_on_disk(&r);
    let opts = Options {
        cosmetic: true,
        ..options(&revset, false)
    };
    let o = normalize(&jj, &opts).unwrap();
    let [(v, precursor)] = o.precursors.as_slice() else {
        panic!("expected one precursor: {:?}", o.precursors)
    };
    assert_eq!(v, &feature);
    let text = r.jj(&["file", "show", "-r", &change(precursor), "src/store.rs"]);
    assert_eq!(text, "pub fn get() -> u8 {\n\t1\n}\n");
    assert!(
        o.start.symbols[precursor].defs.is_empty(),
        "the precursor defines {:?}",
        o.start.symbols[precursor].defs
    );
    assert_eq!(
        o.target.parents[&feature],
        BTreeSet::from([precursor.clone()])
    );
    check_outcome(&r, &jj, &opts, &o, &before_files);
}

/// A file the change renames (and reformats) stays with the change, and
/// the other file's reformatting still moves: the adversarial review's
/// case that made `plan --cosmetic` give up.
#[test]
fn a_renamed_file_stays_with_its_change_while_cosmetic_edits_move() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "Add the store"]);
    r.write("src/store.rs", "pub fn get() -> u8 {\n    1\n}\n");
    r.write("src/old.rs", "pub fn old() -> u8 {\n    2\n}\n");
    r.jj(&["new", "-m", "Rename old and add put"]);
    r.write(
        "src/store.rs",
        "pub fn get() -> u8 {\n\t1\n}\n\npub fn put() {}\n",
    );
    std::fs::remove_file(r.root().join("src/old.rs")).unwrap();
    r.write("src/new.rs", "pub fn old() -> u8 {\n\t2\n}\n");
    let feature = r.current_change();
    r.jj(&["new"]);
    let jj = r.handle();
    let revset = format!("{}..", change(&base));
    let before_files = files_on_disk(&r);
    let opts = Options {
        cosmetic: true,
        ..options(&revset, false)
    };
    let o = normalize(&jj, &opts).unwrap();
    let [(v, precursor)] = o.precursors.as_slice() else {
        panic!("expected one precursor: {:?}", o.precursors)
    };
    assert_eq!(v, &feature);
    let show = |path: &str| r.jj(&["file", "show", "-r", &change(precursor), path]);
    assert_eq!(show("src/store.rs"), "pub fn get() -> u8 {\n\t1\n}\n");
    assert_eq!(show("src/old.rs"), "pub fn old() -> u8 {\n    2\n}\n");
    check_outcome(&r, &jj, &opts, &o, &before_files);
}

/// Section 3: the guide's diagram becomes a ghost graph, and running it
/// again creates nothing.
#[test]
fn the_guides_diagram_becomes_a_ghost_graph_once() {
    let r = Repo::new();
    r.base();
    let diagram = dot::parse(
        r#"digraph components {
            A [label="arch: core_types\nInterfaces & Schemas"]
            B [label="feat: db_adapter\nImplements Storage"]
            C [label="feat: api_client\nImplements Network"]
            D [label="feat: engine\nInjects Storage & Network"]
            E [label="feat: cli\nUser Interface"]
            A -> {B C}
            {B C} -> D -> E
            A -> D
        }"#,
    )
    .unwrap();
    let plan = skeleton::plan(&diagram, &[]).unwrap();
    assert_eq!(
        plan.dropped,
        BTreeSet::from([("A".to_owned(), "D".to_owned())])
    );
    let jj = r.handle();
    let made = skeleton::materialize(&jj, &plan, "@", true).unwrap();
    assert!(made.iter().all(|m| m.created));
    let engine = &made.iter().find(|m| m.node == "D").unwrap().change;
    let parents = r.jj(&[
        "log",
        "--no-graph",
        "-r",
        &change(engine),
        "-T",
        "parents.map(|p| p.description().first_line()).join(\"|\")",
    ]);
    assert_eq!(
        parents.split('|').collect::<BTreeSet<_>>(),
        BTreeSet::from(["feat: db_adapter", "feat: api_client"])
    );
    let body = r.jj(&[
        "log",
        "--no-graph",
        "-r",
        &change(engine),
        "-T",
        "description",
    ]);
    assert_eq!(body, "feat: engine\n\nInjects Storage & Network\n");
    let again = skeleton::materialize(&jj, &plan, "@", true).unwrap();
    assert!(again.iter().all(|m| !m.created));
    assert_eq!(
        again.iter().map(|m| &m.change).collect::<Vec<_>>(),
        made.iter().map(|m| &m.change).collect::<Vec<_>>()
    );
}

const LOGIN_V1: &str = "Feature: Login\n\n  @needs:engine\n  Scenario: Signing in\n    When ada signs in\n    Then she sees her dashboard\n\n  Scenario: Signing out\n    When ada signs out\n    Then she sees the login page\n";

const LOGIN_V2: &str = "Feature: Login\n\n  @needs:engine\n  Scenario: Signing in\n    When ada signs in with her password\n    Then she sees her dashboard\n\n  Scenario: Signing out\n    When ada signs out\n    Then she sees the login page\n\n  @needs:cli\n  Scenario: Remembering me\n    When ada signs in and ticks remember me\n    Then she stays signed in\n";

/// Features join the diagram: a spec change adds the feature file, and
/// each scenario sits on its spec and what it needs. Reruns converge: an
/// edited feature updates its spec and the scenarios that changed, adds the
/// new scenario, and keeps code written in a scenario's change.
#[test]
fn features_become_changes_and_reruns_converge() {
    use jj_graph::gherkin::read_feature;
    use jj_graph::skeleton::{Made, materialize, plan, scenario_node, spec_node};
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new"]);
    r.write("features/login.feature", LOGIN_V1);
    let diagram = dot::parse(
        "digraph { engine [label=\"feat: engine\"]; cli [label=\"feat: cli\"]; engine -> cli }",
    )
    .unwrap();
    let jj = r.handle();
    let onto = change(&base);
    let run = |text: &str| -> (Vec<Made>, jj_graph::gherkin::FeatureSpec) {
        let f = read_feature("features/login.feature", text).unwrap();
        let s = plan(&diagram, std::slice::from_ref(&f)).unwrap();
        (materialize(&jj, &s, &onto, true).unwrap(), f)
    };
    let id =
        |made: &[Made], node: &str| made.iter().find(|m| m.node == node).unwrap().change.clone();
    let parents = |c: &str| -> BTreeSet<String> {
        r.jj(&[
            "log",
            "--no-graph",
            "-r",
            &change(c),
            "-T",
            "parents.map(|p| p.description().first_line()).join(\"|\")",
        ])
        .split('|')
        .map(str::to_owned)
        .collect()
    };

    let (first, f) = run(LOGIN_V1);
    assert!(first.iter().all(|m| m.created));
    let spec = id(&first, &spec_node(&f));
    assert_eq!(
        r.jj(&[
            "file",
            "show",
            "-r",
            &change(&spec),
            "features/login.feature"
        ]),
        LOGIN_V1
    );
    assert_eq!(
        r.jj(&["diff", "--name-only", "-r", &change(&spec)]),
        "features/login.feature\n"
    );
    let signing_in = id(&first, &scenario_node(&f, 0));
    assert_eq!(
        parents(&signing_in),
        BTreeSet::from(["spec(login): Login".to_owned(), "feat: engine".to_owned()])
    );
    assert_eq!(
        parents(&id(&first, &scenario_node(&f, 1))),
        BTreeSet::from(["spec(login): Login".to_owned(), "feat: cli".to_owned()])
    );

    let (again, _) = run(LOGIN_V1);
    assert!(
        again.iter().all(|m| !m.created && !m.updated),
        "a rerun changed something: {again:?}"
    );

    // Write code in "Signing in", then change the feature.
    let working = r.current_change();
    r.jj(&["edit", &change(&signing_in)]);
    r.write("src/login.rs", "pub fn sign_in() {}\n");
    r.jj(&["edit", &change(&working)]);
    r.write("features/login.feature", LOGIN_V2);
    let (third, f2) = run(LOGIN_V2);
    let by_node = |node: &str| third.iter().find(|m| m.node == node).unwrap();
    assert!(by_node(&spec_node(&f2)).updated);
    assert!(
        by_node(&scenario_node(&f2, 0)).updated,
        "the changed scenario keeps its change, updated"
    );
    assert!(!by_node(&scenario_node(&f2, 1)).updated && !by_node(&scenario_node(&f2, 1)).created);
    assert!(by_node(&scenario_node(&f2, 2)).created);
    assert_eq!(by_node(&scenario_node(&f2, 0)).change, signing_in);
    assert_eq!(
        r.jj(&[
            "file",
            "show",
            "-r",
            &change(&spec),
            "features/login.feature"
        ]),
        LOGIN_V2
    );
    assert_eq!(
        r.jj(&["file", "show", "-r", &change(&signing_in), "src/login.rs"]),
        "pub fn sign_in() {}\n"
    );
    let description = r.jj(&[
        "log",
        "--no-graph",
        "-r",
        &change(&signing_in),
        "-T",
        "description",
    ]);
    assert!(description.contains("with her password"), "{description}");
}

/// `check` exits 1 on a graph that is not normal and 0 after normalizing.
#[test]
fn check_exit_status_follows_the_normal_form() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "one"]);
    r.write("src/one.rs", "pub fn one() {}\n");
    r.jj(&["new", "-m", "two"]);
    r.write("src/two.rs", "pub fn two() {}\n");
    // An empty working copy on top: as an anchor it keeps both, while `two`
    // itself does not need `one`.
    r.jj(&["new"]);
    let revset = format!("{}..", change(&base));
    let status = |args: &[&str]| r.jj_graph(args).status.code();
    assert_eq!(status(&["check", "-r", &revset]), Some(1));
    let out = r.jj_graph(&["normalize", "-r", &revset]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(status(&["check", "-r", &revset]), Some(0));
}

/// A contract gains a method after its realizations were written. `shapes`
/// finds the changed contract through `jj evolog` and runs the check in
/// each sibling and each descendant of the contract, in its own tree.
#[test]
fn shapes_run_the_check_in_every_affected_tree() {
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "contract"]);
    r.write("src/types.rs", "pub trait Store { fn get(&self); }\n");
    let contract = r.current_change();
    r.jj(&["new", "-m", "db", &change(&contract)]);
    r.write("src/db.rs", "pub struct Db;\n");
    let db = r.current_change();
    r.jj(&["new", "-m", "net", &change(&contract)]);
    r.write("src/net.rs", "pub struct Net;\n");
    let net = r.current_change();
    r.jj(&["edit", &change(&contract)]);
    r.write(
        "src/types.rs",
        "pub trait Store { fn get(&self); fn put(&self); }\n",
    );
    r.jj(&["new", &change(&db), &change(&net)]);
    let top = r.current_change();
    let revset = format!("{}..", change(&base));
    let run = |cmd: &str| -> (Option<i32>, serde_json::Value) {
        let out = r.jj_graph(&["shapes", "-r", &revset, "--json", "--", "sh", "-c", cmd]);
        let json = serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|_| panic!("{}", String::from_utf8_lossy(&out.stderr)));
        (out.status.code(), json)
    };
    // Every affected tree has the new contract.
    let (code, json) = run("grep -q put src/types.rs");
    assert_eq!(code, Some(0), "{json}");
    assert_eq!(json["mutated"], serde_json::json!([contract]));
    let ran: BTreeSet<String> = json["runs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["change"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(ran, BTreeSet::from([db.clone(), net.clone(), top.clone()]));
    // A check that fails where net's file exists fails exactly there.
    let (code, json) = run("test ! -f src/net.rs");
    assert_eq!(code, Some(1));
    let failed: BTreeSet<String> = json["runs"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["passed"] == serde_json::json!(false))
        .map(|r| r["change"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(failed, BTreeSet::from([net, top]));
}

/// A merge that calls a branch's private helper leaks it.
#[test]
fn a_merge_using_a_private_helper_is_a_leak() {
    use jj_graph::shapes::{Shape, classify, leaks};
    let r = Repo::new();
    let base = r.base();
    r.jj(&["new", "-m", "contract"]);
    r.write("src/types.rs", "pub trait Store { fn get(&self); }\n");
    let contract = r.current_change();
    r.jj(&["new", "-m", "db", &change(&contract)]);
    r.write("src/db.rs", "pub struct Db;\nfn compact() {}\n");
    let db = r.current_change();
    r.jj(&["new", "-m", "net", &change(&contract)]);
    r.write("src/net.rs", "pub struct Net;\n");
    let net = r.current_change();
    r.jj(&["new", "-m", "engine", &change(&db), &change(&net)]);
    r.write("src/engine.rs", "pub fn engine() { compact(); }\n");
    let engine = r.current_change();
    let jj = r.handle();
    let l = load(
        &jj,
        &jj.head_op().unwrap(),
        &Scope {
            revset: format!("{}..", change(&base)),
            anchors: None,
            allow_conflicts: false,
        },
    )
    .unwrap();
    let shapes = classify(&l.graph, &l.symbols);
    assert!(shapes[&contract].contains(&Shape::ContractRoot));
    assert!(shapes[&db].contains(&Shape::Sibling) && shapes[&net].contains(&Shape::Sibling));
    assert!(shapes[&engine].contains(&Shape::Merge));
    let private = l
        .symbols
        .iter()
        .map(|(v, s)| (v.clone(), s.private.clone()))
        .collect();
    let found = leaks(&l.graph, &private);
    assert_eq!(found.len(), 1);
    assert_eq!(
        (found[0].merge.as_str(), found[0].from.as_str()),
        (engine.as_str(), db.as_str())
    );
}
