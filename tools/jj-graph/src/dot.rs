//! Reading a Graphviz DOT digraph as a component diagram (the guide's
//! Section 3, Step 1), with graphviz-rust's parser.
//!
//! In a `digraph` (strict or not), every node, whether declared or only
//! named in an edge, is a component, and its label is its change's
//! description. `a -> b` means b builds on a. A chain (`a -> b -> c`) means
//! each of its edges, and a subgraph at either end (`a -> {b c}`) means an
//! edge to or from each node it holds once the statement is read, counting,
//! as Graphviz does, the nodes an earlier subgraph of the same name in the
//! same place added. Subgraphs and clusters otherwise only group.
//!
//! A node's label is the last `label` it is given, or else the default
//! (`node [label=...]`) in force where it is first named, or else its ID;
//! a label with no text stands for the ID too. Labels read as Graphviz
//! shows them: `\N` is the node's ID, `\G` the graph's (`%1` when it has
//! none), and `\E` nothing; then, outside HTML labels, `\n`, `\l`, and `\r`
//! break lines and any other `\` shows the character after it. An HTML
//! label is read as its text, with `<br/>` as a line break, entities read,
//! and raw line breaks and tabs dropped. Quoted strings joined with `+` are
//! one string. Other attributes are ignored.
//!
//! An undirected `graph` is refused, since an edge needs a direction, as is
//! `--` in a digraph, a node that builds on itself, an unquoted keyword as
//! a node ID, a node ID with `:`, which jj-graph keeps for the nodes
//! features add, and a named entity other than XML's five.
//!
//! graphviz-rust's grammar reads less than DOT: it needs the `subgraph`
//! keyword that DOT lets a subgraph omit, takes keywords only in lowercase,
//! reads a subgraph that starts a statement as a statement of its own even
//! when an edge follows, and lexes IDs more loosely than DOT. So jj-graph
//! lexes the text as DOT itself and hands graphviz-rust the same graph with
//! keywords in lowercase, every `subgraph` written out, and every ID set
//! aside behind a placeholder, which it reads back as DOT does.

use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;

use anyhow::{Result, anyhow, bail};
use graphviz_rust::dot_structures::{
    Attribute, Edge, EdgeTy, Graph, GraphAttributes, Id, Node, NodeId, Stmt, Subgraph, Vertex,
};
use graphviz_rust::printer::{DotPrinter, PrinterContext};

/// A component diagram.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Diagram {
    /// Each node's label, by node ID.
    pub labels: BTreeMap<String, String>,
    /// `(a, b)`: b builds on a.
    pub edges: BTreeSet<(String, String)>,
    /// Node IDs in the order they first appear.
    pub order: Vec<String>,
}

/// DOT's keywords, which it reads in any case.
const KEYWORDS: [&str; 6] = ["strict", "graph", "digraph", "subgraph", "node", "edge"];

/// The compass points a port may end with.
const COMPASS: [&str; 10] = ["n", "ne", "e", "se", "s", "sw", "w", "nw", "c", "_"];

fn keyword(word: &str) -> Option<&'static str> {
    KEYWORDS.into_iter().find(|k| word.eq_ignore_ascii_case(k))
}

// ---------------------------------------------------------------------
// Strings, as Graphviz reads them
// ---------------------------------------------------------------------

/// A quoted string's value: `\"` is a quote, a `\` before a line break
/// joins the lines, and any other `\` stays with the character after it.
fn value_of(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('"') => out.push('"'),
            Some('\n') => {}
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// A label with `\N` read as the node's ID, `\G` as the graph's, and `\E`
/// as nothing. Other escapes stay.
fn substituted(label: &str, node: &str, graph: &str) -> String {
    let mut out = String::with_capacity(label.len());
    let mut chars = label.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('N') => out.push_str(node),
            Some('G') => out.push_str(graph),
            Some('E') => {}
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// A label as Graphviz shows it: `\n`, `\l`, and `\r` break lines, and
/// any other `\` shows the character after it.
fn shown(label: &str) -> String {
    let mut out = String::with_capacity(label.len());
    let mut chars = label.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n' | 'l' | 'r') => out.push('\n'),
            Some(other) => out.push(other),
            None => {}
        }
    }
    out
}

/// The character an entity at the start of `s` (at its `&`) stands for,
/// and the entity's length. None when the `&` starts no entity.
fn entity(s: &str) -> Result<Option<(char, usize)>> {
    let name_end = s[1..]
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '#'))
        .map_or(s.len(), |at| at + 1);
    if name_end == 1 || !s[name_end..].starts_with(';') {
        return Ok(None);
    }
    let name = &s[1..name_end];
    let c = match name {
        "lt" => Some('<'),
        "gt" => Some('>'),
        "amp" => Some('&'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        _ => match name.strip_prefix('#') {
            Some(number) => {
                let (digits, radix) = match number.strip_prefix(['x', 'X']) {
                    Some(hex) => (hex, 16),
                    None => (number, 10),
                };
                if digits.is_empty() || !digits.chars().all(|d| d.is_digit(radix)) {
                    return Ok(None);
                }
                u32::from_str_radix(digits, radix)
                    .ok()
                    .and_then(char::from_u32)
            }
            None if name.starts_with(|c: char| c.is_ascii_alphabetic()) => {
                bail!("&{name}; is not an entity jj-graph reads; write the character itself")
            }
            None => return Ok(None),
        },
    };
    match c {
        Some(c) => Ok(Some((c, name_end + 1))),
        None => bail!("&{name}; names no character"),
    }
}

/// The text of an HTML string's content, as Graphviz shows it: tags
/// dropped, `<br/>` read as a line break, entities read, and control
/// characters, raw line breaks and tabs among them, dropped.
fn html_text(html: &str) -> Result<String> {
    let shown = |c: &char| *c >= ' ';
    let mut text = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(at) = rest.find(['<', '&']) {
        text.extend(rest[..at].chars().filter(shown));
        rest = &rest[at..];
        if rest.starts_with('<') {
            let close = rest.find('>').unwrap_or(rest.len());
            let name = rest[1..close]
                .trim_start()
                .split(|c: char| !c.is_ascii_alphanumeric())
                .next()
                .unwrap_or_default();
            if name.eq_ignore_ascii_case("br") {
                text.push('\n');
            }
            rest = &rest[(close + 1).min(rest.len())..];
        } else if let Some((c, len)) = entity(rest)? {
            text.extend(Some(c).filter(shown));
            rest = &rest[len..];
        } else {
            text.push('&');
            rest = &rest[1..];
        }
    }
    text.extend(rest.chars().filter(shown));
    Ok(text)
}

fn clean(label: &str) -> String {
    label
        .lines()
        .map(str::trim)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

// ---------------------------------------------------------------------
// Lexing DOT
// ---------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    /// A keyword, or an ID of letters, digits, and underscores.
    Word,
    Numeral,
    Quoted,
    Html,
    Open,
    Close,
    /// `->` or `--`.
    Arrow,
    /// Any other character: `[`, `]`, `;`, `,`, `=`, `:`, `+`, or one DOT
    /// has no use for, which graphviz-rust then refuses.
    Other,
}

#[derive(Clone, Debug)]
struct Token {
    kind: Kind,
    span: Range<usize>,
    /// The line breaks between this token and the one before.
    breaks: usize,
}

/// The line of byte `at`.
fn line_of(text: &str, at: usize) -> usize {
    text[..at].matches('\n').count() + 1
}

/// Where an HTML string opening at `start` ends: after the `>` that
/// balances its `<`.
fn html_end(b: &[u8], start: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (p, &c) in b.iter().enumerate().skip(start) {
        match c {
            b'<' => depth += 1,
            b'>' => {
                depth -= 1;
                if depth == 0 {
                    return Some(p + 1);
                }
            }
            _ => {}
        }
    }
    None
}

/// The tokens of DOT text. Comments and white space are dropped, but their
/// line breaks are counted. `#` starts a comment anywhere, as Graphviz and
/// graphviz-rust both read it.
fn tokens(text: &str) -> Result<Vec<Token>> {
    let b = text.as_bytes();
    let name = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c >= 0x80;
    let digits = |mut i: usize| {
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        i
    };
    let line_end = |mut i: usize| {
        while i < b.len() && !matches!(b[i], b'\n' | b'\r') {
            i += 1;
        }
        i
    };
    let mut out = Vec::new();
    let mut breaks = 0;
    let mut i = 0;
    while i < b.len() {
        let start = i;
        let kind = match b[i] {
            b'\n' => {
                breaks += 1;
                i += 1;
                continue;
            }
            c if c.is_ascii_whitespace() => {
                i += 1;
                continue;
            }
            b'#' => {
                i = line_end(i);
                continue;
            }
            b'/' if b.get(i + 1) == Some(&b'/') => {
                i = line_end(i);
                continue;
            }
            b'/' if b.get(i + 1) == Some(&b'*') => {
                let Some(at) = text[i + 2..].find("*/") else {
                    bail!("line {}: a comment is never closed", line_of(text, start));
                };
                i += at + 4;
                breaks += text[start..i].matches('\n').count();
                continue;
            }
            b'"' => {
                i += 1;
                while i < b.len() && b[i] != b'"' {
                    i += if b[i] == b'\\' { 2 } else { 1 };
                }
                if i >= b.len() {
                    bail!(
                        "line {}: a quoted string is never closed",
                        line_of(text, start)
                    );
                }
                i += 1;
                Kind::Quoted
            }
            b'<' => {
                let Some(end) = html_end(b, i) else {
                    bail!(
                        "line {}: an HTML string is never closed",
                        line_of(text, start)
                    );
                };
                i = end;
                Kind::Html
            }
            b'{' => {
                i += 1;
                Kind::Open
            }
            b'}' => {
                i += 1;
                Kind::Close
            }
            b'-' if matches!(b.get(i + 1), Some(b'>' | b'-')) => {
                i += 2;
                Kind::Arrow
            }
            // A numeral: `-`, then digits with an optional fraction, or a
            // fraction alone.
            c if c.is_ascii_digit()
                || c == b'.' && b.get(i + 1).is_some_and(u8::is_ascii_digit)
                || c == b'-'
                    && b.get(i + 1).is_some_and(|&d| {
                        d.is_ascii_digit()
                            || d == b'.' && b.get(i + 2).is_some_and(u8::is_ascii_digit)
                    }) =>
            {
                if c == b'-' {
                    i += 1;
                }
                i = digits(i);
                if b.get(i) == Some(&b'.') {
                    i = digits(i + 1);
                }
                Kind::Numeral
            }
            c if c.is_ascii_alphabetic() || c == b'_' || c >= 0x80 => {
                while i < b.len() && name(b[i]) {
                    i += 1;
                }
                Kind::Word
            }
            _ => {
                i += 1;
                Kind::Other
            }
        };
        out.push(Token {
            kind,
            span: start..i,
            breaks,
        });
        breaks = 0;
    }
    Ok(out)
}

// ---------------------------------------------------------------------
// Spelling DOT within graphviz-rust's grammar
// ---------------------------------------------------------------------

/// What a placeholder ID stands for.
#[derive(Clone, Debug)]
enum Literal {
    /// An unquoted ID: a name or a numeral.
    Plain(String),
    /// A quoted string's body, its escapes unread.
    Quoted(String),
    /// An HTML string's content, between its outer brackets.
    Html(String),
    /// The subgraph statement just before, which an edge starts from.
    Previous,
}

/// The text spelled within graphviz-rust's grammar, and what its
/// placeholders stand for. Keywords are in lowercase, `subgraph` is written
/// before each subgraph's brace that lacks it (every brace after the
/// graph's own opens a subgraph), every ID is a placeholder, and an edge
/// that starts from a subgraph starts from a placeholder standing for the
/// subgraph, which then comes before it as a statement of its own. Every
/// token keeps its line.
fn within_grammar(text: &str) -> Result<(String, BTreeMap<String, Literal>)> {
    let toks = tokens(text)?;
    let word = |k: usize| &text[toks[k].span.clone()];
    let is = |k: usize, kind: Kind, s: &str| toks[k].kind == kind && word(k) == s;
    let is_subgraph = |k: usize| toks[k].kind == Kind::Word && keyword(word(k)) == Some("subgraph");
    // Where the ID that ends at token `end` starts, if one does there; a
    // `+` joins quoted strings into one.
    let id_start = |end: usize| match toks[end].kind {
        Kind::Word if keyword(word(end)).is_none() => Some(end),
        Kind::Numeral | Kind::Html => Some(end),
        Kind::Quoted => {
            let mut start = end;
            while start >= 2
                && is(start - 1, Kind::Other, "+")
                && toks[start - 2].kind == Kind::Quoted
            {
                start -= 2;
            }
            Some(start)
        }
        _ => None,
    };

    // Each brace's partner.
    let mut partner = vec![0; toks.len()];
    let mut open = Vec::new();
    for (k, t) in toks.iter().enumerate() {
        match t.kind {
            Kind::Open => open.push(k),
            Kind::Close => {
                let Some(o) = open.pop() else {
                    bail!(
                        "line {}: a `}}` closes nothing",
                        line_of(text, t.span.start)
                    );
                };
                partner[o] = k;
                partner[k] = o;
            }
            _ => {}
        }
    }
    if let Some(&o) = open.last() {
        bail!(
            "line {}: a `{{` is never closed",
            line_of(text, toks[o].span.start)
        );
    }

    // Placeholders start with a prefix the text never holds.
    let mut prefix = String::from("jjgraph");
    while text.contains(prefix.as_str()) {
        prefix.push('_');
    }
    let mut literals = BTreeMap::new();
    let mut set_aside = |out: &mut String, literal: Literal| {
        let key = format!("{prefix}{}", literals.len());
        out.push(' ');
        out.push_str(&key);
        literals.insert(key, literal);
    };
    let mut out = String::with_capacity(text.len() + 64);
    let mut directed = None;
    let mut depth = 0usize;
    // Closing braces of subgraphs an edge starts from.
    let mut starts = BTreeSet::new();
    let mut k = 0;
    while k < toks.len() {
        let t = &toks[k];
        out.push_str(&"\n".repeat(t.breaks));
        let s = word(k);
        match t.kind {
            Kind::Word => match keyword(s) {
                Some(kw) => {
                    if depth == 0 && matches!(kw, "graph" | "digraph") {
                        directed = Some(kw == "digraph");
                    }
                    out.push(' ');
                    out.push_str(kw);
                }
                // A port's compass point.
                None if k > 0 && is(k - 1, Kind::Other, ":") && COMPASS.contains(&s) => {
                    out.push(' ');
                    out.push_str(s);
                }
                None => set_aside(&mut out, Literal::Plain(s.to_owned())),
            },
            Kind::Numeral => set_aside(&mut out, Literal::Plain(s.to_owned())),
            Kind::Quoted => {
                let mut body = s[1..s.len() - 1].to_owned();
                let mut breaks = 0;
                while k + 2 < toks.len()
                    && is(k + 1, Kind::Other, "+")
                    && toks[k + 2].kind == Kind::Quoted
                {
                    breaks += toks[k + 1].breaks + toks[k + 2].breaks;
                    k += 2;
                    let next = word(k);
                    body.push_str(&next[1..next.len() - 1]);
                }
                set_aside(&mut out, Literal::Quoted(body));
                out.push_str(&"\n".repeat(breaks));
            }
            Kind::Html => set_aside(&mut out, Literal::Html(s[1..s.len() - 1].to_owned())),
            Kind::Open => {
                if depth > 0 {
                    // The subgraph's first token: `subgraph`, or this brace.
                    let first = match k.checked_sub(1) {
                        Some(p) if is_subgraph(p) => p,
                        Some(p) => match id_start(p) {
                            Some(id) if id > 0 && is_subgraph(id - 1) => id - 1,
                            _ => k,
                        },
                        None => k,
                    };
                    if first == k {
                        out.push_str(" subgraph");
                    }
                    let follows_arrow = first > 0 && toks[first - 1].kind == Kind::Arrow;
                    let close = partner[k];
                    if !follows_arrow && toks.get(close + 1).is_some_and(|t| t.kind == Kind::Arrow)
                    {
                        starts.insert(close);
                    }
                }
                depth += 1;
                out.push_str(" {");
            }
            Kind::Close => {
                depth = depth.saturating_sub(1);
                out.push_str(" }");
                if starts.contains(&k) {
                    set_aside(&mut out, Literal::Previous);
                }
            }
            Kind::Arrow => {
                if s == "--" && directed == Some(true) {
                    bail!(
                        "line {}: `--` joins the nodes of an undirected graph; a digraph's edges are `->`",
                        line_of(text, t.span.start)
                    );
                }
                out.push(' ');
                out.push_str(s);
            }
            Kind::Other => {
                out.push(' ');
                out.push_str(s);
            }
        }
        k += 1;
    }
    Ok((out, literals))
}

/// graphviz-rust's complaint about the respelled text, told against the
/// text as written, whose lines it kept.
fn unreadable(text: &str, error: &str) -> anyhow::Error {
    let line = error
        .split("--> ")
        .nth(1)
        .and_then(|rest| rest.split(':').next())
        .and_then(|n| n.trim().parse::<usize>().ok());
    let expected = error
        .lines()
        .rev()
        .find_map(|l| l.trim().strip_prefix("= "))
        .unwrap_or("not DOT");
    match line.and_then(|n| Some((n, text.lines().nth(n.checked_sub(1)?)?))) {
        Some((n, source)) => anyhow!("line {n}: {expected}: {}", source.trim()),
        None => anyhow!("not a Graphviz graph: {expected}"),
    }
}

// ---------------------------------------------------------------------
// Reading the graph
// ---------------------------------------------------------------------

/// What an ID says.
enum Said<'a> {
    Plain(&'a str),
    /// A quoted string's body.
    Quoted(&'a str),
    /// An HTML string's content.
    Html(&'a str),
    /// The subgraph statement before.
    Previous,
}

/// One subgraph among those around a statement. A named subgraph reopens
/// wherever its name recurs in the same place; an anonymous one never does.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Scope {
    Named(String),
    Anonymous(usize),
}

/// Where a statement sits: the subgraphs around it, outermost first.
type Place = Vec<Scope>;

/// One end of an edge.
enum End {
    Node(String),
    Subgraph(Place),
}

struct Reader {
    d: Diagram,
    literals: BTreeMap<String, Literal>,
    /// The graph's name, which `\G` stands for.
    graph: String,
    /// The subgraph being read; empty at the top level.
    place: Place,
    /// The nodes each subgraph holds so far.
    members: BTreeMap<Place, BTreeSet<String>>,
    /// The default node label each subgraph, or the graph, set last.
    defaults: BTreeMap<Place, Id>,
    anonymous: usize,
}

impl Reader {
    fn said<'a>(&'a self, id: &'a Id) -> Said<'a> {
        match id {
            Id::Plain(s) => match self.literals.get(s) {
                Some(Literal::Plain(text)) => Said::Plain(text),
                Some(Literal::Quoted(body)) => Said::Quoted(body),
                Some(Literal::Html(content)) => Said::Html(content),
                Some(Literal::Previous) => Said::Previous,
                None => Said::Plain(s),
            },
            Id::Anonymous(s) => Said::Plain(s),
            // graphviz-rust never sees a string, but read any it reports.
            Id::Escaped(s) => Said::Quoted(
                s.strip_prefix('"')
                    .and_then(|s| s.strip_suffix('"'))
                    .unwrap_or(s),
            ),
            Id::Html(s) => Said::Html(
                s.strip_prefix('<')
                    .and_then(|s| s.strip_suffix('>'))
                    .unwrap_or(s),
            ),
        }
    }

    /// The text of an ID.
    fn text(&self, id: &Id) -> Result<String> {
        Ok(match self.said(id) {
            Said::Plain(s) => s.to_owned(),
            Said::Quoted(body) => value_of(body),
            Said::Html(content) => html_text(content)?,
            Said::Previous => bail!("jj-graph misplaced a subgraph an edge starts from"),
        })
    }

    /// Give a node a label: `value`'s text, or the node's ID when there is
    /// no value or it has no text.
    fn set_label(&mut self, node: &str, value: Option<&Id>) -> Result<()> {
        let text = match value.map(|v| self.said(v)) {
            None => String::new(),
            Some(Said::Plain(s)) => shown(&substituted(s, node, &self.graph)),
            Some(Said::Quoted(body)) => shown(&substituted(&value_of(body), node, &self.graph)),
            // Graphviz substitutes in an HTML label's text, but reads no
            // other escapes there.
            Some(Said::Html(content)) => substituted(&html_text(content)?, node, &self.graph),
            Some(Said::Previous) => bail!("jj-graph misplaced a subgraph an edge starts from"),
        };
        let text = clean(&text);
        let label = if text.is_empty() {
            node.to_owned()
        } else {
            text
        };
        self.d.labels.insert(node.to_owned(), label);
        Ok(())
    }

    /// Name a node here, declaring it with the default label in force,
    /// the innermost one set, if it is new.
    fn node(&mut self, id: &NodeId) -> Result<String> {
        // Keywords are never set aside, so graphviz-rust read this one as
        // an ID.
        if let Id::Plain(word) = &id.0
            && keyword(word).is_some()
        {
            bail!("node {word:?} is a DOT keyword; quote it to use it as a node ID");
        }
        let name = self.text(&id.0)?;
        if name.contains(':') {
            bail!("node {name:?} has a `:`, which jj-graph keeps for the changes features add");
        }
        if name.is_empty() {
            bail!("a node has an empty ID");
        }
        if !self.d.labels.contains_key(&name) {
            self.d.order.push(name.clone());
            let default = (0..=self.place.len())
                .rev()
                .find_map(|k| self.defaults.get(&self.place[..k]))
                .cloned();
            self.set_label(&name, default.as_ref())?;
        }
        for k in 1..=self.place.len() {
            self.members
                .entry(self.place[..k].to_vec())
                .or_default()
                .insert(name.clone());
        }
        Ok(name)
    }

    /// Read a subgraph and return its place.
    fn subgraph(&mut self, sub: &Subgraph) -> Result<Place> {
        let scope = match &sub.id {
            Id::Anonymous(_) => {
                self.anonymous += 1;
                Scope::Anonymous(self.anonymous)
            }
            id => Scope::Named(self.text(id)?),
        };
        self.place.push(scope);
        self.members.entry(self.place.clone()).or_default();
        let read = self.stmts(&sub.stmts);
        let place = self.place.clone();
        self.place.pop();
        read.map(|()| place)
    }

    /// Read an edge statement; `previous` is the place of the subgraph
    /// statement before it, if it was one.
    fn edge(&mut self, e: &Edge, previous: Option<&Place>) -> Result<()> {
        let vertices: Vec<&Vertex> = match &e.ty {
            EdgeTy::Pair(a, b) => vec![a, b],
            EdgeTy::Chain(vs) => vs.iter().collect(),
        };
        let mut ends = Vec::with_capacity(vertices.len());
        for (k, v) in vertices.into_iter().enumerate() {
            ends.push(match v {
                Vertex::N(id) if matches!(self.said(&id.0), Said::Previous) => {
                    match (k, previous) {
                        (0, Some(place)) => End::Subgraph(place.clone()),
                        _ => bail!("jj-graph misplaced a subgraph an edge starts from"),
                    }
                }
                Vertex::N(id) => End::Node(self.node(id)?),
                Vertex::S(sub) => End::Subgraph(self.subgraph(sub)?),
            });
        }
        let groups: Vec<BTreeSet<String>> = ends
            .into_iter()
            .map(|end| match end {
                End::Node(node) => BTreeSet::from([node]),
                End::Subgraph(place) => self.members[&place].clone(),
            })
            .collect();
        for pair in groups.windows(2) {
            for a in &pair[0] {
                for b in &pair[1] {
                    if a == b {
                        bail!("node {a:?} builds on itself");
                    }
                    self.d.edges.insert((a.clone(), b.clone()));
                }
            }
        }
        Ok(())
    }

    fn stmts(&mut self, stmts: &[Stmt]) -> Result<()> {
        let mut previous = None;
        for stmt in stmts {
            let mut subgraph = None;
            match stmt {
                Stmt::Node(Node { id, attributes }) => {
                    let name = self.node(id)?;
                    for Attribute(key, value) in attributes {
                        if self.text(key)? == "label" {
                            self.set_label(&name, Some(value))?;
                        }
                    }
                }
                Stmt::Edge(e) => self.edge(e, previous.as_ref())?,
                Stmt::Subgraph(sub) => subgraph = Some(self.subgraph(sub)?),
                Stmt::GAttribute(GraphAttributes::Node(attributes)) => {
                    for Attribute(key, value) in attributes {
                        if self.text(key)? == "label" {
                            self.defaults.insert(self.place.clone(), value.clone());
                        }
                    }
                }
                Stmt::Attribute(_) | Stmt::GAttribute(_) => {}
            }
            previous = subgraph;
        }
        Ok(())
    }
}

/// Parse a DOT digraph.
pub fn parse(text: &str) -> Result<Diagram> {
    let (spelled, literals) = within_grammar(text)?;
    let graph = graphviz_rust::parse(&spelled).map_err(|e| unreadable(text, &e))?;
    let Graph::DiGraph { id, stmts, .. } = graph else {
        bail!(
            "the diagram is an undirected `graph`; use a `digraph`, where `a -> b` means b builds on a"
        );
    };
    let mut r = Reader {
        d: Diagram::default(),
        literals,
        graph: String::new(),
        place: Vec::new(),
        members: BTreeMap::new(),
        defaults: BTreeMap::new(),
        anonymous: 0,
    };
    // Graphviz names a graph without an ID `%1`.
    r.graph = match &id {
        Id::Anonymous(_) => "%1".to_owned(),
        id => r.text(id)?,
    };
    r.stmts(&stmts)?;
    Ok(r.d)
}

/// A quoted string whose value is `value`, for any value [`parse`] reads:
/// a quote is written `\"`, and a `\` with the character after it as it is.
fn quote_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => {
                out.push('\\');
                out.extend(chars.next());
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A quoted label that Graphviz shows as `text`.
fn quote_label(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Write a diagram as a DOT digraph that [`parse`] reads back to the same
/// diagram, for any diagram it read.
pub fn render(d: &Diagram) -> String {
    let node = |id: &str| NodeId(Id::Escaped(quote_value(id)), None);
    let mut stmts: Vec<Stmt> = d
        .order
        .iter()
        .map(|id| {
            Stmt::Node(Node {
                id: node(id),
                attributes: vec![Attribute(
                    Id::Plain("label".into()),
                    Id::Escaped(quote_label(&d.labels[id])),
                )],
            })
        })
        .collect();
    stmts.extend(d.edges.iter().map(|(a, b)| {
        Stmt::Edge(Edge {
            ty: EdgeTy::Pair(Vertex::N(node(a)), Vertex::N(node(b))),
            attributes: Vec::new(),
        })
    }));
    Graph::DiGraph {
        id: Id::Plain("components".into()),
        strict: false,
        stmts,
    }
    .print(&mut PrinterContext::default())
}
