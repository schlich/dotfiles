//! Splitting a change: moving part of it into a new change before it.
//!
//! jj-graph is its own diff editor here. `jj squash --from v -B v --tool
//! jj-graph-split` gives it the change's parent tree (`$left`) and the
//! change's tree (`$right`); whatever it leaves in `$right` moves into the
//! new change, and the rest stays in `v`, whose tree does not change. What
//! it leaves there is a [`Plan`] made from v's diff beforehand: the files
//! the new change gets, with their text there. Every other file keeps its
//! parent's version, symlinks and permissions included.
//!
//! Two parts can move, each assembled from whole top-level syntax units (an
//! item with its doc comments and attributes, an import, a statement), never
//! from lines:
//!
//! - New contracts (Pass 2): each top-level unit that holds only contracts
//!   the file did not have, and that no implementation shares a name with,
//!   goes in after the nearest unit before it that the old file has, with an
//!   import of each name it uses that the file does not import yet. Only
//!   additions move: a precursor that changed or removed a contract would
//!   break the code still written against the old one. A file the change
//!   adds moves its new contracts too, except in Rust and Nix, where another
//!   file must declare it. In Nix a new option goes into the attribute set
//!   the old file already has for it.
//! - Cosmetic edits (the guide's refactor precursor, Pattern A): each unit
//!   whose tokens the change leaves alone, but whose layout, comments, or
//!   trailing commas it changes, takes its new text.
//!
//! A part must parse, and must hold exactly what it meant to move, or its
//! file moves nothing. Renamed, copied, and binary files never move
//! anything, and neither do files in languages jj-graph cannot read.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tree_sitter::Node;

use crate::diff::FileDiff;
use crate::extract::{
    Binding, Item, Kind, Lang, Parsed, Role, Unit, has_syntax_errors, parse, units,
};

/// Which part of a change moves into the new change before it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Split {
    Contracts,
    Cosmetic,
}

impl Split {
    pub fn name(self) -> &'static str {
        match self {
            Split::Contracts => "contracts",
            Split::Cosmetic => "cosmetic",
        }
    }
}

/// The files a split gives the new change, each with its text there.
pub type Plan = BTreeMap<String, String>;

/// The part of one file's change that `split` moves: the file's path and
/// its text in the new change, or None when none of it moves.
pub fn file_part(file: &FileDiff, split: Split) -> Option<(String, String)> {
    if file.binary || file.same_text {
        return None;
    }
    if let (Some(old), Some(new)) = (&file.old_path, &file.new_path)
        && old != new
    {
        return None;
    }
    let path = file.path();
    let lang = Lang::of_path(path)?;
    let left = file.old_path.as_ref().map(|_| file.old.as_str());
    let right = file.new_path.as_ref().map(|_| file.new.as_str())?;
    if has_syntax_errors(lang, right) || left.is_some_and(|l| has_syntax_errors(lang, l)) {
        return None;
    }
    let part = match split {
        Split::Contracts => match (lang, left) {
            (Lang::Nix, None) => None,
            (Lang::Nix, Some(left)) => nix_contracts(left, right),
            (_, left) => contracts(lang, left, right),
        },
        Split::Cosmetic => cosmetics(lang, left?, right),
    }?;
    Some((path.to_owned(), part))
}

/// The part of a change that `split` moves.
pub fn plan(files: &[FileDiff], split: Split) -> Plan {
    let mut plan: Plan = files.iter().filter_map(|f| file_part(f, split)).collect();
    if split == Split::Contracts {
        declare_rust_modules(files, &mut plan);
    }
    plan
}

/// The files that may declare a Rust module file with `mod`, and the
/// module's name: `dir/name.rs` and `dir/name/mod.rs` are declared in
/// `dir/lib.rs`, `dir/main.rs`, `dir/mod.rs`, or `dir.rs`.
fn rust_declarers(path: &str) -> Option<(Vec<String>, String)> {
    let path = path.strip_suffix(".rs")?;
    let (dir, name) = match path.strip_suffix("/mod") {
        Some(module) => module.rsplit_once('/').unwrap_or(("", module)),
        None => path.rsplit_once('/').unwrap_or(("", path)),
    };
    let in_dir = |file: &str| {
        if dir.is_empty() {
            file.to_owned()
        } else {
            format!("{dir}/{file}")
        }
    };
    let mut declarers = vec![in_dir("lib.rs"), in_dir("main.rs"), in_dir("mod.rs")];
    if !dir.is_empty() {
        declarers.push(format!("{dir}.rs"));
    }
    Some((declarers, name.to_owned()))
}

/// The `mod` declarations of Rust text, as each declared name and the
/// declaration with its attributes.
fn rust_mods(text: &str) -> BTreeMap<String, String> {
    units(Lang::Rust, text)
        .into_iter()
        .filter_map(|u| match u.role {
            Role::Import(bindings) => Some((u.bytes, bindings)),
            _ => None,
        })
        .filter(|(bytes, _)| {
            text[bytes.clone()]
                .split(|c: char| !(c.is_alphanumeric() || c == '_'))
                .any(|w| w == "mod")
        })
        .flat_map(|(bytes, bindings)| {
            bindings
                .into_iter()
                .map(move |b| (b.name, text[bytes.clone()].to_owned()))
        })
        .collect()
}

/// A Rust file the change adds needs the `mod` that declares it. When a
/// file the change modifies gains that declaration, it moves too; when the
/// file that declares it is new as well, the added file stays behind. With
/// no declaration in the change, the file is declared as it was before,
/// or not at all, either way the same in both changes.
fn declare_rust_modules(files: &[FileDiff], plan: &mut Plan) {
    let added: Vec<String> = files
        .iter()
        .filter(|f| f.old_path.is_none() && Lang::of_path(f.path()) == Some(Lang::Rust))
        .map(|f| f.path().to_owned())
        .filter(|p| plan.contains_key(p))
        .collect();
    for path in added {
        let Some((declarers, name)) = rust_declarers(&path) else {
            continue;
        };
        for d in files
            .iter()
            .filter(|f| declarers.iter().any(|x| x == f.path()))
        {
            let Some(declaration) = d
                .new_path
                .as_ref()
                .and_then(|_| rust_mods(&d.new).remove(&name))
            else {
                continue;
            };
            let declared_before = d.old_path.is_some() && rust_mods(&d.old).contains_key(&name);
            if declared_before {
                continue;
            }
            let base = match (&d.old_path, plan.get(d.path())) {
                (_, Some(part)) => part.clone(),
                (Some(_), None) => d.old.clone(),
                // The declaring file is new too: the module cannot exist
                // in the part without it.
                (None, None) => {
                    plan.remove(&path);
                    break;
                }
            };
            match with_imports(Lang::Rust, &base, &[declaration]) {
                Some(part) => {
                    plan.insert(d.path().to_owned(), part);
                }
                None => {
                    plan.remove(&path);
                }
            }
            break;
        }
    }
}

/// Where imports go in a file: after its last import, or else after its
/// prologue, or else before its first unit.
fn opening(base: &str, units: &[Unit]) -> usize {
    let after_last = |pick: &dyn Fn(&Role) -> bool| {
        units
            .iter()
            .filter(|u| pick(&u.role))
            .map(|u| line_end(base, u.bytes.end))
            .max()
    };
    after_last(&|r| matches!(r, Role::Import(_)))
        .or_else(|| after_last(&|r| *r == Role::Prologue))
        .or_else(|| units.first().map(|u| u.bytes.start))
        .unwrap_or(base.len())
}

/// `base` with these imports added where imports go, if it still parses.
fn with_imports(lang: Lang, base: &str, imports: &[String]) -> Option<String> {
    let at = opening(base, &units(lang, base));
    let body: String = imports.iter().map(|i| format!("{i}\n")).collect();
    let text = insert(base, vec![(at, 0, block(base, at, &body))]);
    (!has_syntax_errors(lang, &text)).then_some(text)
}

/// One file's text in the new change of `split`, given its text before
/// the change and after it (None: the file does not exist there).
pub fn part(split: Split, path: &str, left: Option<&str>, right: Option<&str>) -> Option<String> {
    let file = FileDiff {
        old_path: left.map(|_| path.to_owned()),
        new_path: right.map(|_| path.to_owned()),
        old: left.unwrap_or_default().to_owned(),
        new: right.unwrap_or_default().to_owned(),
        ..FileDiff::default()
    };
    match file_part(&file, split) {
        Some((_, text)) => Some(text),
        None => left.map(str::to_owned),
    }
}

pub fn contract_part(path: &str, left: Option<&str>, right: Option<&str>) -> Option<String> {
    part(Split::Contracts, path, left, right)
}

pub fn cosmetic_part(path: &str, left: Option<&str>, right: Option<&str>) -> Option<String> {
    part(Split::Cosmetic, path, left, right)
}

// ---------------------------------------------------------------------
// Assembling a part
// ---------------------------------------------------------------------

/// Where the line holding byte `at` ends: just past its newline.
fn line_end(text: &str, at: usize) -> usize {
    text[at..].find('\n').map_or(text.len(), |i| at + i + 1)
}

/// The items of a parsed file that lie in `bytes`.
fn items_in<'a>(p: &'a Parsed, bytes: &Range<usize>) -> Vec<&'a Item> {
    p.items
        .iter()
        .filter(|i| bytes.start <= i.bytes.start && i.bytes.end <= bytes.end)
        .collect()
}

fn names_in(p: &Parsed, bytes: &Range<usize>) -> BTreeSet<String> {
    items_in(p, bytes)
        .into_iter()
        .map(|i| i.name.clone())
        .collect()
}

/// Insertions into `text`, each at a byte with a rank among those at the
/// same byte.
fn insert(text: &str, mut insertions: Vec<(usize, usize, String)>) -> String {
    insertions.sort_by_key(|(at, rank, _)| (*at, *rank));
    let mut out = String::with_capacity(text.len() + 256);
    let mut at = 0;
    for (to, _, piece) in insertions {
        out.push_str(&text[at..to]);
        out.push_str(&piece);
        at = to;
    }
    out.push_str(&text[at..]);
    out
}

/// Text to put at a line start `at` of `text` as a block of its own.
fn block(text: &str, at: usize, body: &str) -> String {
    let mut out = String::new();
    if at == text.len() && !text.is_empty() && !text.ends_with('\n') {
        out.push('\n');
    }
    if at > 0 && !text[..at].ends_with("\n\n") {
        out.push('\n');
    }
    out.push_str(body);
    if !body.ends_with('\n') {
        out.push('\n');
    }
    if at < text.len() && !text[at..].starts_with('\n') {
        out.push('\n');
    }
    out
}

/// Each item of a parsed file as its name, kind, and tokens, sorted.
fn signature<'a>(items: impl IntoIterator<Item = &'a Item>) -> Vec<(String, Kind, u64)> {
    let mut out: Vec<_> = items
        .into_iter()
        .map(|i| (i.name.clone(), i.kind, i.fingerprint))
        .collect();
    out.sort();
    out
}

/// The new contracts of a file in a language with items and imports, with
/// the imports they need, inserted into the old file (or, for a file the
/// change adds, into its prologue).
fn contracts(lang: Lang, left: Option<&str>, right: &str) -> Option<String> {
    let rp = parse(lang, right);
    let ru = units(lang, right);
    let base: String = match left {
        Some(l) => l.to_owned(),
        None => ru
            .iter()
            .filter(|u| u.role == Role::Prologue)
            .map(|u| format!("{}\n", &right[u.bytes.clone()]))
            .collect(),
    };
    let lp = parse(lang, &base);
    let lu = units(lang, &base);
    let left_names: BTreeSet<&str> = lp.items.iter().map(|i| i.name.as_str()).collect();
    let impl_names: BTreeSet<&str> = rp
        .items
        .iter()
        .filter(|i| i.kind == Kind::Impl)
        .map(|i| i.name.as_str())
        .collect();
    let moves = |u: &Unit| {
        let items = items_in(&rp, &u.bytes);
        u.role == Role::Other
            && !items.is_empty()
            && items.iter().all(|i| {
                i.kind == Kind::Contract
                    && !left_names.contains(i.name.as_str())
                    && !impl_names.contains(i.name.as_str())
            })
    };
    let moving: Vec<usize> = (0..ru.len()).filter(|&k| moves(&ru[k])).collect();
    if moving.is_empty() {
        return None;
    }

    // The names the moving units use that an import of the new file binds
    // and the old file neither binds nor defines.
    let used: BTreeSet<&str> = rp
        .refs
        .iter()
        .filter(|r| {
            moving
                .iter()
                .any(|&k| ru[k].bytes.start <= r.bytes.start && r.bytes.end <= ru[k].bytes.end)
        })
        .map(|r| r.name.as_str())
        .collect();
    let bound_before: BTreeSet<&str> = lu
        .iter()
        .flat_map(|u| match &u.role {
            Role::Import(bs) => bs.iter().map(|b| b.name.as_str()).collect(),
            _ => Vec::new(),
        })
        .collect();
    let mut needed: Vec<&Binding> = Vec::new();
    for u in &ru {
        let Role::Import(bindings) = &u.role else {
            continue;
        };
        for b in bindings {
            if b.name != "*"
                && used.contains(b.name.as_str())
                && !bound_before.contains(b.name.as_str())
                && !left_names.contains(b.name.as_str())
                && !needed.iter().any(|n| n.text == b.text)
            {
                needed.push(b);
            }
        }
    }

    // Where each moving unit goes: after the nearest unit before it that
    // the old file has, matched by the items it holds, or else by tokens.
    let mut taken = vec![false; lu.len()];
    let mut counterpart: Vec<Option<usize>> = vec![None; ru.len()];
    for (k, r) in ru.iter().enumerate() {
        if moving.contains(&k) {
            continue;
        }
        let rn = names_in(&rp, &r.bytes);
        counterpart[k] = (0..lu.len()).find(|&j| {
            !taken[j]
                && if rn.is_empty() {
                    lu[j].fingerprint == r.fingerprint
                } else {
                    names_in(&lp, &lu[j].bytes) == rn
                }
        });
        if let Some(j) = counterpart[k] {
            taken[j] = true;
        }
    }
    let opening = opening(&base, &lu);
    let mut insertions = Vec::new();
    if !needed.is_empty() {
        let body: String = needed.iter().map(|b| format!("{}\n", b.text)).collect();
        insertions.push((opening, 0, block(&base, opening, &body)));
    }
    for &k in &moving {
        let at = (0..k)
            .rev()
            .find_map(|j| counterpart[j])
            .map_or(opening, |j| line_end(&base, lu[j].bytes.end));
        insertions.push((at, k + 1, block(&base, at, &right[ru[k].bytes.clone()])));
    }
    let twin = insert(&base, insertions);

    // The part parses, and holds the old items and the moving ones.
    if has_syntax_errors(lang, &twin) {
        return None;
    }
    let mut want = lp.items.clone();
    for &k in &moving {
        want.extend(items_in(&rp, &ru[k].bytes).into_iter().cloned());
    }
    (signature(&parse(lang, &twin).items) == signature(&want)).then_some(twin)
}

/// The cosmetic part of a file's change: each unit whose tokens the change
/// leaves alone takes its new text.
fn cosmetics(lang: Lang, left: &str, right: &str) -> Option<String> {
    let (lp, rp) = (parse(lang, left), parse(lang, right));
    let (lu, ru) = (units(lang, left), units(lang, right));
    let mut taken = vec![false; ru.len()];
    let mut edits: Vec<(Range<usize>, &str)> = Vec::new();
    for l in &lu {
        let names = names_in(&lp, &l.bytes);
        let same = (0..ru.len()).find(|&k| {
            !taken[k]
                && ru[k].fingerprint == l.fingerprint
                && std::mem::discriminant(&ru[k].role) == std::mem::discriminant(&l.role)
                && names_in(&rp, &ru[k].bytes) == names
        });
        if let Some(k) = same {
            taken[k] = true;
            if left[l.bytes.clone()] != right[ru[k].bytes.clone()] {
                edits.push((l.bytes.clone(), &right[ru[k].bytes.clone()]));
            }
        }
    }
    if edits.is_empty() {
        return None;
    }
    let mut twin = String::with_capacity(left.len());
    let mut at = 0;
    for (range, text) in edits {
        twin.push_str(&left[at..range.start]);
        twin.push_str(text);
        at = range.end;
    }
    twin.push_str(&left[at..]);
    // The part parses, and has the old units' tokens, in order.
    let tokens = |us: &[Unit]| us.iter().map(|u| u.fingerprint).collect::<Vec<_>>();
    (!has_syntax_errors(lang, &twin) && tokens(&units(lang, &twin)) == tokens(&lu)).then_some(twin)
}

// ---------------------------------------------------------------------
// Nix options
// ---------------------------------------------------------------------

/// Bindings of an attribute set, each with its attribute path as written.
fn bindings_of<'t>(set: Node<'t>, text: &str) -> Vec<(Vec<String>, Node<'t>)> {
    let mut cursor = set.walk();
    let Some(binding_set) = set
        .named_children(&mut cursor)
        .find(|c| c.kind() == "binding_set")
    else {
        return Vec::new();
    };
    let mut c = binding_set.walk();
    binding_set
        .named_children(&mut c)
        .filter(|b| b.kind() == "binding")
        .filter_map(|b| {
            let path = crate::extract::nix_attr_names(b.child_by_field_name("attrpath")?, text)?;
            Some((path, b))
        })
        .collect()
}

/// The attribute set a binding's value is, if it is one.
fn set_value(binding: Node) -> Option<Node> {
    binding
        .child_by_field_name("expression")
        .filter(|e| matches!(e.kind(), "attrset_expression" | "rec_attrset_expression"))
}

/// The attribute set at `path` below `set`, following bindings whose
/// values are sets, the way a module nests them.
fn set_at<'t>(set: Node<'t>, path: &[String], text: &str) -> Option<Node<'t>> {
    if path.is_empty() {
        return Some(set);
    }
    bindings_of(set, text).into_iter().find_map(|(p, b)| {
        let rest = path.strip_prefix(p.as_slice())?;
        set_at(set_value(b)?, rest, text)
    })
}

/// The new options of a Nix module, each put into the attribute set the old
/// module already has for it.
fn nix_contracts(left: &str, right: &str) -> Option<String> {
    let (lp, rp) = (parse(Lang::Nix, left), parse(Lang::Nix, right));
    let left_names: BTreeSet<&str> = lp.items.iter().map(|i| i.name.as_str()).collect();
    let impl_names: BTreeSet<&str> = rp
        .items
        .iter()
        .filter(|i| i.kind == Kind::Impl)
        .map(|i| i.name.as_str())
        .collect();
    let new_contract = |i: &Item| {
        i.kind == Kind::Contract
            && !left_names.contains(i.name.as_str())
            && !impl_names.contains(i.name.as_str())
    };
    let (lt, rt) = (
        crate::extract::parse_tree(Lang::Nix, left)?,
        crate::extract::parse_tree(Lang::Nix, right)?,
    );
    let (lroot, rroot) = (
        crate::extract::nix_root_set(lt.root_node())?,
        crate::extract::nix_root_set(rt.root_node())?,
    );

    // Walk the new module's sets from the top. The walk goes into a set the
    // old module has too; a binding outside such a set moves whole when
    // every item in it is a new contract and the old module has the set it
    // sits in.
    let mut moving: Vec<(Vec<String>, Node, Vec<String>)> = Vec::new();
    let mut stack = vec![(Vec::<String>::new(), rroot)];
    while let Some((at, set)) = stack.pop() {
        for (path, binding) in bindings_of(set, right) {
            let items = items_in(&rp, &binding.byte_range());
            if items.is_empty() {
                continue;
            }
            let mut deeper = at.clone();
            deeper.extend(path.iter().cloned());
            if let Some(inner) = set_value(binding)
                && set_at(lroot, &deeper, left).is_some()
            {
                stack.push((deeper, inner));
            } else if items.iter().all(|i| new_contract(i)) && set_at(lroot, &at, left).is_some() {
                moving.push((at.clone(), binding, path));
            }
        }
    }
    if moving.is_empty() {
        return None;
    }
    let mut insertions = Vec::new();
    for (rank, (at, binding, path)) in moving.iter().enumerate() {
        let target = set_at(lroot, at, left)?;
        let siblings = bindings_of(target, left);
        // Two bindings of one attribute, or of an attribute and one inside
        // it, would collide.
        if siblings
            .iter()
            .any(|(p, _)| p.starts_with(path) || path.starts_with(p))
        {
            return None;
        }
        let indent: String = right[..binding.start_byte()]
            .rsplit('\n')
            .next()
            .unwrap_or_default()
            .chars()
            .take_while(|c| c.is_whitespace())
            .collect();
        let text = &right[binding.byte_range()];
        // After the set's last binding, or just inside an empty set's `{`.
        let (pos, piece) = match siblings.last() {
            Some((_, last)) => (last.end_byte(), format!("\n{indent}{text}")),
            None => {
                let brace = left[target.byte_range()].find('{')? + target.start_byte() + 1;
                (brace, format!("\n{indent}{text}\n"))
            }
        };
        insertions.push((pos, rank, piece));
    }
    let twin = insert(left, insertions);
    if has_syntax_errors(Lang::Nix, &twin) {
        return None;
    }
    let mut want = lp.items.clone();
    for (_, binding, _) in &moving {
        want.extend(items_in(&rp, &binding.byte_range()).into_iter().cloned());
    }
    (signature(&parse(Lang::Nix, &twin).items) == signature(&want)).then_some(twin)
}

// ---------------------------------------------------------------------
// The diff editor
// ---------------------------------------------------------------------

fn files_under(root: &Path) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    if !root.exists() {
        return Ok(out);
    }
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                stack.push(entry.path());
            } else {
                out.push(entry.path().strip_prefix(root)?.to_path_buf());
            }
        }
    }
    Ok(out)
}

fn remove(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(path)?,
        Ok(_) => fs::remove_file(path)?,
        Err(_) => {}
    }
    Ok(())
}

/// Make `to` what `from` is: a symlink to the same target, or a file with
/// the same bytes and permissions; nothing when `from` does not exist.
fn copy_entry(from: &Path, to: &Path) -> Result<()> {
    let Ok(meta) = fs::symlink_metadata(from) else {
        return Ok(());
    };
    // A directory's files come one by one.
    if meta.is_dir() {
        return Ok(());
    }
    if let Some(dir) = to.parent() {
        fs::create_dir_all(dir)?;
    }
    if meta.file_type().is_symlink() {
        std::os::unix::fs::symlink(fs::read_link(from)?, to)?;
    } else {
        fs::copy(from, to)?;
    }
    Ok(())
}

/// Make `right` hold the new change: each file of `plan` with its text
/// there, and every other file as `left` has it. A planned file keeps the
/// permissions it had in `left`, or in `right` when it is new.
pub fn apply_plan(plan: &Plan, left: &Path, right: &Path) -> Result<()> {
    let mut paths = files_under(left)?;
    paths.extend(files_under(right)?);
    paths.extend(plan.keys().map(PathBuf::from));
    paths.sort();
    paths.dedup();
    for rel in paths {
        let (l, r) = (left.join(&rel), right.join(&rel));
        let key = rel.to_string_lossy();
        match plan.get(key.as_ref()) {
            Some(text) => {
                let permissions = [&l, &r]
                    .iter()
                    .find_map(|p| fs::symlink_metadata(p).ok().filter(|m| m.is_file()))
                    .map(|m| m.permissions());
                remove(&r)?;
                if let Some(dir) = r.parent() {
                    fs::create_dir_all(dir)?;
                }
                fs::write(&r, text).with_context(|| format!("writing {}", r.display()))?;
                if let Some(p) = permissions {
                    fs::set_permissions(&r, p)?;
                }
            }
            None => {
                remove(&r)?;
                copy_entry(&l, &r)?;
            }
        }
    }
    Ok(())
}
