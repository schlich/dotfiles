//! Splitting a change, across the languages jj-graph reads: a part parses,
//! moves exactly what it is meant to, and leaves nothing it could move
//! behind; the diff editor lays out a plan, symlinks and permissions kept.

mod common;

use std::collections::BTreeSet;

use common::{Drawn, LANGUAGES, Language, file, files};
use hegel::TestCase;
use hegel::generators as gs;
use jj_graph::diff::FileDiff;
use jj_graph::extract::{Kind, Lang, Symbols, file_symbols, has_syntax_errors, parse};
use jj_graph::hoist::{Plan, apply_plan, contract_part, cosmetic_part};

fn symbols(path: &str, old: &str, new: &str) -> Symbols {
    file_symbols(&FileDiff {
        old_path: Some(path.into()),
        new_path: Some(path.into()),
        old: old.into(),
        new: new.into(),
        ..FileDiff::default()
    })
}

/// A change to a generated file: each old item kept, reformatted (its first
/// space doubled), changed, or removed, and up to two new items put
/// anywhere.
#[hegel::composite]
fn edits(tc: &TestCase, lang: usize, items: Vec<Drawn>) -> Vec<Drawn> {
    let mut out = Vec::new();
    for d in &items {
        match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => out.push(*d),
            1 => out.push(Drawn { spaced: true, ..*d }),
            2 => out.push(Drawn {
                value: 3 - d.value,
                ..*d
            }),
            _ => {}
        }
    }
    let n = tc.draw(gs::integers::<usize>().max_value(2));
    for k in 0..n {
        let at = tc.draw(gs::integers::<usize>().max_value(out.len()));
        let template =
            tc.draw(gs::integers::<usize>().max_value(LANGUAGES[lang].templates.len() - 1));
        let spaced = tc.draw(gs::booleans());
        out.insert(
            at,
            Drawn {
                template,
                index: 10 + k,
                value: 1,
                spaced,
            },
        );
    }
    out
}

fn items(code: Lang, text: &str) -> BTreeSet<(String, Kind, u64)> {
    parse(code, text)
        .items
        .into_iter()
        .map(|i| (i.name, i.kind, i.fingerprint))
        .collect()
}

#[hegel::test(test_cases = 300)]
fn the_contract_part_moves_exactly_the_new_contracts(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang: &Language = &LANGUAGES[l];
    let code = Lang::of_path(lang.path).unwrap();
    let before = tc.draw(files(l));
    let after = tc.draw(edits(l, before.clone()));
    let (left, right) = (file(lang, &before), file(lang, &after));
    let mid = contract_part(lang.path, Some(&left), Some(&right)).unwrap();
    let shown = format!("{left}\n=>\n{right}\n\npart:\n{mid}");
    assert!(!has_syntax_errors(code, &mid), "{shown}");
    // The part holds the old items as they were, and the new contracts.
    let (left_items, mid_items) = (items(code, &left), items(code, &mid));
    assert!(left_items.is_subset(&mid_items), "{shown}");
    let added: BTreeSet<String> = mid_items
        .difference(&left_items)
        .map(|(name, _, _)| name.clone())
        .collect();
    let new_contracts: BTreeSet<String> = after
        .iter()
        .filter(|d| d.index >= 10 && d.contract(lang))
        .map(|d| d.name(lang))
        .collect();
    assert_eq!(added, new_contracts, "{shown}");
    // The change's symbols say as much, and nothing more would move.
    assert_eq!(
        symbols(lang.path, &left, &right).hoisted,
        symbols(lang.path, &left, &mid).defs,
        "{shown}"
    );
    assert!(
        symbols(lang.path, &mid, &right).hoisted.is_empty(),
        "{shown}"
    );
    assert_eq!(
        contract_part(lang.path, Some(&mid), Some(&right)).as_deref(),
        Some(mid.as_str()),
        "{shown}"
    );
}

#[hegel::test(test_cases = 300)]
fn the_cosmetic_part_moves_exactly_the_reformatting(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang: &Language = &LANGUAGES[l];
    let code = Lang::of_path(lang.path).unwrap();
    let before = tc.draw(files(l));
    let after = tc.draw(edits(l, before.clone()));
    let (left, right) = (file(lang, &before), file(lang, &after));
    let mid = cosmetic_part(lang.path, Some(&left), Some(&right)).unwrap();
    let shown = format!("{left}\n=>\n{right}\n\npart:\n{mid}");
    assert!(!has_syntax_errors(code, &mid), "{shown}");
    assert!(symbols(lang.path, &left, &mid).defs.is_empty(), "{shown}");
    // Every old item only reformatted has its new text.
    for d in after.iter().filter(|d| {
        d.spaced
            && before.contains(&Drawn {
                spaced: false,
                ..**d
            })
    }) {
        assert!(mid.contains(&d.text(lang)), "{}: {shown}", d.name(lang));
    }
    assert!(
        symbols(lang.path, &mid, &right).cosmetic_files.is_empty(),
        "{shown}"
    );
}

// ---------------------------------------------------------------------
// The splits the adversarial review broke
// ---------------------------------------------------------------------

fn part(path: &str, old: &str, new: &str) -> String {
    let code = Lang::of_path(path).unwrap();
    let mid = contract_part(path, Some(old), Some(new)).unwrap();
    assert!(!has_syntax_errors(code, &mid), "{mid}");
    mid
}

#[test]
fn imports_over_several_lines_stay_whole_and_new_names_get_imports_of_their_own() {
    let mid = part(
        "a.py",
        "from typing import (\n    Protocol,\n)\n\n\nclass Impl:\n    pass\n",
        "from typing import (\n    Any,\n    Protocol,\n)\n\n\nclass Impl:\n    pass\n\n\nclass P(Protocol):\n    def m(self) -> Any: ...\n",
    );
    assert!(
        mid.contains("from typing import Any\n") && mid.contains("class P(Protocol)"),
        "{mid}"
    );
    let mid = part(
        "src/x.rs",
        "use a::{\n    B,\n};\n\nfn f(b: B) {}\n",
        "use a::{\n    B,\n    D,\n};\n\nfn f(b: B) {}\n\npub trait T {\n    fn d(&self) -> D;\n}\n",
    );
    assert!(
        mid.contains("use a::D;") && mid.contains("pub trait T"),
        "{mid}"
    );
    assert_eq!(mid.matches("B,").count(), 1, "{mid}");
    let mid = part(
        "a.go",
        "package a\n\nimport (\n\t\"fmt\"\n)\n\nfunc F() { fmt.Println() }\n",
        "package a\n\nimport (\n\t\"fmt\"\n\t\"io\"\n\t\"os\"\n)\n\nfunc F() { fmt.Println(); os.Exit(0) }\n\ntype R interface {\n\tRead() io.Reader\n}\n",
    );
    // Go refuses an import nothing uses: only what the contract uses moves.
    assert!(
        mid.contains("import \"io\"") && !mid.contains("\"os\""),
        "{mid}"
    );
    let mid = part(
        "a.ts",
        "import {\n  a,\n} from './a';\n\nexport function f() { return a; }\n",
        "import {\n  a,\n  B,\n} from './a';\n\nexport function f() { return a; }\n\nexport interface I {\n  b: B;\n}\n",
    );
    assert!(mid.contains("import { B } from './a';"), "{mid}");
}

#[test]
fn a_go_file_without_imports_gets_them_below_its_package_clause() {
    let mid = part(
        "a.go",
        "package a\n\nfunc F() {}\n",
        "package a\n\nimport \"io\"\n\nfunc F() {}\n\ntype R interface {\n\tRead() io.Reader\n}\n",
    );
    assert!(mid.starts_with("package a\n"), "{mid}");
    assert!(mid.contains("import \"io\""), "{mid}");
}

#[test]
fn a_module_only_the_implementation_uses_stays_behind() {
    let mid = part(
        "src/lib.rs",
        "pub fn f() {}\n",
        "mod util;\n\npub fn f() {\n    util::g();\n}\n\npub trait T {}\n",
    );
    assert!(
        !mid.contains("mod util") && mid.contains("pub trait T"),
        "{mid}"
    );
}

#[test]
fn overloads_and_contracts_inside_implementations_stay_with_them() {
    let old = "export function f(a: string): void;\nexport function f(a: any) {}\n";
    let new = "export function f(a: number): void;\nexport function f(a: string): void;\nexport function f(a: any) {}\n";
    assert_eq!(
        contract_part("a.ts", Some(old), Some(new)).as_deref(),
        Some(old)
    );
    let old = "pub struct Item;\n\nstruct It;\n";
    let new = "pub struct Item;\n\nstruct It;\n\nimpl Iterator for It {\n    type Item = Item;\n    fn next(&mut self) -> Option<Item> {\n        None\n    }\n}\n";
    assert_eq!(
        contract_part("src/a.rs", Some(old), Some(new)).as_deref(),
        Some(old)
    );
}

#[test]
fn items_on_one_line_split_item_by_item() {
    let mid = part(
        "src/a.rs",
        "struct A; fn f() {}\n",
        "struct A; fn f() {}\nfn g() {}\npub trait T {}\n",
    );
    assert!(
        mid.contains("struct A; fn f() {}") && mid.contains("pub trait T {}"),
        "{mid}"
    );
    assert!(!mid.contains("fn g"), "{mid}");
    let old = "fn a() {} fn b() -> u8 { 1 }\n";
    let new = "fn a()  {} fn b() -> u8 { 2 }\n";
    assert_eq!(
        cosmetic_part("src/a.rs", Some(old), Some(new)).as_deref(),
        Some("fn a()  {} fn b() -> u8 { 1 }\n")
    );
}

#[test]
fn a_new_python_protocol_goes_in_at_the_top_level() {
    let old = "class Impl:\n    def a(self):\n        pass\n\n    x = 1\n";
    let mid = part(
        "a.py",
        old,
        "class Impl:\n    def a(self):\n        pass\n\n    x = 1\n\n\nclass P(Protocol):\n    def m(self) -> int: ...\n",
    );
    assert!(
        mid.starts_with(old) && mid.contains("\nclass P(Protocol):"),
        "{mid}"
    );
}

#[test]
fn a_new_nix_option_goes_into_the_set_the_module_has_for_it() {
    let old = "{ lib, ... }:\n{\n  options = {\n    a = lib.mkOption { };\n  };\n  config = {\n    x = 1;\n  };\n}\n";
    let new = "{ lib, ... }:\n{\n  options = {\n    a = lib.mkOption { };\n    b = lib.mkOption { };\n  };\n  config = {\n    x = 1;\n    y = 2;\n  };\n}\n";
    let mid = part("m.nix", old, new);
    let s = symbols("m.nix", old, &mid);
    assert_eq!(s.defs, BTreeSet::from(["b".to_owned()]), "{mid}");
    assert_eq!(s.contracts, s.defs, "{mid}");
    // Into an empty set, and a whole new set at the top level.
    let old = "{ lib, ... }:\n{\n  options = { };\n  config.x = 1;\n}\n";
    let new = "{ lib, ... }:\n{\n  options = { b = lib.mkOption { }; };\n  config.x = 2;\n}\n";
    assert_eq!(
        symbols("m.nix", old, &part("m.nix", old, new)).contracts,
        BTreeSet::from(["b".to_owned()])
    );
    let old = "{ lib, ... }:\n{\n  config.x = 1;\n}\n";
    let new =
        "{ lib, ... }:\n{\n  config.x = 2;\n  options = {\n    b = lib.mkOption { };\n  };\n}\n";
    assert_eq!(
        symbols("m.nix", old, &part("m.nix", old, new)).contracts,
        BTreeSet::from(["b".to_owned()])
    );
}

fn diff(path: &str, old: Option<&str>, new: &str) -> FileDiff {
    FileDiff {
        old_path: old.map(|_| path.into()),
        new_path: Some(path.into()),
        old: old.unwrap_or_default().into(),
        new: new.into(),
        ..FileDiff::default()
    }
}

#[test]
fn a_new_rust_module_moves_with_its_declaration() {
    let store = "pub trait Storage {\n    fn get(&self) -> u8;\n}\n\npub struct Db;\n\nimpl Storage for Db {\n    fn get(&self) -> u8 {\n        1\n    }\n}\n";
    let lib_old = "pub fn run() {}\n";
    let lib_new = "mod store;\n\npub fn run() {\n    store::Db.get();\n}\n";
    let files = [
        diff("src/store.rs", None, store),
        diff("src/lib.rs", Some(lib_old), lib_new),
    ];
    let plan = jj_graph::hoist::plan(&files, jj_graph::hoist::Split::Contracts);
    assert!(
        plan["src/store.rs"].contains("pub trait Storage"),
        "{plan:?}"
    );
    assert!(!plan["src/store.rs"].contains("impl Storage"), "{plan:?}");
    assert_eq!(plan["src/lib.rs"], "mod store;\n\npub fn run() {}\n");
    let s = jj_graph::extract::change_symbols(&files);
    assert_eq!(
        s.cfiles,
        BTreeSet::from(["src/lib.rs".to_owned(), "src/store.rs".to_owned()])
    );
    // A module whose declaring file is new too cannot exist without it.
    let files = [
        diff("src/store.rs", None, store),
        diff("src/lib.rs", None, lib_new),
    ];
    let plan = jj_graph::hoist::plan(&files, jj_graph::hoist::Split::Contracts);
    assert!(!plan.contains_key("src/store.rs"), "{plan:?}");
}

#[test]
fn applying_a_plan_keeps_symlinks_and_permissions() {
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    let (left, right) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (l, r) = (left.path(), right.path());
    fs::write(l.join("a.rs"), "old a").unwrap();
    fs::set_permissions(l.join("a.rs"), fs::Permissions::from_mode(0o755)).unwrap();
    symlink("a.rs", l.join("link")).unwrap();
    fs::create_dir(l.join("dir")).unwrap();
    fs::write(l.join("dir/b.rs"), "old b").unwrap();
    fs::write(l.join("gone.rs"), "gone").unwrap();
    // The change edits a.rs and drops its mode, turns the link into a file,
    // edits b.rs, adds new.rs, and deletes gone.rs.
    fs::write(r.join("a.rs"), "new a").unwrap();
    fs::set_permissions(r.join("a.rs"), fs::Permissions::from_mode(0o644)).unwrap();
    fs::write(r.join("link"), "not a link").unwrap();
    fs::create_dir(r.join("dir")).unwrap();
    fs::write(r.join("dir/b.rs"), "new b").unwrap();
    fs::write(r.join("new.rs"), "new").unwrap();
    let plan: Plan = [
        ("dir/b.rs".to_owned(), "planned b".to_owned()),
        ("new.rs".to_owned(), "planned new".to_owned()),
    ]
    .into();
    apply_plan(&plan, l, r).unwrap();
    assert_eq!(fs::read_to_string(r.join("a.rs")).unwrap(), "old a");
    assert_eq!(
        fs::metadata(r.join("a.rs")).unwrap().permissions().mode() & 0o777,
        0o755
    );
    assert_eq!(
        fs::read_link(r.join("link")).unwrap().to_str(),
        Some("a.rs")
    );
    assert_eq!(fs::read_to_string(r.join("dir/b.rs")).unwrap(), "planned b");
    assert_eq!(fs::read_to_string(r.join("new.rs")).unwrap(), "planned new");
    assert_eq!(fs::read_to_string(r.join("gone.rs")).unwrap(), "gone");
}
