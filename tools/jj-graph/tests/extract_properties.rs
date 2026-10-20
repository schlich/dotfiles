//! What a change defines, across the languages jj-graph reads: files made
//! of item templates, edited the ways a change edits them.

mod common;

use std::collections::BTreeSet;

use common::{Drawn, LANGUAGES, Language, file, files};
use hegel::TestCase;
use hegel::generators as gs;
use jj_graph::diff::FileDiff;
use jj_graph::extract::{
    Lang, Piece, Symbols, file_symbols, has_syntax_errors, parse, piece_edit, pieces,
};

fn symbols(lang: &Language, old: &str, new: &str) -> Symbols {
    let diff = FileDiff {
        old_path: Some(lang.path.to_owned()),
        new_path: Some(lang.path.to_owned()),
        old: old.to_owned(),
        new: new.to_owned(),
        ..FileDiff::default()
    };
    file_symbols(&diff)
}

fn defs(lang: &Language, old: &str, new: &str) -> BTreeSet<String> {
    symbols(lang, old, new).defs
}

fn uses(lang: &Language, old: &str, new: &str) -> BTreeSet<String> {
    symbols(lang, old, new).refs
}

/// What an item uses on its own: what adding it to an empty file adds.
fn own_uses(lang: &Language, item: &Drawn) -> BTreeSet<String> {
    uses(lang, &file(lang, &[]), &file(lang, &[*item]))
}

#[hegel::test(test_cases = 300)]
fn generated_files_parse_and_every_item_is_read(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let items = tc.draw(files(l));
    let text = file(lang, &items);
    let code = Lang::of_path(lang.path).unwrap();
    assert!(!has_syntax_errors(code, &text), "{text}");
    let read: BTreeSet<String> = parse(code, &text)
        .items
        .into_iter()
        .map(|i| i.name)
        .collect();
    for d in &items {
        assert!(
            read.contains(&d.name(lang)),
            "{} in\n{text}\n{read:?}",
            d.name(lang)
        );
    }
}

#[hegel::test(test_cases = 300)]
fn moving_reformatting_or_commenting_defines_and_uses_nothing(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let items = tc.draw(files(l));
    let text = file(lang, &items);
    // Moved, each item maybe reformatted (its first space doubled), and
    // maybe under a comment.
    let mut moved = tc.draw(gs::permutations(items.clone()));
    for d in &mut moved {
        d.spaced = tc.draw(gs::booleans());
    }
    let mut edited = file(lang, &moved);
    if tc.draw(gs::booleans()) {
        edited = format!("{}{edited}", lang.comment);
    }
    for (old, new) in [(&text, &text), (&text, &edited)] {
        let s = symbols(lang, old, new);
        assert_eq!(s.defs, BTreeSet::new(), "{old}\n=>\n{new}");
        assert_eq!(s.refs, BTreeSet::new(), "{old}\n=>\n{new}");
    }
}

#[hegel::test(test_cases = 300)]
fn an_added_item_uses_what_it_uses_on_its_own(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let items = tc.draw(files(l));
    let new = Drawn {
        template: tc.draw(gs::integers::<usize>().max_value(lang.templates.len() - 1)),
        index: 9,
        value: 1,
        spaced: false,
    };
    let mut more = items.clone();
    more.insert(tc.draw(gs::integers::<usize>().max_value(items.len())), new);
    let (text, more_text) = (file(lang, &items), file(lang, &more));
    assert_eq!(
        uses(lang, &text, &more_text),
        own_uses(lang, &new),
        "{text}\n=>\n{more_text}"
    );
}

#[hegel::test(test_cases = 300)]
fn a_changed_item_uses_only_what_its_new_version_holds(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let items = tc.draw(files(l));
    let k = tc.draw(gs::integers::<usize>().max_value(items.len() - 1));
    let mut changed = items.clone();
    changed[k].value = 3 - changed[k].value;
    changed[k].spaced = tc.draw(gs::booleans());
    let (text, changed_text) = (file(lang, &items), file(lang, &changed));
    let added = uses(lang, &text, &changed_text);
    assert!(
        added.is_subset(&own_uses(lang, &changed[k])),
        "{added:?}\n{text}\n=>\n{changed_text}"
    );
}

#[hegel::test(test_cases = 300)]
fn changing_or_renaming_an_item_defines_it(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let items = tc.draw(files(l));
    let k = tc.draw(gs::integers::<usize>().max_value(items.len() - 1));
    let text = file(lang, &items);
    let mut changed = items.clone();
    changed[k].value = 3 - changed[k].value;
    let changed_text = file(lang, &changed);
    let d = defs(lang, &text, &changed_text);
    assert!(
        d.contains(&items[k].name(lang)),
        "{d:?}\n{text}\n=>\n{changed_text}"
    );
    let mut renamed = items.clone();
    renamed[k].index = 9;
    let renamed_text = file(lang, &renamed);
    let d = defs(lang, &text, &renamed_text);
    assert!(
        d.contains(&items[k].name(lang)) && d.contains(&renamed[k].name(lang)),
        "{d:?}\n{text}\n=>\n{renamed_text}"
    );
}

#[hegel::test(test_cases = 300)]
fn what_a_change_defines_does_not_depend_on_its_direction(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let (x, y) = (
        file(lang, &tc.draw(files(l))),
        file(lang, &tc.draw(files(l))),
    );
    assert_eq!(defs(lang, &x, &y), defs(lang, &y, &x), "{x}\n<=>\n{y}");
}

// ---------------------------------------------------------------------
// Pieces: an edit item by item, as mergiraf's merges are judged
// ---------------------------------------------------------------------

#[hegel::test(test_cases = 300)]
fn moving_or_reformatting_keeps_every_piece_and_a_comment_is_one(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let code = Lang::of_path(lang.path).unwrap();
    let items = tc.draw(files(l));
    let text = file(lang, &items);
    let mut moved = tc.draw(gs::permutations(items.clone()));
    for d in &mut moved {
        d.spaced = tc.draw(gs::booleans());
    }
    let moved_text = file(lang, &moved);
    assert_eq!(
        pieces(code, &text),
        pieces(code, &moved_text),
        "{text}\n=>\n{moved_text}"
    );
    let commented = format!("{}{moved_text}", lang.comment);
    assert_eq!(
        piece_edit(code, Some(&text), Some(&commented)),
        Some((
            Vec::new(),
            vec![Piece::Comment(lang.comment.trim_end().to_owned())]
        )),
        "{text}\n=>\n{commented}"
    );
}

/// Changing one item's value removes one piece and adds one, both that
/// item, or an item inside it, under the same name; the other items' edits
/// do not change it.
#[hegel::test(test_cases = 300)]
fn changing_an_item_changes_one_piece_whatever_else_changed(tc: TestCase) {
    let l = tc.draw(gs::integers::<usize>().max_value(LANGUAGES.len() - 1));
    let lang = &LANGUAGES[l];
    let code = Lang::of_path(lang.path).unwrap();
    let items = tc.draw(files(l));
    let k = tc.draw(gs::integers::<usize>().max_value(items.len() - 1));
    let mut changed = items.clone();
    changed[k].value = 3 - changed[k].value;
    let edit = piece_edit(code, Some(&file(lang, &items)), Some(&file(lang, &changed)))
        .expect("generated files parse");
    let ([Piece::Item(was, _)], [Piece::Item(is, _)]) = (edit.0.as_slice(), edit.1.as_slice())
    else {
        panic!("{edit:?}");
    };
    assert_eq!(was, is);
    // The same edit on top of edits to the other items, with the items in
    // another order: the same pieces.
    let mut others = items.clone();
    for (j, d) in others.iter_mut().enumerate() {
        if j != k && tc.draw(gs::booleans()) {
            d.value = 3 - d.value;
        }
    }
    let mut others_changed = others.clone();
    others_changed[k] = changed[k];
    let order = tc.draw(gs::permutations((0..items.len()).collect::<Vec<_>>()));
    let reorder = |ds: &[Drawn]| -> Vec<Drawn> { order.iter().map(|&i| ds[i]).collect() };
    let elsewhere = piece_edit(
        code,
        Some(&file(lang, &reorder(&others))),
        Some(&file(lang, &reorder(&others_changed))),
    );
    assert_eq!(elsewhere, Some(edit));
}

#[test]
fn a_method_added_to_one_impl_is_the_same_edit_wherever_it_lands() {
    let code = Lang::Rust;
    let one = (
        "pub struct Db;\nimpl Db {\n    fn a() {}\n}\n",
        "pub struct Db;\nimpl Db {\n    fn a() {}\n    fn b() {}\n}\n",
    );
    // Another change added `c` first, and mergiraf put `b` above it.
    let other = (
        "pub struct Db;\nimpl Db {\n    fn a() {}\n    fn c() {}\n}\n",
        "pub struct Db;\nimpl Db {\n    fn a() {}\n    fn b() {}\n    fn c() {}\n}\n",
    );
    let edit = piece_edit(code, Some(one.0), Some(one.1)).unwrap();
    assert!(edit.0.is_empty());
    assert!(matches!(edit.1.as_slice(), [Piece::Item(name, _)] if name == "b"));
    assert_eq!(piece_edit(code, Some(other.0), Some(other.1)), Some(edit));
    // Changing the impl's header is an edit of its own.
    let header = piece_edit(
        code,
        Some(one.1),
        Some(&one.1.replace("impl Db", "impl<T> Db")),
    )
    .unwrap();
    assert!(matches!(
        (header.0.as_slice(), header.1.as_slice()),
        ([Piece::Unit(_)], [Piece::Unit(_)])
    ));
}

#[test]
fn a_comment_edit_is_an_edit_and_a_broken_file_has_no_pieces() {
    let code = Lang::Rust;
    assert_eq!(
        piece_edit(
            code,
            Some("// old\nfn f() {}\n"),
            Some("// new\nfn f() {}\n")
        ),
        Some((
            vec![Piece::Comment("// old".into())],
            vec![Piece::Comment("// new".into())]
        ))
    );
    assert_eq!(pieces(code, "fn f( {}\n"), None);
    assert_eq!(
        piece_edit(code, Some("fn f() {}\n"), Some("fn f( {}\n")),
        None
    );
}

// ---------------------------------------------------------------------
// The edits the adversarial review found unseen
// ---------------------------------------------------------------------

fn defs_at(path: &str, old: &str, new: &str) -> BTreeSet<String> {
    let lang = LANGUAGES.iter().find(|l| l.path == path).unwrap();
    defs(lang, old, new)
}

fn names(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

#[test]
fn dedenting_a_python_statement_out_of_a_block_redefines_its_function() {
    let old = "def f():\n    if x:\n        a()\n        c()\n";
    let new = "def f():\n    if x:\n        a()\n    c()\n";
    assert_eq!(defs_at("a.py", old, new), names(&["f"]));
}

#[test]
fn a_hole_in_an_array_is_not_a_trailing_comma() {
    assert_eq!(
        defs_at("a.js", "const x = [b];\n", "const x = [, b];\n"),
        names(&["x"])
    );
    assert_eq!(
        defs_at("a.js", "const x = [b];\n", "const x = [b,];\n"),
        names(&[])
    );
}

#[test]
fn export_and_const_belong_to_the_item() {
    assert_eq!(
        defs_at("a.ts", "function f() {}\n", "export function f() {}\n"),
        names(&["f"])
    );
    assert_eq!(
        defs_at("a.js", "const x = 1;\n", "let x = 1;\n"),
        names(&["x"])
    );
    assert_eq!(
        defs_at(
            "a.js",
            "function f() {}\n",
            "function f() {}\nexport { f };\n"
        ),
        names(&["f"])
    );
}

#[test]
fn a_nix_module_under_a_comment_or_with_lib_has_items() {
    for header in ["# A module.\n{ lib, ... }:\n", "{ lib, ... }:\nwith lib;\n"] {
        let old = format!("{header}{{\n  options.a = mkOption {{ }};\n}}\n");
        let new = format!("{header}{{\n  options.a = mkOption {{ default = 1; }};\n}}\n");
        assert_eq!(defs_at("module.nix", &old, &new), names(&["a"]), "{old}");
    }
}

fn uses_at(path: &str, old: &str, new: &str) -> BTreeSet<String> {
    let lang = LANGUAGES.iter().find(|l| l.path == path).unwrap();
    uses(lang, old, new)
}

#[test]
fn a_change_uses_only_what_it_inserts() {
    // A moved function, a new parameter, and a reformatted body: only the
    // parameter is a new use, though a line diff sees every line as new.
    let old = "pub trait Storage {\n    fn get(&self, key: u8) -> u8;\n}\n\npub fn open(path: &str) -> u8 { helper(path) }\n\nfn helper(p: &str) -> u8 {\n    p.len() as u8\n}\n";
    let new = "fn helper(p: &str) -> u8 {\n    p.len() as u8\n}\n\npub trait Storage {\n    fn get(&self, key: u8, fallback: u8) -> u8;\n}\n\npub fn open(path: &str) -> u8 {\n    helper(path)\n}\n";
    assert_eq!(uses_at("src/a.rs", old, new), names(&["fallback"]));
}

#[test]
fn another_use_of_a_name_an_item_already_uses_is_a_use() {
    // Each inserted use counts, so the change still needs what `a` names
    // wherever it moves.
    let old = "fn f() {\n    a();\n}\n";
    let new = "fn f() {\n    a();\n    b();\n    a();\n}\n";
    assert_eq!(uses_at("src/a.rs", old, new), names(&["a", "b"]));
}

#[test]
fn a_use_outside_every_unit_counts_by_line() {
    let old = "{ lib, ... }:\nlet\n  x = 1;\nin\n{\n  y = x;\n}\n";
    let new = "{ lib, ... }:\nlet\n  x = lib.z;\nin\n{\n  y = x;\n}\n";
    let added = uses_at("module.nix", old, new);
    assert!(added.contains("lib.z") && !added.contains("x"), "{added:?}");
}

#[test]
fn an_item_made_public_is_no_longer_private() {
    let diff = FileDiff {
        old_path: Some("src/a.rs".into()),
        new_path: Some("src/a.rs".into()),
        old: "fn helper() {}\n".into(),
        new: "pub fn helper() {}\n".into(),
        ..FileDiff::default()
    };
    let s = file_symbols(&diff);
    assert_eq!(s.defs, names(&["helper"]));
    assert!(s.private.is_empty(), "{:?}", s.private);
}
