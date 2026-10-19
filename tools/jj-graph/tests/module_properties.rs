//! Properties of the modules around the core: reading diffs, selecting
//! lines, reading definitions, splitting out contracts, reading diagrams,
//! planning skeletons, and finding merge leaks. One property per test.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::process::Command;

use hegel::generators as gs;
use hegel::{Generator, TestCase};
use jj_graph::diff::{FileDiff, added_lines, parse_git_diff, patch_signature};
use jj_graph::dot::{self, Diagram};
use jj_graph::extract::{Kind, Lang, file_symbols, has_syntax_errors, parse};
use jj_graph::graph::{Change, Graph, Id};
use jj_graph::hoist::{contract_part, cosmetic_part};
use jj_graph::shapes::leaks;
use jj_graph::skeleton;

fn set<T: Ord>(items: impl IntoIterator<Item = T>) -> BTreeSet<T> {
    items.into_iter().collect()
}

// ---------------------------------------------------------------------
// Reading jj's diffs, against jj itself
// ---------------------------------------------------------------------

/// File text: a few lines from a small alphabet, among them lines a diff's
/// markers turn into look-alikes of its headers (a removed `-- x` shows as
/// `--- x`), and line ends with carriage returns; sometimes without a final
/// newline, sometimes empty.
#[hegel::composite]
fn texts(tc: &TestCase) -> String {
    let lines: Vec<String> = tc.draw(
        gs::vecs(
            gs::sampled_from(vec![
                "a",
                "b",
                "c",
                "",
                "  x  ",
                "ü",
                "-- x",
                "++ y",
                "--- a/z",
                "+++ b/z",
                "@@ -1 +1 @@",
                "\\ No newline at end of file",
                "diff --git a/q b/q",
                "cr\r",
                "lone\rcr",
            ])
            .map(String::from),
        )
        .max_size(6),
    );
    let mut text = lines.join("\n");
    if !text.is_empty() && tc.draw(gs::booleans()) {
        text.push('\n');
    }
    text
}

fn jj_in(dir: &Path, config: &Path, args: &[&str]) -> String {
    let out = Command::new("jj")
        .current_dir(dir)
        .env("JJ_CONFIG", config)
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

#[hegel::test(test_cases = 25)]
fn whole_file_diffs_from_jj_give_back_both_sides_of_every_file(tc: TestCase) {
    // jj writes paths unquoted, whatever they hold.
    let names = [
        "a.txt",
        "dir/b file.txt",
        "ünï.txt",
        "say \"hi\".ts",
        "x b/y.txt",
        "tab\tin.txt",
    ];
    let before: Vec<Option<String>> = names
        .iter()
        .map(|_| tc.draw(gs::optional(texts())))
        .collect();
    let after: Vec<Option<String>> = names
        .iter()
        .map(|_| tc.draw(gs::optional(texts())))
        .collect();
    let tmp = tempfile::tempdir().unwrap();
    let config = tmp.path().join("config.toml");
    std::fs::write(&config, "[user]\nname = \"T\"\nemail = \"t@example.com\"\n").unwrap();
    let repo = tmp.path().join("repo");
    std::fs::create_dir(&repo).unwrap();
    jj_in(&repo, &config, &["git", "init"]);
    let write = |files: &[Option<String>]| {
        for (name, text) in names.iter().zip(files) {
            let p = repo.join(name);
            let _ = std::fs::remove_file(&p);
            if let Some(t) = text {
                std::fs::create_dir_all(p.parent().unwrap()).unwrap();
                std::fs::write(&p, t).unwrap();
            }
        }
    };
    write(&before);
    jj_in(&repo, &config, &["new"]);
    write(&after);
    let diff = jj_in(
        &repo,
        &config,
        &["diff", "--git", "--context", "1000000000", "-r", "@"],
    );
    let files = parse_git_diff(&diff).unwrap();
    let old_tree: BTreeMap<&str, &String> = names
        .iter()
        .zip(&before)
        .filter_map(|(n, t)| t.as_ref().map(|t| (*n, t)))
        .collect();
    let new_tree: BTreeMap<&str, &String> = names
        .iter()
        .zip(&after)
        .filter_map(|(n, t)| t.as_ref().map(|t| (*n, t)))
        .collect();
    // jj may pair a deleted file with an added one as a rename, so check
    // sides rather than files: every side the diff shows is the real file,
    // and every path that changed shows up on some side.
    for f in &files {
        if f.same_text {
            // A move without a content change shows no text; the two sides
            // must really be the same.
            let (p, q) = (
                f.old_path.as_deref().unwrap(),
                f.new_path.as_deref().unwrap(),
            );
            assert_eq!(
                old_tree.get(p),
                new_tree.get(q),
                "{p} -> {q} is not a pure move\n{diff}"
            );
            continue;
        }
        if let Some(p) = &f.old_path {
            assert_eq!(
                Some(&&f.old),
                old_tree.get(p.as_str()),
                "old side of {p}\n{diff}"
            );
        }
        if let Some(p) = &f.new_path {
            assert_eq!(
                Some(&&f.new),
                new_tree.get(p.as_str()),
                "new side of {p}\n{diff}"
            );
        }
    }
    for (i, name) in names.iter().enumerate() {
        let shown = files
            .iter()
            .any(|f| f.old_path.as_deref() == Some(*name) || f.new_path.as_deref() == Some(*name));
        assert_eq!(
            shown,
            before[i] != after[i],
            "{name}: shown in the diff exactly when it changed\n{diff}"
        );
    }
    // The context a diff is shown with never changes its signature.
    let narrow = jj_in(
        &repo,
        &config,
        &["diff", "--git", "--context", "0", "-r", "@"],
    );
    let wide = jj_in(
        &repo,
        &config,
        &["diff", "--git", "--context", "5", "-r", "@"],
    );
    assert_eq!(patch_signature(&narrow), patch_signature(&wide));
}

#[hegel::test(test_cases = 300)]
fn added_lines_are_the_new_lines_a_line_diff_does_not_keep(tc: TestCase) {
    let (old, new) = (tc.draw(texts()), tc.draw(texts()));
    let added = added_lines(&old, &new);
    let new_lines: Vec<&str> = new.split_inclusive('\n').collect();
    // Sorted, merged, nonempty, and in bounds.
    for pair in added.windows(2) {
        assert!(pair[0].end < pair[1].start, "{added:?}");
    }
    assert!(
        added
            .iter()
            .all(|r| r.start < r.end && r.end <= new_lines.len()),
        "{added:?}"
    );
    assert!(added_lines(&new, &new).is_empty());
    // What is not added, the old text has in the same order.
    let mut old_lines = old.split_inclusive('\n');
    for (i, line) in new_lines.iter().enumerate() {
        if !added.iter().any(|r| r.contains(&i)) {
            assert!(
                old_lines.any(|o| o == *line),
                "{line:?} is kept but not in order in {old:?}"
            );
        }
    }
}

// ---------------------------------------------------------------------
// Reading definitions
// ---------------------------------------------------------------------

#[derive(Clone, Debug)]
enum RustItem {
    Trait(usize),
    Struct(usize),
    Fn { id: usize, calls: Vec<usize> },
    Impl { tr: usize, ty: usize },
    Const(usize),
}

#[hegel::composite]
fn rust_items(tc: &TestCase) -> Vec<RustItem> {
    let n = tc.draw(gs::integers::<usize>().max_value(6));
    let mut out = Vec::new();
    for i in 0..n {
        let kind = tc.draw(gs::integers::<u8>().max_value(4));
        out.push(match kind {
            0 => RustItem::Trait(i),
            1 => RustItem::Struct(i),
            2 => RustItem::Fn {
                id: i,
                calls: tc.draw(gs::vecs(gs::integers::<usize>().max_value(8)).max_size(2)),
            },
            3 => RustItem::Impl {
                tr: i,
                ty: tc.draw(gs::integers::<usize>().max_value(8)),
            },
            _ => RustItem::Const(i),
        });
    }
    out
}

/// The items as Rust source, laid out with `indent` and `gap` blank lines.
fn rust_source(items: &[RustItem], indent: &str, gap: usize) -> String {
    let sep = "\n".repeat(gap + 1);
    items
        .iter()
        .map(|it| match it {
            RustItem::Trait(i) => format!("pub trait T{i} {{\n{indent}fn m{i}(&self);\n}}\n"),
            RustItem::Struct(i) => format!("pub struct S{i} {{\n{indent}f{i}: u8,\n}}\n"),
            RustItem::Fn { id, calls } => {
                let body: String = calls.iter().map(|c| format!("{indent}g{c}();\n")).collect();
                format!("pub fn g{id}() {{\n{body}}}\n")
            }
            RustItem::Impl { tr, ty } => {
                format!("impl T{tr} for S{ty} {{\n{indent}fn m{tr}(&self) {{}}\n}}\n")
            }
            RustItem::Const(i) => format!("const C{i}: u8 = {i};\n"),
        })
        .collect::<Vec<_>>()
        .join(&sep)
}

fn expected_items(items: &[RustItem]) -> BTreeSet<(String, Kind)> {
    items
        .iter()
        .map(|it| match it {
            RustItem::Trait(i) => (format!("T{i}"), Kind::Contract),
            RustItem::Struct(i) => (format!("S{i}"), Kind::Contract),
            RustItem::Fn { id, .. } => (format!("g{id}"), Kind::Impl),
            RustItem::Impl { tr, ty } => (format!("S{ty}::m{tr}"), Kind::Impl),
            RustItem::Const(i) => (format!("C{i}"), Kind::Impl),
        })
        .collect()
}

#[hegel::test(test_cases = 300)]
fn every_generated_rust_item_is_read_with_its_kind(tc: TestCase) {
    let items = tc.draw(rust_items());
    let found: BTreeSet<(String, Kind)> = parse(Lang::Rust, &rust_source(&items, "    ", 1))
        .items
        .into_iter()
        .map(|i| (i.name, i.kind))
        .collect();
    assert_eq!(found, expected_items(&items));
}

fn modified(path: &str, old: &str, new: &str) -> FileDiff {
    FileDiff {
        old_path: Some(path.into()),
        new_path: Some(path.into()),
        old: old.into(),
        new: new.into(),
        ..FileDiff::default()
    }
}

#[hegel::test(test_cases = 300)]
fn changing_only_the_layout_defines_nothing(tc: TestCase) {
    let items = tc.draw(rust_items());
    let indent = tc.draw(gs::sampled_from(vec!["  ", "    ", "\t"]));
    let gap = tc.draw(gs::integers::<usize>().max_value(3));
    let s = file_symbols(&modified(
        "a.rs",
        &rust_source(&items, "    ", 1),
        &rust_source(&items, indent, gap),
    ));
    assert!(s.defs.is_empty(), "layout defined {:?}", s.defs);
}

#[hegel::test(test_cases = 300)]
fn adding_an_item_defines_it_and_its_members(tc: TestCase) {
    let items = tc.draw(rust_items());
    let extra = tc.draw(rust_items());
    let mut more = items.clone();
    // Shift the new items' numbers past the old ones, so names stay unique.
    let shift = |it: &RustItem| match it {
        RustItem::Trait(i) => RustItem::Trait(i + 100),
        RustItem::Struct(i) => RustItem::Struct(i + 100),
        RustItem::Fn { id, calls } => RustItem::Fn {
            id: id + 100,
            calls: calls.clone(),
        },
        RustItem::Impl { tr, ty } => RustItem::Impl {
            tr: tr + 100,
            ty: *ty,
        },
        RustItem::Const(i) => RustItem::Const(i + 100),
    };
    more.extend(extra.iter().map(shift));
    let s = file_symbols(&modified(
        "a.rs",
        &rust_source(&items, "    ", 1),
        &rust_source(&more, "    ", 1),
    ));
    let added: Vec<RustItem> = extra.iter().map(shift).collect();
    let mut want: BTreeSet<String> = expected_items(&added).into_iter().map(|(n, _)| n).collect();
    for it in &added {
        match it {
            RustItem::Trait(i) => drop(want.insert(format!("m{i}"))),
            RustItem::Struct(i) => drop(want.insert(format!("f{i}"))),
            _ => {}
        }
    }
    assert_eq!(s.defs, want);
}

#[hegel::test(test_cases = 300)]
fn a_call_added_to_a_function_is_a_reference(tc: TestCase) {
    let callee = tc.draw(gs::integers::<usize>().max_value(50));
    let old = "pub fn f() {\n    a();\n}\n";
    let new = format!("pub fn f() {{\n    a();\n    g{callee}();\n}}\n");
    let s = file_symbols(&modified("a.rs", old, &new));
    assert!(s.refs.contains(&format!("g{callee}")));
    assert!(
        !s.refs.contains("a"),
        "an unchanged line's call is not this change's reference"
    );
    assert_eq!(s.defs, set(["f".to_owned()]));
}

// ---------------------------------------------------------------------
// Splitting out contracts
// ---------------------------------------------------------------------

#[hegel::test(test_cases = 300)]
fn the_contract_part_takes_exactly_the_contracts(tc: TestCase) {
    let old_items = tc.draw(rust_items());
    let new_items = tc.draw(rust_items());
    let has_old = tc.draw(gs::booleans());
    let left = has_old.then(|| rust_source(&old_items, "    ", 1));
    let right = rust_source(&new_items, "    ", 1);
    // An absent part means the file does not exist in it.
    let part = contract_part("a.rs", left.as_deref(), Some(&right));
    let mid = part.clone().unwrap_or_default();
    let l = left.clone().unwrap_or_default();
    let first = file_symbols(&FileDiff {
        old_path: has_old.then(|| "a.rs".into()),
        new_path: part.is_some().then(|| "a.rs".into()),
        ..modified("a.rs", &l, &mid)
    });
    let second = file_symbols(&FileDiff {
        old_path: part.is_some().then(|| "a.rs".into()),
        ..modified("a.rs", &mid, &right)
    });
    let whole = file_symbols(&FileDiff {
        old_path: has_old.then(|| "a.rs".into()),
        ..modified("a.rs", &l, &right)
    });
    // The contract part defines only contracts, all of them new; it is what
    // the change's symbols say a split moves; the rest has no contract left
    // to move; and together they define everything the change did.
    let old_names: BTreeSet<String> = parse(Lang::Rust, &l)
        .items
        .into_iter()
        .map(|i| i.name)
        .collect();
    assert!(
        first.defs.is_subset(&first.contracts),
        "the contract part defines {:?}",
        first.defs
    );
    assert!(
        first.defs.is_disjoint(&old_names),
        "the contract part changes old items {:?}",
        first.defs.intersection(&old_names).collect::<Vec<_>>()
    );
    assert_eq!(first.defs, whole.hoisted, "\n{l}\n=>\n{mid}");
    assert!(
        second.hoisted.is_empty(),
        "the rest still has contracts to move {:?}",
        second.hoisted
    );
    assert!(
        whole
            .defs
            .is_subset(&first.defs.union(&second.defs).cloned().collect())
    );
}

#[hegel::test(test_cases = 300)]
fn the_contract_part_of_well_formed_files_is_well_formed(tc: TestCase) {
    let old_items = tc.draw(rust_items());
    let new_items = tc.draw(rust_items());
    let left = tc
        .draw(gs::booleans())
        .then(|| rust_source(&old_items, "    ", 1));
    let right = rust_source(
        &new_items,
        "    ",
        tc.draw(gs::integers::<usize>().max_value(2)),
    );
    if let Some(mid) = contract_part("a.rs", left.as_deref(), Some(&right)) {
        assert!(
            !has_syntax_errors(Lang::Rust, &mid),
            "the contract part does not parse:\n{mid}"
        );
    }
}

#[hegel::test(test_cases = 300)]
fn a_change_without_contracts_leaves_the_contract_part_empty(tc: TestCase) {
    let items = tc.draw(rust_items());
    let left = rust_source(&items, "    ", 1);
    let right = format!("{left}\npub fn extra() {{ g0(); }}\n");
    assert_eq!(
        contract_part("a.rs", Some(&left), Some(&right)).as_deref(),
        Some(left.as_str())
    );
}

fn shifted(it: &RustItem) -> RustItem {
    match it {
        RustItem::Trait(i) => RustItem::Trait(i + 100),
        RustItem::Struct(i) => RustItem::Struct(i + 100),
        RustItem::Fn { id, calls } => RustItem::Fn {
            id: id + 100,
            calls: calls.clone(),
        },
        RustItem::Impl { tr, ty } => RustItem::Impl {
            tr: tr + 100,
            ty: *ty,
        },
        RustItem::Const(i) => RustItem::Const(i + 100),
    }
}

#[hegel::test(test_cases = 300)]
fn the_cosmetic_part_defines_nothing_and_leaves_no_cosmetic_edit_behind(tc: TestCase) {
    let items = tc.draw(rust_items());
    let extra = tc.draw(rust_items());
    let indent = tc.draw(gs::sampled_from(vec!["  ", "    ", "\t"]));
    let gap = tc.draw(gs::integers::<usize>().max_value(2));
    let left = rust_source(&items, "    ", 1);
    let mut more = items.clone();
    more.extend(extra.iter().map(shifted));
    let right = rust_source(&more, indent, gap);
    let mid = cosmetic_part("a.rs", Some(&left), Some(&right)).expect("the file stays");
    assert!(
        !has_syntax_errors(Lang::Rust, &mid),
        "the cosmetic part does not parse:\n{mid}"
    );
    let first = file_symbols(&modified("a.rs", &left, &mid));
    let second = file_symbols(&modified("a.rs", &mid, &right));
    assert!(
        first.defs.is_empty(),
        "the cosmetic part defines {:?}",
        first.defs
    );
    assert!(
        second.cosmetic_files.is_empty(),
        "a cosmetic edit stayed behind"
    );
}

#[hegel::test(test_cases = 300)]
fn a_purely_cosmetic_change_moves_whole(tc: TestCase) {
    let items = tc.draw(rust_items());
    let indent = tc.draw(gs::sampled_from(vec!["  ", "\t"]));
    let left = rust_source(&items, "    ", 1);
    let right = rust_source(&items, indent, 1);
    assert_eq!(
        cosmetic_part("a.rs", Some(&left), Some(&right)).as_deref(),
        Some(right.as_str())
    );
}

#[hegel::test(test_cases = 100)]
fn files_jj_graph_cannot_read_stay_with_the_change(tc: TestCase) {
    let (old, new) = (tc.draw(texts()), tc.draw(texts()));
    assert_eq!(
        contract_part("notes.md", Some(&old), Some(&new)).as_deref(),
        Some(old.as_str())
    );
    assert_eq!(contract_part("notes.md", None, Some(&new)), None);
}

// ---------------------------------------------------------------------
// Reading diagrams and planning skeletons
// ---------------------------------------------------------------------

#[hegel::composite]
fn diagrams(tc: &TestCase, acyclic: bool) -> Diagram {
    let n = tc.draw(gs::integers::<usize>().min_value(1).max_value(6));
    let ids: Vec<String> = (0..n).map(|i| format!("N{i}")).collect();
    let mut d = Diagram::default();
    for (i, id) in ids.iter().enumerate() {
        let title = format!("feat: part {i} \"x\" & <y>");
        let body = tc.draw(gs::optional(gs::sampled_from(vec![
            "Implements Storage",
            "Wires it",
            "a <b> c",
        ])));
        let label = match body {
            Some(b) => format!("{title}\n{b}"),
            None => title,
        };
        d.labels.insert(id.clone(), label);
        d.order.push(id.clone());
    }
    for j in 0..n {
        for i in 0..n {
            let allowed = if acyclic { i < j } else { i != j };
            if allowed && tc.draw(gs::weighted_booleans(0.3)) {
                d.edges.insert((ids[i].clone(), ids[j].clone()));
            }
        }
    }
    d
}

#[hegel::test(test_cases = 300)]
fn a_rendered_diagram_reads_back_the_same(tc: TestCase) {
    let d = tc.draw(diagrams(false));
    assert_eq!(dot::parse(&dot::render(&d)).unwrap(), d);
}

#[hegel::test(test_cases = 300)]
fn equivalent_spellings_mean_the_same_edges(tc: TestCase) {
    let label = tc.draw(gs::sampled_from(vec!["uses", "wires", "x"]));
    let cluster = tc.draw(gs::sampled_from(vec!["cluster_parts", "parts", ""]));
    let spelled = [
        "digraph { A -> {B C} }".to_owned(),
        "digraph { A -> B; A -> C }".to_owned(),
        format!("strict digraph g {{\n  A -> B [label=\"{label}\"]\n  A -> C [label={label}]\n}}"),
        format!(
            "digraph {{\n  // a comment\n  /* and another */\n  A -> subgraph {cluster} {{ B; C }}\n}}"
        ),
        "digraph {\n  node [shape=box]\n  A [label=\"A\"]\n  A -> B\n  A -> C\n}".to_owned(),
    ];
    let edges: Vec<BTreeSet<(String, String)>> = spelled
        .iter()
        .map(|s| dot::parse(s).unwrap_or_else(|e| panic!("{s}: {e}")).edges)
        .collect();
    assert!(edges.iter().all(|e| *e == edges[0]), "{edges:?}");
    let chain = dot::parse("digraph { A -> B -> C }").unwrap();
    assert_eq!(
        chain.edges,
        set([
            ("A".to_owned(), "B".to_owned()),
            ("B".to_owned(), "C".to_owned())
        ])
    );
}

#[test]
fn undirected_graphs_self_loops_and_reserved_ids_are_refused() {
    assert!(dot::parse("graph { A -- B }").is_err());
    assert!(dot::parse("digraph { A -> A }").is_err());
    assert!(dot::parse("digraph { \"spec:x\" -> B }").is_err());
}

#[test]
fn labels_read_escapes_and_html_line_breaks() {
    let d = dot::parse(
        "digraph {\n  a [label=\"feat: engine\\nInjects \\\"Storage\\\"\"]\n  b [label=<feat: cli<br/>User &amp; Interface>]\n  a -> b\n}",
    )
    .unwrap();
    assert_eq!(d.labels["a"], "feat: engine\nInjects \"Storage\"");
    assert_eq!(d.labels["b"], "feat: cli\nUser & Interface");
}

#[hegel::test(test_cases = 500)]
fn reading_any_text_never_panics(tc: TestCase) {
    let text = tc.draw(gs::text().max_size(80));
    let _ = dot::parse(&text);
    let _ = dot::parse(&format!("digraph {{ {text} }}"));
    let _ = parse_git_diff(&text);
}

fn closure(edges: &BTreeSet<(String, String)>) -> BTreeSet<(String, String)> {
    let mut r = edges.clone();
    loop {
        let extra: Vec<(String, String)> = r
            .iter()
            .flat_map(|(x, y)| {
                r.iter()
                    .filter(move |(y2, _)| y2 == y)
                    .map(move |(_, z)| (x.clone(), z.clone()))
            })
            .filter(|p| !r.contains(p))
            .collect();
        if extra.is_empty() {
            return r;
        }
        r.extend(extra);
    }
}

#[hegel::test(test_cases = 300)]
fn a_skeleton_is_the_diagrams_transitive_reduction(tc: TestCase) {
    let d = tc.draw(diagrams(true));
    let s = skeleton::plan(&d, &[]).unwrap();
    let edges: BTreeSet<(String, String)> = s
        .parents
        .iter()
        .flat_map(|(n, ps)| ps.iter().map(move |p| (p.clone(), n.clone())))
        .collect();
    assert_eq!(closure(&edges), closure(&d.edges), "reachability changed");
    for (a, b) in &edges {
        let mut without = edges.clone();
        without.remove(&(a.clone(), b.clone()));
        assert!(
            !closure(&without).contains(&(a.clone(), b.clone())),
            "{a} --> {b} is implied by another path"
        );
    }
    assert_eq!(s.dropped, d.edges.difference(&edges).cloned().collect());
    let position: BTreeMap<&String, usize> =
        s.order.iter().enumerate().map(|(i, n)| (n, i)).collect();
    assert!(
        edges.iter().all(|(a, b)| position[a] < position[b]),
        "creation order puts a node before its parent"
    );
}

#[hegel::test(test_cases = 300)]
fn a_cyclic_diagram_is_refused(tc: TestCase) {
    let d = tc.draw(diagrams(false));
    let cyclic = closure(&d.edges).iter().any(|(x, y)| x == y);
    assert_eq!(skeleton::plan(&d, &[]).is_err(), cyclic);
}

// ---------------------------------------------------------------------
// Gherkin features in the skeleton
// ---------------------------------------------------------------------

#[derive(Clone, Debug)]
struct FeatureDraft {
    slug: String,
    tags: Vec<String>,
    scenarios: Vec<(Vec<String>, usize)>,
}

/// Up to three features over the diagram's nodes, each with up to four
/// scenarios whose `@needs` tags name diagram nodes.
#[hegel::composite]
fn feature_drafts(tc: &TestCase, nodes: Vec<String>) -> Vec<FeatureDraft> {
    let n = tc.draw(gs::integers::<usize>().min_value(1).max_value(3));
    (0..n)
        .map(|i| {
            let tags = tc.draw(gs::subsequences(nodes.clone()).max_size(1));
            let k = tc.draw(gs::integers::<usize>().min_value(1).max_value(4));
            let scenarios = (0..k)
                .map(|_| {
                    (
                        tc.draw(gs::subsequences(nodes.clone()).max_size(2)),
                        tc.draw(gs::integers::<usize>().max_value(2)),
                    )
                })
                .collect();
            FeatureDraft {
                slug: format!("f{i}"),
                tags,
                scenarios,
            }
        })
        .collect()
}

/// The feature as Gherkin, with `noise` comments and blank lines between
/// its parts.
fn gherkin_text(f: &FeatureDraft, noise: bool) -> String {
    let tags = |t: &[String]| {
        t.iter()
            .map(|n| format!("@needs:{n}"))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let extra = if noise { "\n  # a comment\n\n" } else { "\n" };
    let mut out = String::new();
    if !f.tags.is_empty() {
        out.push_str(&format!("{}\n", tags(&f.tags)));
    }
    out.push_str(&format!("Feature: Feature {}\n", f.slug));
    for (i, (needs, steps)) in f.scenarios.iter().enumerate() {
        out.push_str(extra);
        if !needs.is_empty() {
            out.push_str(&format!("  {}\n", tags(needs)));
        }
        out.push_str(&format!("  Scenario: Case {i}\n"));
        for j in 0..*steps {
            out.push_str(&format!("    Given step {j}\n"));
        }
    }
    out
}

fn read_drafts(drafts: &[FeatureDraft], noise: bool) -> Vec<jj_graph::gherkin::FeatureSpec> {
    drafts
        .iter()
        .map(|f| {
            jj_graph::gherkin::read_feature(
                &format!("features/{}.feature", f.slug),
                &gherkin_text(f, noise),
            )
            .unwrap()
        })
        .collect()
}

#[hegel::test(test_cases = 300)]
fn comments_and_blank_lines_do_not_change_a_feature(tc: TestCase) {
    let d = tc.draw(diagrams(true));
    let drafts = tc.draw(feature_drafts(d.order.clone()));
    assert_eq!(read_drafts(&drafts, false), read_drafts(&drafts, true));
}

#[hegel::test(test_cases = 300)]
fn every_feature_and_scenario_becomes_one_change(tc: TestCase) {
    let d = tc.draw(diagrams(true));
    let drafts = tc.draw(feature_drafts(d.order.clone()));
    let features = read_drafts(&drafts, false);
    let s = skeleton::plan(&d, &features).unwrap();
    let mut want: BTreeSet<String> = d.order.iter().cloned().collect();
    for f in &features {
        want.insert(skeleton::spec_node(f));
        want.extend((0..f.scenarios.len()).map(|i| skeleton::scenario_node(f, i)));
    }
    assert_eq!(s.parents.keys().cloned().collect::<BTreeSet<_>>(), want);
}

#[hegel::test(test_cases = 300)]
fn specs_are_roots_and_each_scenario_sits_on_its_spec(tc: TestCase) {
    let d = tc.draw(diagrams(true));
    let features = read_drafts(&tc.draw(feature_drafts(d.order.clone())), false);
    let s = skeleton::plan(&d, &features).unwrap();
    for f in &features {
        assert!(s.parents[&skeleton::spec_node(f)].is_empty());
        for i in 0..f.scenarios.len() {
            assert!(s.parents[&skeleton::scenario_node(f, i)].contains(&skeleton::spec_node(f)));
        }
    }
}

#[hegel::test(test_cases = 300)]
fn scenarios_descend_from_exactly_what_they_need(tc: TestCase) {
    let d = tc.draw(diagrams(true));
    let features = read_drafts(&tc.draw(feature_drafts(d.order.clone())), false);
    let s = skeleton::plan(&d, &features).unwrap();
    let planned: BTreeSet<(String, String)> = s
        .parents
        .iter()
        .flat_map(|(n, ps)| ps.iter().map(move |p| (p.clone(), n.clone())))
        .collect();
    let reach = closure(&planned);
    let sinks = skeleton::sinks(&d);
    let below_diagram = &closure(&d.edges);
    for f in &features {
        for (i, sc) in f.scenarios.iter().enumerate() {
            let node = skeleton::scenario_node(f, i);
            let needs = if sc.needs.is_empty() {
                &sinks
            } else {
                &sc.needs
            };
            // Every component it needs is below it, and every component
            // below it is one it needs or one those build on.
            let below: BTreeSet<String> = d
                .order
                .iter()
                .filter(|c| reach.contains(&((*c).clone(), node.clone())))
                .cloned()
                .collect();
            let want: BTreeSet<String> = needs
                .iter()
                .flat_map(|n| {
                    d.order.iter().filter(move |c| {
                        *c == n || below_diagram.contains(&((*c).clone(), n.clone()))
                    })
                })
                .cloned()
                .collect();
            assert_eq!(below, want, "{node}");
        }
    }
}

#[hegel::test(test_cases = 100)]
fn needs_naming_a_missing_node_are_refused(tc: TestCase) {
    let d = tc.draw(diagrams(true));
    let mut drafts = tc.draw(feature_drafts(d.order.clone()));
    drafts[0].scenarios[0].0.push("Missing".into());
    assert!(skeleton::plan(&d, &read_drafts(&drafts, false)).is_err());
}

// ---------------------------------------------------------------------
// Merge leaks
// ---------------------------------------------------------------------

#[hegel::test(test_cases = 300)]
fn a_leak_is_a_private_symbol_of_a_joined_branch_the_merge_references(tc: TestCase) {
    let n = tc.draw(gs::integers::<usize>().min_value(1).max_value(6));
    let names: Vec<Id> = (0..n).map(|i| format!("c{i}")).collect();
    let symbols = ["p", "q", "r"];
    let mut g = Graph {
        bases: set(["b".to_owned()]),
        ..Graph::default()
    };
    let mut private: BTreeMap<Id, BTreeSet<String>> = BTreeMap::new();
    for (i, v) in names.iter().enumerate() {
        let mut ps: BTreeSet<Id> = set(tc.draw(gs::subsequences(names[..i].to_vec()).max_size(3)));
        if ps.is_empty() {
            ps.insert("b".into());
        }
        g.parents.insert(v.clone(), ps);
        let refs = set(tc.draw(gs::subsequences(
            symbols.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        )));
        g.info.insert(
            v.clone(),
            Change {
                refs,
                ..Change::default()
            },
        );
        private.insert(
            v.clone(),
            set(tc.draw(gs::subsequences(
                symbols.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            ))),
        );
    }
    let found: BTreeSet<(Id, Id, BTreeSet<String>)> = leaks(&g, &private)
        .into_iter()
        .map(|l| (l.merge, l.from, l.symbols))
        .collect();
    // The definition, by brute force: for a merge, a change that is in the
    // lineage of some of its in-scope parents but not of all.
    let a = g.ancestry();
    let lineage = |v: &Id| -> BTreeSet<Id> {
        let mut l: BTreeSet<Id> = a
            .preds(v)
            .into_iter()
            .filter(|u| g.parents.contains_key(u))
            .collect();
        l.insert(v.clone());
        l
    };
    let mut want = BTreeSet::new();
    for (m, ps) in &g.parents {
        let inner: Vec<&Id> = ps.iter().filter(|p| g.parents.contains_key(*p)).collect();
        if inner.len() < 2 {
            continue;
        }
        for u in &names {
            let inside = inner.iter().filter(|p| lineage(p).contains(u)).count();
            if inside > 0 && inside < inner.len() {
                let used: BTreeSet<String> =
                    g.info[m].refs.intersection(&private[u]).cloned().collect();
                if !used.is_empty() {
                    want.insert((m.clone(), u.clone(), used));
                }
            }
        }
    }
    assert_eq!(found, want);
}
