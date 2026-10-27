//! Pass 1: what a change's diff defines and references.
//!
//! Each supported file is parsed before and after the change with
//! tree-sitter. A definition is an item: a contract (trait, interface,
//! protocol, struct, enum, type alias, module option declaration) or an
//! implementation (function, method, class, constant, configuration value).
//! The change *defines* every item it adds, removes, or changes, where
//! "changes" compares the item's tokens without comments or layout, so
//! reformatting is not a redefinition. It *references* every identifier it
//! inserts, other than the names it defines there: each use among the tokens
//! of a top-level unit it changes (diffed against that unit's old version),
//! and each use in a unit it adds. A unit it only moves or reformats
//! references nothing; a use outside every unit counts when its line is new.
//!
//! Names are matched by their simple name, so two unrelated items with the
//! same name look related. That only ever adds a requirement, which keeps a
//! normalization safe at the cost of some parallelism. Files in other
//! languages contribute only their paths, through which changes to the same
//! file stay ordered unless their diffs commute.
//!
//! The same items, cut into pieces (`pieces`), judge a merge jj's text merge
//! did not make: an edit is kept when it removes and adds the same pieces.

use std::collections::{BTreeMap, BTreeSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::Range;

use similar::{Algorithm, DiffOp, capture_diff_slices};
use tree_sitter::{Language, Node, Parser, Query, QueryCursor, StreamingIterator};

use crate::diff::{FileDiff, added_lines};

/// A language jj-graph can read definitions from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Lang {
    Rust,
    Python,
    TypeScript,
    Tsx,
    JavaScript,
    Go,
    Nix,
}

impl Lang {
    pub fn of_path(path: &str) -> Option<Lang> {
        let ext = path.rsplit_once('.').map(|(_, e)| e)?;
        Some(match ext {
            "rs" => Lang::Rust,
            "py" | "pyi" => Lang::Python,
            "ts" | "mts" | "cts" => Lang::TypeScript,
            "tsx" => Lang::Tsx,
            "js" | "mjs" | "cjs" | "jsx" => Lang::JavaScript,
            "go" => Lang::Go,
            "nix" => Lang::Nix,
            _ => return None,
        })
    }

    fn language(self) -> Language {
        match self {
            Lang::Rust => tree_sitter_rust::LANGUAGE.into(),
            Lang::Python => tree_sitter_python::LANGUAGE.into(),
            Lang::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            Lang::Tsx => tree_sitter_typescript::LANGUAGE_TSX.into(),
            Lang::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
            Lang::Go => tree_sitter_go::LANGUAGE.into(),
            Lang::Nix => tree_sitter_nix::LANGUAGE.into(),
        }
    }

    fn query(self) -> &'static str {
        match self {
            Lang::Rust => include_str!("queries/rust.scm"),
            Lang::Python => include_str!("queries/python.scm"),
            Lang::TypeScript | Lang::Tsx => include_str!("queries/typescript.scm"),
            Lang::JavaScript => include_str!("queries/javascript.scm"),
            Lang::Go => include_str!("queries/go.scm"),
            Lang::Nix => "",
        }
    }

    /// Node kinds that name something another item can refer to.
    fn identifier_kinds(self) -> &'static [&'static str] {
        match self {
            Lang::Rust => &["identifier", "type_identifier", "field_identifier"],
            Lang::Python => &["identifier"],
            Lang::TypeScript | Lang::Tsx => &[
                "identifier",
                "type_identifier",
                "property_identifier",
                "shorthand_property_identifier",
            ],
            Lang::JavaScript => &[
                "identifier",
                "property_identifier",
                "shorthand_property_identifier",
            ],
            Lang::Go => &[
                "identifier",
                "type_identifier",
                "field_identifier",
                "package_identifier",
            ],
            Lang::Nix => &["identifier"],
        }
    }

    /// Items whose nested items are private to them: a function's inner
    /// functions are part of the function.
    fn function_kinds(self) -> &'static [&'static str] {
        match self {
            Lang::Rust => &["function_item", "closure_expression"],
            Lang::Python => &["function_definition", "lambda"],
            Lang::TypeScript | Lang::Tsx | Lang::JavaScript => &[
                "function_declaration",
                "function_expression",
                "arrow_function",
                "generator_function_declaration",
                "method_definition",
            ],
            Lang::Go => &["function_declaration", "method_declaration", "func_literal"],
            Lang::Nix => &[],
        }
    }
}

/// Whether an item is part of a contract or of an implementation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Kind {
    Contract,
    Impl,
}

/// One definition in a file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub name: String,
    pub kind: Kind,
    /// Exported: other modules may use it.
    pub public: bool,
    /// The item's bytes and lines (0-based, end exclusive).
    pub bytes: Range<usize>,
    pub lines: Range<usize>,
    /// The item's tokens without comments or layout.
    pub fingerprint: u64,
    /// Names declared inside the item that its users name through it: a
    /// trait's methods, a struct's fields, an enum's variants.
    pub members: Vec<String>,
}

/// A name a file uses, where it uses it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ref {
    pub name: String,
    /// The line (0-based) and the bytes of the use.
    pub line: usize,
    pub bytes: Range<usize>,
}

/// What one version of a file defines, references, and imports.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Parsed {
    pub items: Vec<Item>,
    /// Each use of a name that is not where it is defined.
    pub refs: Vec<Ref>,
    /// Lines of import statements.
    pub imports: Vec<Range<usize>>,
}

impl Parsed {
    /// The innermost item containing `line`, if any.
    pub fn item_at(&self, line: usize) -> Option<&Item> {
        self.items
            .iter()
            .filter(|i| i.lines.contains(&line))
            .min_by_key(|i| i.lines.end - i.lines.start)
    }

    pub fn is_import_line(&self, line: usize) -> bool {
        self.imports.iter().any(|r| r.contains(&line))
    }
}

fn is_comment(kind: &str) -> bool {
    kind.contains("comment")
}

/// A hash of the node's syntax: every named node's kind, every token, and
/// where each node's children begin and end, skipping comments and trailing
/// commas. Layout never reaches it, and neither does a comma a formatter
/// adds or drops before a closing bracket, while any change of structure
/// does: dedenting a Python statement out of a block, a hole in a
/// JavaScript array (`[, b]`), or `(a,)` (a tuple) for `(a)`.
fn fingerprint(node: Node, text: &str) -> u64 {
    enum Step<'t> {
        Enter(Node<'t>),
        Exit,
    }
    let mut h = DefaultHasher::new();
    let mut cursor = node.walk();
    let mut stack = vec![Step::Enter(node)];
    while let Some(step) = stack.pop() {
        let n = match step {
            Step::Exit => {
                0xFEu8.hash(&mut h);
                continue;
            }
            Step::Enter(n) => n,
        };
        if n.is_named() {
            n.kind().hash(&mut h);
        }
        if n.child_count() == 0 {
            text[n.byte_range()].hash(&mut h);
            continue;
        }
        0xFFu8.hash(&mut h);
        stack.push(Step::Exit);
        let children: Vec<Node> = n
            .children(&mut cursor)
            .filter(|c| !is_comment(c.kind()))
            .collect();
        let closing = |c: &Node| !c.is_named() && matches!(c.kind(), ")" | "]" | "}" | ">");
        let kept: Vec<Node> = children
            .iter()
            .enumerate()
            .filter(|(i, c)| {
                !(!c.is_named() && c.kind() == "," && children[i + 1..].iter().all(closing))
            })
            .map(|(_, c)| *c)
            .collect();
        stack.extend(kept.into_iter().rev().map(Step::Enter));
    }
    h.finish()
}

/// The node an item's declaration spans. In JavaScript and TypeScript a
/// variable's `const` or `let`, and an item's `export` or `declare`, sit
/// outside the node the query captures, but changing them changes what
/// the item is.
fn declaration<'t>(lang: Lang, node: Node<'t>) -> Node<'t> {
    if !matches!(lang, Lang::TypeScript | Lang::Tsx | Lang::JavaScript) {
        return node;
    }
    let mut n = node;
    while let Some(p) = n.parent() {
        let outward = matches!(
            (n.kind(), p.kind()),
            (
                "variable_declarator",
                "lexical_declaration" | "variable_declaration"
            ) | (_, "export_statement" | "ambient_declaration")
        );
        if !outward {
            break;
        }
        n = p;
    }
    n
}

/// Whether a comment documents the item below it, by the language's own
/// convention: `///` and `/**` in Rust, `/**` in JavaScript and TypeScript,
/// any comment directly above in Go (godoc), and none in Python, whose
/// documentation is a docstring inside.
fn is_doc_comment(lang: Lang, node: Node, text: &str) -> bool {
    let t = &text[node.byte_range()];
    match lang {
        Lang::Rust => t.starts_with("///") && !t.starts_with("////") || t.starts_with("/**"),
        Lang::TypeScript | Lang::Tsx | Lang::JavaScript => t.starts_with("/**"),
        Lang::Go => true,
        Lang::Python | Lang::Nix => false,
    }
}

/// The first node of an item's extent: its decorators, attributes, and the
/// doc comments directly above it belong to it. Other comments do not, so
/// an item's extent depends on its own text, not on what happens to sit
/// above it.
fn leading<'t>(lang: Lang, node: Node<'t>, text: &str) -> Node<'t> {
    let mut start = match node.parent() {
        Some(p) if p.kind() == "decorated_definition" => p,
        _ => node,
    };
    while let Some(prev) = start.prev_sibling() {
        let attached = matches!(prev.kind(), "attribute_item" | "decorator")
            || is_comment(prev.kind()) && is_doc_comment(lang, prev, text);
        if attached && prev.end_position().row + 1 >= start.start_position().row {
            start = prev;
        } else {
            break;
        }
    }
    start
}

/// The fingerprint of an item with its attributes and decorators.
fn item_fingerprint(first: Node, node: Node, text: &str) -> u64 {
    let mut h = DefaultHasher::new();
    let mut n = first;
    loop {
        if !is_comment(n.kind()) {
            fingerprint(n, text).hash(&mut h);
        }
        if n.id() == node.id() || n.end_byte() >= node.end_byte() {
            break;
        }
        match n.next_sibling() {
            Some(next) => n = next,
            None => break,
        }
    }
    h.finish()
}

fn has_ancestor_kind(node: Node, kinds: &[&str]) -> bool {
    let mut n = node.parent();
    while let Some(p) = n {
        if kinds.contains(&p.kind()) {
            return true;
        }
        n = p.parent();
    }
    false
}

fn is_public(lang: Lang, node: Node, name: &str) -> bool {
    match lang {
        Lang::Rust => {
            let mut cursor = node.walk();
            node.children(&mut cursor)
                .any(|c| c.kind() == "visibility_modifier")
        }
        Lang::Python => !name.starts_with('_'),
        Lang::TypeScript | Lang::Tsx | Lang::JavaScript => {
            node.kind() == "method_definition" || has_ancestor_kind(node, &["export_statement"])
        }
        Lang::Go => name.chars().next().is_some_and(char::is_uppercase),
        Lang::Nix => true,
    }
}

pub(crate) fn parse_tree(lang: Lang, text: &str) -> Option<tree_sitter::Tree> {
    let mut parser = Parser::new();
    parser.set_language(&lang.language()).ok()?;
    parser.parse(text, None)
}

/// Whether tree-sitter finds a syntax error in the text.
pub fn has_syntax_errors(lang: Lang, text: &str) -> bool {
    parse_tree(lang, text).is_none_or(|t| t.root_node().has_error())
}

/// Read one version of a file.
pub fn parse(lang: Lang, text: &str) -> Parsed {
    let Some(tree) = parse_tree(lang, text) else {
        return Parsed::default();
    };
    let root = tree.root_node();
    if lang == Lang::Nix {
        return nix::parse(root, text);
    }
    let query = Query::new(&lang.language(), lang.query()).expect("the bundled queries compile");
    let names = query.capture_names().to_vec();
    let index = |name: &str| names.iter().position(|n| *n == name).map(|i| i as u32);
    let (c_contract, c_impl, c_name, c_import, c_member) = (
        index("contract"),
        index("impl"),
        index("name"),
        index("import"),
        index("member"),
    );

    // Name node byte range -> (item node, kind). A contract capture wins
    // over an implementation capture of the same name.
    let mut found: BTreeMap<(usize, usize), (Node, Kind)> = BTreeMap::new();
    let mut imports = Vec::new();
    let mut members: Vec<Node> = Vec::new();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query, root, text.as_bytes());
    while let Some(m) = matches.next() {
        let capture = |i: Option<u32>| {
            m.captures()
                .iter()
                .find(|c| Some(c.index) == i)
                .map(|c| c.node)
        };
        if let Some(node) = capture(c_import) {
            imports.push(node.start_position().row..node.end_position().row + 1);
            continue;
        }
        if let Some(node) = capture(c_member) {
            members.push(node);
            continue;
        }
        let Some(name) = capture(c_name) else {
            continue;
        };
        let (node, kind) = match (capture(c_contract), capture(c_impl)) {
            (Some(n), _) => (n, Kind::Contract),
            (None, Some(n)) => (n, Kind::Impl),
            _ => continue,
        };
        let key = (name.start_byte(), name.end_byte());
        match found.get(&key) {
            Some((_, Kind::Contract)) => {}
            _ => {
                found.insert(key, (node, kind));
            }
        }
    }

    let contract_nodes: Vec<Node> = found
        .values()
        .filter(|(_, k)| *k == Kind::Contract)
        .map(|(n, _)| *n)
        .collect();
    let impl_nodes: Vec<Node> = found
        .values()
        .filter(|(_, k)| *k == Kind::Impl)
        .map(|(n, _)| *n)
        .collect();
    let within = |outer: Node, inner: Node| {
        outer.id() != inner.id()
            && outer.start_byte() <= inner.start_byte()
            && inner.end_byte() <= outer.end_byte()
    };
    let mut items: Vec<Item> = Vec::new();
    let mut name_sites = BTreeSet::new();
    for (&(start, end), &(node, kind)) in &found {
        name_sites.insert((start, end));
        // An item inside a contract is one of its members (a trait's default
        // method); an item inside a function is private to it.
        if contract_nodes.iter().any(|c| within(*c, node)) {
            if let Some(name_node) = node.child_by_field_name("name") {
                members.push(name_node);
            }
            continue;
        }
        if has_ancestor_kind(node, lang.function_kinds()) {
            continue;
        }
        // A contract nested in an implementation (an impl block's associated
        // type, a class's nested enum) is part of it, and cannot move
        // without it.
        let kind = if kind == Kind::Contract
            && (has_ancestor_kind(node, &["impl_item"])
                || impl_nodes.iter().any(|i| within(*i, node)))
        {
            Kind::Impl
        } else {
            kind
        };
        let mut name = text[start..end]
            .split('[')
            .next()
            .unwrap_or_default()
            .trim()
            .to_owned();
        if name.is_empty() {
            continue;
        }
        // A method of `impl Trait for Type` implements a member the trait
        // already declares: callers name it through the trait, so it gets the
        // type's name in front instead of sharing the member's.
        if lang == Lang::Rust && node.kind() == "function_item" {
            let mut up = node.parent();
            while let Some(p) = up {
                if p.kind() == "impl_item" {
                    if p.child_by_field_name("trait").is_some()
                        && let Some(ty) = p.child_by_field_name("type")
                    {
                        let ty = text[ty.byte_range()]
                            .split('<')
                            .next()
                            .unwrap_or_default()
                            .trim();
                        name = format!("{ty}::{name}");
                    }
                    break;
                }
                up = p.parent();
            }
        }
        let outer = declaration(lang, node);
        let first = leading(lang, outer, text);
        items.push(Item {
            public: is_public(lang, node, &name),
            name,
            kind,
            bytes: first.start_byte()..outer.end_byte(),
            lines: first.start_position().row..outer.end_position().row + 1,
            fingerprint: item_fingerprint(first, outer, text),
            members: Vec::new(),
        });
    }
    for m in &members {
        name_sites.insert((m.start_byte(), m.end_byte()));
        let owner = items
            .iter_mut()
            .filter(|i| i.bytes.start <= m.start_byte() && m.end_byte() <= i.bytes.end)
            .min_by_key(|i| i.bytes.end - i.bytes.start);
        if let Some(item) = owner {
            item.members.push(text[m.byte_range()].to_owned());
        }
    }

    let mut refs = Vec::new();
    let kinds = lang.identifier_kinds();
    let mut walker = root.walk();
    let mut stack = vec![root];
    while let Some(n) = stack.pop() {
        if kinds.contains(&n.kind()) {
            if !name_sites.contains(&(n.start_byte(), n.end_byte())) {
                refs.push(Ref {
                    name: text[n.byte_range()].to_owned(),
                    line: n.start_position().row,
                    bytes: n.byte_range(),
                });
            }
        } else {
            stack.extend(n.children(&mut walker));
        }
    }
    Parsed {
        items,
        refs,
        imports,
    }
}

/// What one file's change defines and references.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct Symbols {
    pub defs: BTreeSet<String>,
    /// Every contract among `defs`: added, changed, or removed.
    pub contracts: BTreeSet<String>,
    pub refs: BTreeSet<String>,
    /// The contracts the change's contract part holds: the new ones a split
    /// moves before it (see `hoist`), what that part references, and the
    /// files it touches.
    pub hoisted: BTreeSet<String>,
    pub crefs: BTreeSet<String>,
    /// Every file touched, and the files the contract part touches.
    pub files: BTreeSet<String>,
    pub cfiles: BTreeSet<String>,
    /// The implementations among `defs` that are not exported.
    pub private: BTreeSet<String>,
    /// Files whose cosmetic edits a split can move: units whose layout,
    /// comments, or trailing commas the change edits and whose tokens it
    /// leaves alone.
    pub cosmetic_files: BTreeSet<String>,
}

impl Symbols {
    pub fn merge(&mut self, other: Symbols) {
        self.defs.extend(other.defs);
        self.contracts.extend(other.contracts);
        self.hoisted.extend(other.hoisted);
        self.refs.extend(other.refs);
        self.crefs.extend(other.crefs);
        self.files.extend(other.files);
        self.cfiles.extend(other.cfiles);
        self.private.extend(other.private);
        self.cosmetic_files.extend(other.cosmetic_files);
    }

    /// The change mixes cosmetic edits with others, so a refactor precursor
    /// can take the cosmetic ones.
    pub fn has_separable_cosmetics(&self) -> bool {
        !self.cosmetic_files.is_empty()
            && (!self.defs.is_empty() || self.files.len() > self.cosmetic_files.len())
    }
}

/// Items grouped by name, with their kinds and fingerprints.
fn by_name(p: &Parsed) -> BTreeMap<&str, (BTreeSet<Kind>, Vec<u64>)> {
    let mut out: BTreeMap<&str, (BTreeSet<Kind>, Vec<u64>)> = BTreeMap::new();
    for item in &p.items {
        let e = out.entry(item.name.as_str()).or_default();
        e.0.insert(item.kind);
        e.1.push(item.fingerprint);
    }
    for (_, fps) in out.values_mut() {
        fps.sort_unstable();
    }
    out
}

/// What one file's change defines and references, and what its splits
/// would move.
pub fn file_symbols(file: &FileDiff) -> Symbols {
    let mut out = Symbols {
        files: file.paths().cloned().collect(),
        ..Symbols::default()
    };
    let Some(lang) = (!file.binary).then(|| Lang::of_path(file.path())).flatten() else {
        return out;
    };
    let old = file.old_path.as_ref().map(|_| file.old.as_str());
    let new = file.new_path.as_ref().map(|_| file.new.as_str());
    let whole = between(lang, old, new);
    out.defs = whole.defs;
    out.contracts = whole.contracts;
    out.private = whole.private;
    out.refs = whole.refs;
    // The contract part is what the split would move, read the same way.
    if let Some((path, part)) = crate::hoist::file_part(file, crate::hoist::Split::Contracts) {
        let moved = between(lang, old, Some(&part));
        out.hoisted = moved.defs;
        out.crefs = moved.refs;
        out.cfiles.insert(path);
    }
    if crate::hoist::file_part(file, crate::hoist::Split::Cosmetic).is_some() {
        out.cosmetic_files.insert(file.path().to_owned());
    }
    out
}

/// What changing a file from `old` to `new` (None: it does not exist on
/// that side) defines, and the names the lines it adds reference.
fn between(lang: Lang, old: Option<&str>, new: Option<&str>) -> Symbols {
    let mut out = Symbols::default();
    let before = old.map(|t| parse(lang, t)).unwrap_or_default();
    let after = new.map(|t| parse(lang, t)).unwrap_or_default();
    let (b, a) = (by_name(&before), by_name(&after));
    for name in b.keys().chain(a.keys()) {
        let (bk, bf) = b.get(name).cloned().unwrap_or_default();
        let (ak, af) = a.get(name).cloned().unwrap_or_default();
        if bf != af {
            // A changed item defines itself and every member its users name
            // through it, on either side of the change.
            let mut names: BTreeSet<String> = BTreeSet::from([(*name).to_owned()]);
            for item in after
                .items
                .iter()
                .chain(&before.items)
                .filter(|i| i.name == *name)
            {
                names.extend(item.members.iter().cloned());
            }
            let contract =
                ak.contains(&Kind::Contract) || ak.is_empty() && bk.contains(&Kind::Contract);
            // Private as the change leaves it: after the change, or before
            // it for an item the change deletes.
            let side = if a.contains_key(name) {
                &after
            } else {
                &before
            };
            if contract {
                out.contracts.extend(names.iter().cloned());
            } else if side
                .items
                .iter()
                .filter(|i| i.name == *name)
                .all(|i| !i.public)
            {
                out.private.insert((*name).to_owned());
            }
            out.defs.extend(names);
        }
    }
    out.refs = added_refs(lang, old, new, &before, &after);
    out
}

/// The names whose uses a change from `old` to `new` adds. A use counts
/// when the change inserts it: among the tokens of a top-level unit it
/// changes, diffed against that unit's old version, or anywhere in a unit
/// it adds. A unit it only moves or reformats adds no use, though a line
/// diff sees its lines as new. A use outside every unit counts when its
/// line is new.
fn added_refs(
    lang: Lang,
    old: Option<&str>,
    new: Option<&str>,
    before: &Parsed,
    after: &Parsed,
) -> BTreeSet<String> {
    let Some(new) = new else {
        return BTreeSet::new();
    };
    let old_text = old.unwrap_or_default();
    let (bu, au) = (
        old.map(|t| units(lang, t)).unwrap_or_default(),
        units(lang, new),
    );
    let names = |p: &Parsed, u: &Unit| -> BTreeSet<String> {
        p.items
            .iter()
            .filter(|i| u.bytes.start <= i.bytes.start && i.bytes.end <= u.bytes.end)
            .map(|i| i.name.clone())
            .collect()
    };
    let (bn, an): (Vec<_>, Vec<_>) = (
        bu.iter().map(|u| names(before, u)).collect(),
        au.iter().map(|u| names(after, u)).collect(),
    );
    // Each new unit's old version: one with the same items and tokens (it
    // moved or was reformatted), or else the one sharing the most items.
    let mut taken = vec![false; bu.len()];
    let mut old_of: Vec<Option<usize>> = vec![None; au.len()];
    for (k, a) in au.iter().enumerate() {
        old_of[k] = (0..bu.len())
            .find(|&j| !taken[j] && bu[j].fingerprint == a.fingerprint && bn[j] == an[k]);
        if let Some(j) = old_of[k] {
            taken[j] = true;
        }
    }
    for k in 0..au.len() {
        if old_of[k].is_some() {
            continue;
        }
        old_of[k] = (0..bu.len())
            .filter(|&j| !taken[j])
            .map(|j| (bn[j].intersection(&an[k]).count(), j))
            .filter(|(shared, _)| *shared > 0)
            .max_by_key(|(shared, j)| (*shared, std::cmp::Reverse(*j)))
            .map(|(_, j)| j);
        if let Some(j) = old_of[k] {
            taken[j] = true;
        }
    }
    // The bytes of the new text where the change inserted something.
    let mut inserted: Vec<Range<usize>> = Vec::new();
    for (k, a) in au.iter().enumerate() {
        match old_of[k] {
            Some(j) if bu[j].fingerprint == a.fingerprint => {}
            Some(j) => {
                let was: Vec<&str> = bu[j].tokens.iter().map(|r| &old_text[r.clone()]).collect();
                let is: Vec<&str> = a.tokens.iter().map(|r| &new[r.clone()]).collect();
                for op in capture_diff_slices(Algorithm::Myers, &was, &is) {
                    if let DiffOp::Insert {
                        new_index, new_len, ..
                    }
                    | DiffOp::Replace {
                        new_index, new_len, ..
                    } = op
                    {
                        inserted.extend(a.tokens[new_index..new_index + new_len].iter().cloned());
                    }
                }
            }
            None => inserted.push(a.bytes.clone()),
        }
    }
    let lines = added_lines(old_text, new);
    after
        .refs
        .iter()
        .filter(|r| {
            let in_unit = au
                .iter()
                .any(|u| u.bytes.start <= r.bytes.start && r.bytes.end <= u.bytes.end);
            if in_unit {
                inserted
                    .iter()
                    .any(|i| i.start < r.bytes.end && r.bytes.start < i.end)
            } else {
                lines.iter().any(|l| l.contains(&r.line))
            }
        })
        .map(|r| r.name.clone())
        .collect()
}

/// The contracts in the files a change touches, after the change: each
/// contract's name and fingerprint. Two versions of a change with the same
/// contracts leave their dependents' interface alone.
pub fn contract_api(files: &[FileDiff]) -> BTreeMap<String, Vec<u64>> {
    let mut out: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    for f in files.iter().filter(|f| !f.binary && f.new_path.is_some()) {
        let Some(lang) = Lang::of_path(f.path()) else {
            continue;
        };
        for item in parse(lang, &f.new)
            .items
            .into_iter()
            .filter(|i| i.kind == Kind::Contract)
        {
            out.entry(item.name).or_default().push(item.fingerprint);
        }
    }
    for fps in out.values_mut() {
        fps.sort_unstable();
    }
    out
}

/// What a whole change defines and references. Its contract part is the
/// one the split plans for the whole change, since a new Rust module moves
/// with the `mod` another file declares it with.
pub fn change_symbols(files: &[FileDiff]) -> Symbols {
    let mut out = Symbols::default();
    for f in files {
        out.merge(file_symbols(f));
    }
    out.hoisted.clear();
    out.crefs.clear();
    out.cfiles.clear();
    let plan = crate::hoist::plan(files, crate::hoist::Split::Contracts);
    for f in files {
        let (Some(part), Some(lang)) = (plan.get(f.path()), Lang::of_path(f.path())) else {
            continue;
        };
        let old = f.old_path.as_ref().map(|_| f.old.as_str());
        let moved = between(lang, old, Some(part));
        out.hoisted.extend(moved.defs);
        out.crefs.extend(moved.refs);
        out.cfiles.insert(f.path().to_owned());
    }
    out
}

// ---------------------------------------------------------------------
// Top-level units, which a split moves whole
// ---------------------------------------------------------------------

/// One name an import binds, and an import of that name alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    /// The name the import binds in the file, or `*` for a glob.
    pub name: String,
    /// An import of this name alone.
    pub text: String,
}

/// What a top-level unit is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Role {
    /// What must come first: a Go package clause, Rust inner attributes, a
    /// Python docstring or `__future__` import, a JavaScript directive or
    /// `#!` line.
    Prologue,
    /// An import, and what it binds.
    Import(Vec<Binding>),
    Other,
}

/// A statement or item directly in a file (in Nix, a binding of the
/// module's attribute set), with the doc comments and attributes above it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unit {
    pub bytes: Range<usize>,
    /// Its tokens without comments or layout.
    pub fingerprint: u64,
    pub role: Role,
    /// The bytes of its tokens, comments left out, in order.
    pub tokens: Vec<Range<usize>>,
}

/// The bytes of every token from `first` through its siblings to `last`,
/// comments left out.
fn tokens(first: Node, last: Node) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut n = first;
    loop {
        let mut cursor = n.walk();
        let mut stack = vec![n];
        while let Some(m) = stack.pop() {
            if is_comment(m.kind()) {
                continue;
            }
            if m.child_count() == 0 {
                out.push(m.byte_range());
            } else {
                let children: Vec<Node> = m.children(&mut cursor).collect();
                stack.extend(children.into_iter().rev());
            }
        }
        if n.id() == last.id() || n.end_byte() >= last.end_byte() {
            break;
        }
        match n.next_sibling() {
            Some(next) => n = next,
            None => break,
        }
    }
    out
}

/// A file's top-level units, in order. Comments that belong to no unit
/// are not units.
pub fn units(lang: Lang, text: &str) -> Vec<Unit> {
    let Some(tree) = parse_tree(lang, text) else {
        return Vec::new();
    };
    let root = tree.root_node();
    let parent = if lang == Lang::Nix {
        let set = nix::root_set(root).and_then(|s| {
            let mut cursor = s.walk();
            s.named_children(&mut cursor)
                .find(|c| c.kind() == "binding_set")
        });
        match set {
            Some(set) => set,
            None => return Vec::new(),
        }
    } else {
        root
    };
    let mut cursor = parent.walk();
    let mut out = Vec::new();
    let mut opening = true;
    for node in parent.named_children(&mut cursor) {
        if is_comment(node.kind()) || node.kind() == "attribute_item" {
            continue;
        }
        let role = role_of(lang, node, text, opening);
        opening &= role == Role::Prologue;
        let first = leading(lang, node, text);
        out.push(Unit {
            bytes: first.start_byte()..node.end_byte(),
            fingerprint: item_fingerprint(first, node, text),
            role,
            tokens: tokens(first, node),
        });
    }
    out
}

// ---------------------------------------------------------------------
// Edits item by item, for merges jj's text merge did not make
// ---------------------------------------------------------------------

/// A part of a file as an edit sees it. Two versions of a file hold the
/// same pieces when they hold the same items, statements, and comments, in
/// whatever order and layout.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Piece {
    /// A named item and its syntax. An item that holds others (a class and
    /// its methods) counts only its own tokens; each item inside it is a
    /// piece of its own.
    Item(String, u64),
    /// What a top-level unit holds outside every named item: an import, a
    /// statement, the header of an `impl` block.
    Unit(u64),
    /// A comment, by its text.
    Comment(String),
    /// The tokens outside every unit, such as a Nix module's arguments.
    Rest(u64),
}

fn hash_tokens<'a>(tokens: impl IntoIterator<Item = &'a str>) -> u64 {
    let mut h = DefaultHasher::new();
    for t in tokens {
        t.hash(&mut h);
    }
    h.finish()
}

/// A file's pieces, sorted, or None when tree-sitter finds a syntax error,
/// which leaves its items unreliable.
pub fn pieces(lang: Lang, text: &str) -> Option<Vec<Piece>> {
    let tree = parse_tree(lang, text)?;
    let root = tree.root_node();
    if root.has_error() {
        return None;
    }
    let items = parse(lang, text).items;
    let units = units(lang, text);
    let inside = |inner: &Range<usize>, outer: &Range<usize>| {
        outer.start <= inner.start && inner.end <= outer.end
    };
    // Each token belongs to the innermost item around it, if any.
    let owner = |t: &Range<usize>| {
        items
            .iter()
            .enumerate()
            .filter(|(_, i)| inside(t, &i.bytes))
            .min_by_key(|(_, i)| i.bytes.len())
            .map(|(k, _)| k)
    };
    let tokens: Vec<(Range<usize>, Option<usize>)> = tokens(root, root)
        .into_iter()
        .filter(|t| !t.is_empty())
        .map(|t| {
            let o = owner(&t);
            (t, o)
        })
        .collect();
    let mut out = Vec::new();
    for (k, item) in items.iter().enumerate() {
        let holds_another = items
            .iter()
            .any(|j| j.bytes.len() < item.bytes.len() && inside(&j.bytes, &item.bytes));
        let fingerprint = if holds_another {
            hash_tokens(
                tokens
                    .iter()
                    .filter(|(_, o)| *o == Some(k))
                    .map(|(t, _)| &text[t.clone()]),
            )
        } else {
            item.fingerprint
        };
        out.push(Piece::Item(item.name.clone(), fingerprint));
    }
    for unit in &units {
        if !items.iter().any(|i| inside(&i.bytes, &unit.bytes)) {
            out.push(Piece::Unit(unit.fingerprint));
            continue;
        }
        let rest: Vec<&str> = tokens
            .iter()
            .filter(|(t, o)| o.is_none() && inside(t, &unit.bytes))
            .map(|(t, _)| &text[t.clone()])
            .collect();
        if !rest.is_empty() {
            out.push(Piece::Unit(hash_tokens(rest)));
        }
    }
    let outside: Vec<&str> = tokens
        .iter()
        .filter(|(t, o)| o.is_none() && !units.iter().any(|u| inside(t, &u.bytes)))
        .map(|(t, _)| &text[t.clone()])
        .collect();
    if !outside.is_empty() {
        out.push(Piece::Rest(hash_tokens(outside)));
    }
    let mut cursor = root.walk();
    let mut stack = vec![root];
    while let Some(n) = stack.pop() {
        if is_comment(n.kind()) {
            out.push(Piece::Comment(text[n.byte_range()].trim_end().to_owned()));
        } else {
            stack.extend(n.children(&mut cursor));
        }
    }
    out.sort();
    Some(out)
}

/// What changing a file from `old` to `new` (None: it does not exist on
/// that side) does to its pieces: those it removes and those it adds, each
/// sorted. None when either side does not parse cleanly.
pub fn piece_edit(
    lang: Lang,
    old: Option<&str>,
    new: Option<&str>,
) -> Option<(Vec<Piece>, Vec<Piece>)> {
    let side = |t: Option<&str>| t.map_or(Some(Vec::new()), |t| pieces(lang, t));
    let (before, after) = (side(old)?, side(new)?);
    let minus = |a: &[Piece], b: &[Piece]| {
        let mut left: BTreeMap<&Piece, usize> = BTreeMap::new();
        for p in b {
            *left.entry(p).or_default() += 1;
        }
        a.iter()
            .filter(|p| match left.get_mut(p) {
                Some(n) if *n > 0 => {
                    *n -= 1;
                    false
                }
                _ => true,
            })
            .cloned()
            .collect::<Vec<_>>()
    };
    Some((minus(&before, &after), minus(&after, &before)))
}

/// A statement made only of a string: a docstring or a directive.
fn is_string_statement(node: Node) -> bool {
    node.kind() == "expression_statement"
        && node.named_child_count() == 1
        && node
            .named_child(0)
            .is_some_and(|c| matches!(c.kind(), "string" | "concatenated_string"))
}

/// What a top-level node is; `opening` says whether only prologue came
/// before it.
fn role_of(lang: Lang, node: Node, text: &str, opening: bool) -> Role {
    use Lang::*;
    match (lang, node.kind()) {
        (Go, "package_clause")
        | (Rust, "inner_attribute_item")
        | (Python, "future_import_statement")
        | (TypeScript | Tsx | JavaScript, "hash_bang_line") => Role::Prologue,
        (Python | TypeScript | Tsx | JavaScript, "expression_statement")
            if opening && is_string_statement(node) =>
        {
            Role::Prologue
        }
        (Rust, "use_declaration" | "extern_crate_declaration") => {
            Role::Import(rust_bindings(node, text))
        }
        (Rust, "mod_item") if node.child_by_field_name("body").is_none() => {
            let name = node
                .child_by_field_name("name")
                .map(|n| text[n.byte_range()].to_owned())
                .unwrap_or_default();
            Role::Import(vec![Binding {
                name,
                text: text[node.byte_range()].to_owned(),
            }])
        }
        (Python, "import_statement" | "import_from_statement") => {
            Role::Import(python_bindings(node, text))
        }
        (TypeScript | Tsx | JavaScript, "import_statement") => {
            Role::Import(js_bindings(node, text))
        }
        (Go, "import_declaration") => Role::Import(go_bindings(node, text)),
        _ => Role::Other,
    }
}

fn last_segment(path: &str, separator: &str) -> String {
    path.rsplit(separator).next().unwrap_or(path).to_owned()
}

fn rust_bindings(node: Node, text: &str) -> Vec<Binding> {
    let mut cursor = node.walk();
    let vis = node
        .named_children(&mut cursor)
        .find(|c| c.kind() == "visibility_modifier")
        .map(|v| format!("{} ", &text[v.byte_range()]))
        .unwrap_or_default();
    if node.kind() == "extern_crate_declaration" {
        let name = node
            .child_by_field_name("alias")
            .or_else(|| node.child_by_field_name("name"))
            .map(|n| text[n.byte_range()].to_owned())
            .unwrap_or_default();
        return vec![Binding {
            name,
            text: text[node.byte_range()].to_owned(),
        }];
    }
    let Some(argument) = node.child_by_field_name("argument") else {
        return Vec::new();
    };
    let mut paths = Vec::new();
    flatten_use(argument, "", text, &mut paths);
    paths
        .into_iter()
        .map(|(path, alias)| Binding {
            name: alias.clone().unwrap_or_else(|| last_segment(&path, "::")),
            text: match alias {
                Some(alias) => format!("{vis}use {path} as {alias};"),
                None => format!("{vis}use {path};"),
            },
        })
        .collect()
}

/// The paths a Rust use tree imports, each with its alias.
fn flatten_use(node: Node, prefix: &str, text: &str, out: &mut Vec<(String, Option<String>)>) {
    let join = |rest: &str| {
        if prefix.is_empty() {
            rest.to_owned()
        } else {
            format!("{prefix}::{rest}")
        }
    };
    match node.kind() {
        "use_as_clause" => {
            let path = node
                .child_by_field_name("path")
                .map(|p| join(&text[p.byte_range()]));
            let alias = node
                .child_by_field_name("alias")
                .map(|a| text[a.byte_range()].to_owned());
            if let Some(path) = path {
                out.push((path, alias));
            }
        }
        "use_list" => {
            let mut cursor = node.walk();
            for child in node.named_children(&mut cursor) {
                if !is_comment(child.kind()) {
                    flatten_use(child, prefix, text, out);
                }
            }
        }
        "scoped_use_list" => {
            let inner = match node.child_by_field_name("path") {
                Some(p) => join(&text[p.byte_range()]),
                None => prefix.to_owned(),
            };
            if let Some(list) = node.child_by_field_name("list") {
                flatten_use(list, &inner, text, out);
            }
        }
        _ => {
            let path = &text[node.byte_range()];
            if path == "self" && !prefix.is_empty() {
                out.push((prefix.to_owned(), None));
            } else {
                out.push((join(path), None));
            }
        }
    }
}

fn python_bindings(node: Node, text: &str) -> Vec<Binding> {
    let module = node
        .child_by_field_name("module_name")
        .map(|m| &text[m.byte_range()]);
    let mut out = Vec::new();
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        let (imported, alias) = match child.kind() {
            "aliased_import" => (
                child.child_by_field_name("name"),
                child.child_by_field_name("alias"),
            ),
            "dotted_name" if Some(child) != node.child_by_field_name("module_name") => {
                (Some(child), None)
            }
            "wildcard_import" => {
                if let Some(m) = module {
                    out.push(Binding {
                        name: "*".into(),
                        text: format!("from {m} import *"),
                    });
                }
                continue;
            }
            _ => continue,
        };
        let Some(imported) = imported else { continue };
        let imported = &text[imported.byte_range()];
        let alias = alias.map(|a| &text[a.byte_range()]);
        let named = match alias {
            Some(a) => format!("{imported} as {a}"),
            None => imported.to_owned(),
        };
        out.push(match module {
            Some(m) => Binding {
                name: alias.unwrap_or(imported).to_owned(),
                text: format!("from {m} import {named}"),
            },
            // `import a.b` binds `a`.
            None => Binding {
                name: alias
                    .map(str::to_owned)
                    .unwrap_or_else(|| imported.split('.').next().unwrap_or(imported).to_owned()),
                text: format!("import {named}"),
            },
        });
    }
    out
}

fn js_bindings(node: Node, text: &str) -> Vec<Binding> {
    let Some(source) = node
        .child_by_field_name("source")
        .map(|s| &text[s.byte_range()])
    else {
        return Vec::new();
    };
    let mut cursor = node.walk();
    let children: Vec<Node> = node.children(&mut cursor).collect();
    let keyword = if children.iter().any(|c| c.kind() == "type") {
        "import type"
    } else {
        "import"
    };
    let Some(clause) = children.iter().find(|c| c.kind() == "import_clause") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut cursor = clause.walk();
    for part in clause.named_children(&mut cursor) {
        match part.kind() {
            "identifier" => {
                let name = &text[part.byte_range()];
                out.push(Binding {
                    name: name.to_owned(),
                    text: format!("{keyword} {name} from {source};"),
                });
            }
            "namespace_import" => {
                let mut c = part.walk();
                if let Some(name) = part
                    .named_children(&mut c)
                    .find(|n| n.kind() == "identifier")
                {
                    let name = &text[name.byte_range()];
                    out.push(Binding {
                        name: name.to_owned(),
                        text: format!("{keyword} * as {name} from {source};"),
                    });
                }
            }
            "named_imports" => {
                let mut c = part.walk();
                for spec in part
                    .named_children(&mut c)
                    .filter(|n| n.kind() == "import_specifier")
                {
                    let bound = spec
                        .child_by_field_name("alias")
                        .or_else(|| spec.child_by_field_name("name"));
                    if let Some(bound) = bound {
                        out.push(Binding {
                            name: text[bound.byte_range()].to_owned(),
                            text: format!(
                                "{keyword} {{ {} }} from {source};",
                                &text[spec.byte_range()]
                            ),
                        });
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn go_bindings(node: Node, text: &str) -> Vec<Binding> {
    let mut specs = Vec::new();
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        match child.kind() {
            "import_spec" => specs.push(child),
            "import_spec_list" => {
                let mut c = child.walk();
                specs.extend(
                    child
                        .named_children(&mut c)
                        .filter(|s| s.kind() == "import_spec"),
                );
            }
            _ => {}
        }
    }
    specs
        .into_iter()
        .filter_map(|spec| {
            let path = spec.child_by_field_name("path")?;
            let path = text[path.byte_range()].trim_matches(['"', '`']);
            let name = match spec.child_by_field_name("name") {
                Some(n) => text[n.byte_range()].to_owned(),
                // The package a path names is usually its last element,
                // before a major version suffix.
                None => {
                    let mut parts: Vec<&str> = path.split('/').collect();
                    if parts.len() > 1
                        && parts.last().is_some_and(|p| {
                            p.len() > 1
                                && p.starts_with('v')
                                && p[1..].chars().all(|c| c.is_ascii_digit())
                        })
                    {
                        parts.pop();
                    }
                    let last = parts.last().copied().unwrap_or(path);
                    last.split('.').next().unwrap_or(last).to_owned()
                }
            };
            Some(Binding {
                name,
                text: format!("import {}", &text[spec.byte_range()]),
            })
        })
        .collect()
}

pub(crate) use nix::{attr_names as nix_attr_names, root_set as nix_root_set};

mod nix {
    //! Nix has no item syntax, so jj-graph walks the module's attribute
    //! sets: a binding under `options` declares an option (a contract), any
    //! other binding of the module's attribute set sets a value (an
    //! implementation). References are variables, and selections from
    //! `config` by option path, with every prefix of the path, so a use of
    //! `config.a.b.c` meets a declaration of `a.b`.

    use super::*;

    const SPECIAL: [&str; 5] = ["imports", "_module", "meta", "disabledModules", "_file"];

    pub(crate) fn attr_names(attrpath: Node, text: &str) -> Option<Vec<String>> {
        let mut cursor = attrpath.walk();
        attrpath
            .children_by_field_name("attr", &mut cursor)
            .map(|a| match a.kind() {
                "identifier" => Some(text[a.byte_range()].to_owned()),
                "string_expression" => Some(text[a.byte_range()].trim_matches('"').to_owned()),
                _ => None,
            })
            .collect()
    }

    /// The attribute path of a binding, from the module's own attribute set,
    /// or `None` when the binding sits inside something else (a function
    /// argument, a list, a `let`).
    pub(crate) fn module_path(binding: Node, text: &str, root_set: Node) -> Option<Vec<String>> {
        let mut path = attr_names(binding.child_by_field_name("attrpath")?, text)?;
        let mut node = binding;
        loop {
            let set = node.parent()?; // binding_set
            let attrs = set.parent()?;
            if !matches!(
                attrs.kind(),
                "attrset_expression" | "rec_attrset_expression"
            ) {
                return None;
            }
            if attrs.id() == root_set.id() {
                return Some(path);
            }
            let outer = attrs.parent()?;
            if outer.kind() != "binding" {
                return None;
            }
            let mut prefix = attr_names(outer.child_by_field_name("attrpath")?, text)?;
            prefix.extend(path);
            path = prefix;
            node = outer;
        }
    }

    /// The module's attribute set: the file's expression, under any
    /// function header, `let`, `with`, `assert`, and parentheses.
    pub(crate) fn root_set(root: Node) -> Option<Node> {
        let mut n = root.child_by_field_name("expression")?;
        loop {
            n = match n.kind() {
                "function_expression"
                | "let_expression"
                | "with_expression"
                | "assert_expression" => n.child_by_field_name("body")?,
                "parenthesized_expression" => n.child_by_field_name("expression")?,
                "attrset_expression" | "rec_attrset_expression" => return Some(n),
                _ => return None,
            };
        }
    }

    fn select_path(node: Node, text: &str) -> Option<Vec<String>> {
        let base = node.child_by_field_name("expression")?;
        if base.kind() != "variable_expression" {
            return None;
        }
        let mut path = vec![text[base.byte_range()].to_owned()];
        path.extend(attr_names(node.child_by_field_name("attrpath")?, text)?);
        Some(path)
    }

    pub(super) fn parse(root: Node, text: &str) -> Parsed {
        let mut out = Parsed::default();
        let set = root_set(root);
        let mut walker = root.walk();
        let mut stack = vec![root];
        while let Some(n) = stack.pop() {
            match n.kind() {
                "binding" => {
                    if let Some(path) = set.and_then(|s| module_path(n, text, s)) {
                        let is_set = n.child_by_field_name("expression").is_some_and(|e| {
                            matches!(e.kind(), "attrset_expression" | "rec_attrset_expression")
                        });
                        let (kind, name) = match path.first().map(String::as_str) {
                            Some("options") => (Kind::Contract, path[1..].join(".")),
                            Some("config") => (Kind::Impl, path[1..].join(".")),
                            Some(first) if SPECIAL.contains(&first) => (Kind::Impl, String::new()),
                            _ => (Kind::Impl, path.join(".")),
                        };
                        // Only leaves define something; a set is a namespace.
                        if !is_set && !name.is_empty() {
                            out.items.push(Item {
                                name,
                                kind,
                                public: true,
                                bytes: n.byte_range(),
                                lines: n.start_position().row..n.end_position().row + 1,
                                fingerprint: fingerprint(n, text),
                                members: Vec::new(),
                            });
                        }
                    }
                }
                "select_expression" => {
                    if let Some(path) = select_path(n, text) {
                        let at = |name: String| Ref {
                            name,
                            line: n.start_position().row,
                            bytes: n.byte_range(),
                        };
                        let rest = if path[0] == "config" {
                            &path[1..]
                        } else {
                            &path[..]
                        };
                        for i in 1..=rest.len() {
                            out.refs.push(at(rest[..i].join(".")));
                        }
                        if let Some(last) = rest.last() {
                            out.refs.push(at(last.clone()));
                        }
                    }
                }
                "variable_expression" => {
                    out.refs.push(Ref {
                        name: text[n.byte_range()].to_owned(),
                        line: n.start_position().row,
                        bytes: n.byte_range(),
                    });
                }
                _ => {}
            }
            stack.extend(n.children(&mut walker));
        }
        // In the order they appear, as every other language has them.
        out.items.sort_by_key(|i| i.bytes.start);
        out.refs.sort_by_key(|r| r.bytes.start);
        out
    }
}
