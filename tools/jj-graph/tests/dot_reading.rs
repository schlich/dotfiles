//! Reading DOT as Graphviz reads it. Graphviz's own `dot` is the oracle:
//! each example also checks that `dot -Tplain` reads its text the same way,
//! and a property reads random DOT texts with both. HTML labels' text,
//! which plain output does not show, is pinned by examples taken from what
//! `dot -Tsvg` draws.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::process::{Command, Stdio};

use hegel::TestCase;
use hegel::generators as gs;
use jj_graph::dot;

fn edges(pairs: &[(&str, &str)]) -> BTreeSet<(String, String)> {
    pairs
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
}

/// Read `text`, which Graphviz must read the same way.
fn read(text: &str) -> dot::Diagram {
    assert_eq!(agrees(text), "read", "{text}");
    dot::parse(text).unwrap_or_else(|e| panic!("{text}: {e}"))
}

// ---------------------------------------------------------------------
// Graphviz as the oracle
// ---------------------------------------------------------------------

/// A graph as `dot -Tplain` reports it: nodes in the order Graphviz made
/// them, the label each shows (None for an HTML label, whose text plain
/// output leaves out), and edges.
#[derive(Debug, Default)]
struct Plain {
    order: Vec<String>,
    labels: BTreeMap<String, Option<String>>,
    edges: BTreeSet<(String, String)>,
}

/// The fields of a line of plain output, each with whether it is an HTML
/// string. Graphviz quotes a field with spaces and escapes only its quotes.
fn fields(line: &str) -> Vec<(String, bool)> {
    let b: Vec<char> = line.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            ' ' => i += 1,
            '"' => {
                let mut text = String::new();
                i += 1;
                while i < b.len() && b[i] != '"' {
                    if b[i] == '\\' && i + 1 < b.len() {
                        if b[i + 1] != '"' {
                            text.push('\\');
                        }
                        text.push(b[i + 1]);
                        i += 2;
                    } else {
                        text.push(b[i]);
                        i += 1;
                    }
                }
                i += 1;
                out.push((text, false));
            }
            '<' => {
                let start = i;
                let mut depth = 0i32;
                while let Some(&c) = b.get(i) {
                    depth += match c {
                        '<' => 1,
                        '>' => -1,
                        _ => 0,
                    };
                    i += 1;
                    if depth == 0 {
                        break;
                    }
                }
                out.push((b[start..i].iter().collect(), true));
            }
            _ => {
                let start = i;
                while i < b.len() && b[i] != ' ' {
                    i += 1;
                }
                out.push((b[start..i].iter().collect(), false));
            }
        }
    }
    out
}

/// What Graphviz shows for a label value plain output reports, as
/// `make_simple_label` in Graphviz's lib/common/labels.c draws it: `\n`,
/// `\l`, and `\r` break lines, any other `\` shows the character after it,
/// and a trailing `\` shows nothing. jj-graph then trims each line, and a
/// label without text stands for the node's ID.
fn shown_by_graphviz(value: &str, id: &str) -> String {
    let mut out = String::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('n' | 'l' | 'r') => out.push('\n'),
                Some(other) => out.push(other),
                None => {}
            },
            c => out.push(c),
        }
    }
    let trimmed = out
        .lines()
        .map(str::trim)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned();
    if trimmed.is_empty() {
        id.to_owned()
    } else {
        trimmed
    }
}

/// Graphviz's reading of `text`, or its complaint.
fn graphviz(text: &str) -> Result<Plain, String> {
    let mut child = Command::new("dot")
        .arg("-Tplain")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Graphviz's dot, these tests' oracle, is on PATH");
    child
        .stdin
        .take()
        .expect("dot's stdin")
        .write_all(text.as_bytes())
        .expect("writing to dot");
    let out = child.wait_with_output().expect("dot runs");
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    let mut plain = Plain::default();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let f = fields(line);
        match f.first().map(|(word, _)| word.as_str()) {
            Some("node") => {
                let name = f[1].0.clone();
                let (value, html) = &f[6];
                plain.order.push(name.clone());
                plain.labels.insert(
                    name.clone(),
                    (!html).then(|| shown_by_graphviz(value, &name)),
                );
            }
            Some("edge") => {
                plain.edges.insert((f[1].0.clone(), f[2].0.clone()));
            }
            _ => {}
        }
    }
    Ok(plain)
}

/// Read `text` with jj-graph and with Graphviz, check that they agree, and
/// say how it went. jj-graph refuses a self-loop, which Graphviz draws.
fn agrees(text: &str) -> &'static str {
    let ours = dot::parse(text);
    let theirs = match graphviz(text) {
        Ok(theirs) => theirs,
        Err(e) => {
            assert!(
                ours.is_err(),
                "Graphviz refused this and jj-graph read it:\n{text}\n{e}"
            );
            return "both refused";
        }
    };
    let loops = theirs.edges.iter().any(|(a, b)| a == b);
    match ours {
        Err(e) => {
            assert!(
                loops && e.to_string().contains("builds on itself"),
                "jj-graph refused this and Graphviz read it:\n{text}\n{e}"
            );
            "self-loop refused"
        }
        Ok(d) => {
            assert!(!loops, "jj-graph read a self-loop:\n{text}");
            assert_eq!(d.order, theirs.order, "node order:\n{text}");
            assert_eq!(d.edges, theirs.edges, "edges:\n{text}");
            for (node, label) in &theirs.labels {
                if let Some(label) = label {
                    assert_eq!(&d.labels[node], label, "label of {node}:\n{text}");
                }
            }
            "read"
        }
    }
}

// ---------------------------------------------------------------------
// Examples
// ---------------------------------------------------------------------

#[test]
fn a_default_label_reaches_only_the_nodes_named_after_it() {
    let d = read(r#"digraph { a; node [label="X"]; b }"#);
    assert_eq!(d.labels["a"], "a");
    assert_eq!(d.labels["b"], "X");
    let d = read(r#"digraph { node [label="feat: \N"] a b [label="own"] }"#);
    assert_eq!(d.labels["a"], "feat: a");
    assert_eq!(d.labels["b"], "own");
}

#[test]
fn labels_name_the_node_and_the_graph() {
    assert_eq!(
        read(r#"digraph G { a [label="\G and \N"] }"#).labels["a"],
        "G and a"
    );
    assert_eq!(read(r#"digraph { a [label="[\G]"] }"#).labels["a"], "[%1]");
    assert_eq!(
        read(r#"digraph { a [label="E=\E T=\T q=\q"] }"#).labels["a"],
        "E= T=T q=q"
    );
    assert_eq!(
        read(r#"digraph { a [label="x\ny\lz\r"] }"#).labels["a"],
        "x\ny\nz"
    );
}

#[test]
fn every_substitution_in_a_label_reads() {
    // Graphviz 15.1.1 reports random bytes for these labels, so they are not
    // checked against it; each `\N` is the node's ID and `\G` the graph's,
    // as its documentation says.
    let d = dot::parse(r#"digraph G { a [label="\N\N \G-\N"] }"#).unwrap();
    assert_eq!(d.labels["a"], "aa G-a");
}

#[test]
fn a_label_without_text_stands_for_the_id() {
    assert_eq!(read(r#"digraph { a [label=""] }"#).labels["a"], "a");
}

#[test]
fn a_reopened_subgraph_stands_for_every_node_it_holds() {
    let d = read("digraph { subgraph s { a } b -> subgraph s { c } }");
    assert_eq!(d.edges, edges(&[("b", "a"), ("b", "c")]));
    // A subgraph of the same name inside another subgraph is another one.
    let d = read("digraph { subgraph s { a } { subgraph s { b } x -> subgraph s {} } }");
    assert_eq!(d.edges, edges(&[("x", "b")]));
}

#[test]
fn a_reopened_subgraph_keeps_its_default_label() {
    let d = read(r#"digraph { subgraph s { node [label="X"] a } subgraph s { b } c }"#);
    assert_eq!(
        [&d.labels["a"], &d.labels["b"], &d.labels["c"]],
        ["X", "X", "c"]
    );
    let d = read(r#"digraph { subgraph s { a } node [label="Y"] subgraph s { b } }"#);
    assert_eq!(d.labels["b"], "Y");
}

#[test]
fn html_labels_read_as_graphviz_draws_them() {
    let d = read(
        "digraph { a [label=<x\ny>]; b [label=<x<br/>y &amp; <b>z</b>>]; c [label=<p &#65;&#x42; &lt;q&gt;>]; d [label=<\\N and \\\\ x>] }",
    );
    assert_eq!(d.labels["a"], "xy");
    assert_eq!(d.labels["b"], "x\ny & z");
    assert_eq!(d.labels["c"], "p AB <q>");
    assert_eq!(d.labels["d"], "d and \\\\ x");
}

#[test]
fn keywords_read_in_any_case_and_subgraphs_need_no_keyword() {
    let d = read(r#"DiGraph { Node [label="k \N"] a; SubGraph { b } a -> {b c} }"#);
    assert_eq!(d.labels["a"], "k a");
    assert_eq!(d.labels["b"], "k b");
    assert_eq!(d.edges, edges(&[("a", "b"), ("a", "c")]));
}

#[test]
fn a_subgraph_holds_the_nodes_of_those_inside_it() {
    assert_eq!(
        read("digraph { {a {b}} -> c }").edges,
        edges(&[("a", "c"), ("b", "c")])
    );
}

#[test]
fn strings_and_comments_keep_their_braces_and_keywords() {
    let d = read(
        "digraph {\n  a [label=\"uses {b} -> c # d\"] // { e }\n  /* subgraph { f } */\n  # { g }\n  a -> \"subgraph\"\n}",
    );
    assert_eq!(d.order, ["a", "subgraph"]);
    assert_eq!(d.labels["a"], "uses {b} -> c # d");
}

#[test]
fn placeholders_never_meet_the_text_s_own_ids() {
    let d = read("digraph { jjgraph0 -> \"x\" -> jjgraph_0 }");
    assert_eq!(d.order, ["jjgraph0", "x", "jjgraph_0"]);
}

#[test]
fn errors_name_their_line() {
    let err = dot::parse("digraph {\n  a\n  b [label=\"x]\n}").unwrap_err();
    assert!(err.to_string().contains("line 3"), "{err}");
}

#[test]
fn what_graphviz_refuses_or_jj_graph_cannot_use_is_refused() {
    for text in [
        "digraph { a [label=\"x] }",
        "digraph { a [label=<x] }",
        "digraph { /* a }",
        "digraph { a [label=<&eacute;>] }",
        "digraph { node }",
        "digraph { a -> edge }",
        "digraph { a -> a }",
        "digraph { subgraph s {a} -> subgraph s {b} }",
        "digraph { \"spec:x\" -> b }",
        "graph { a -- b }",
    ] {
        assert!(dot::parse(text).is_err(), "{text}");
    }
}

// ---------------------------------------------------------------------
// Random DOT, read by both
// ---------------------------------------------------------------------

/// Node IDs as written: plain, quoted, numeric, a quoted keyword, and one
/// node written two ways.
const IDS: [&str; 8] = ["a", "b2", "_c", "d", "\"d\"", "\"x y\"", "\"Node\"", "-1.5"];

const WORDS: [&str; 6] = [
    "feat: engine",
    "uses {braces} -> x",
    "a # b",
    "c // d /* e */",
    "x <y> & z",
    "Subgraph node",
];

/// Escapes in a quoted label, a `\` before a line break among them.
const ESCAPES: [&str; 10] = [
    "\\n", "\\l", "\\r", "\\N", "\\G", "\\E", "\\q", "\\\\", "\\\"", "\\\n",
];

fn keyword(tc: &TestCase, k: &str) -> String {
    match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => k.to_owned(),
        1 => k.to_uppercase(),
        _ => k[..1].to_uppercase() + &k[1..],
    }
}

/// A label. Graphviz 15.1.1 reports random bytes for a label that
/// substitutes twice (`\N\N`, `\Nx\N`), so a label here substitutes at most
/// once, and an example pins what more mean.
fn label(tc: &TestCase) -> String {
    match tc.draw(gs::integers::<u8>().max_value(5)) {
        0 => "engine".to_owned(),
        1 => "<<b>bold</b> x<br/>y &amp; z>".to_owned(),
        _ => {
            let n = tc.draw(gs::integers::<usize>().max_value(4));
            let mut s = String::from("\"");
            let mut substituted = false;
            for _ in 0..n {
                let pieces = if tc.draw(gs::booleans()) {
                    WORDS.to_vec()
                } else {
                    ESCAPES.to_vec()
                };
                let piece = tc.draw(gs::sampled_from(pieces));
                let substitution = matches!(piece, "\\N" | "\\G" | "\\E");
                if substitution && substituted {
                    continue;
                }
                substituted |= substitution;
                s.push_str(piece);
            }
            s.push('"');
            s
        }
    }
}

/// What separates statements: nothing but a space, a `;`, a line break, or
/// a comment holding braces.
fn gap(tc: &TestCase) -> &'static str {
    tc.draw(gs::sampled_from(vec![
        " ",
        "; ",
        "\n",
        " /* { } */ ",
        "\n// { x\n",
        "\n# { y\n",
    ]))
}

fn subgraph(tc: &TestCase, depth: usize) -> String {
    let body = if depth < 2 {
        statements(tc, depth + 1)
    } else {
        String::new()
    };
    let opening = match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => String::new(),
        1 => format!("{} ", keyword(tc, "subgraph")),
        _ => format!(
            "{} {} ",
            keyword(tc, "subgraph"),
            tc.draw(gs::sampled_from(vec!["s", "cluster_t", "\"u v\""]))
        ),
    };
    format!("{opening}{{ {body}}}")
}

fn endpoint(tc: &TestCase, depth: usize) -> String {
    if depth < 2 && tc.draw(gs::weighted_booleans(0.3)) {
        return subgraph(tc, depth);
    }
    let id = tc.draw(gs::sampled_from(IDS.to_vec()));
    match tc.draw(gs::integers::<u8>().max_value(5)) {
        0 => format!("{id}:n"),
        1 => format!("{id}:\"p\""),
        _ => id.to_owned(),
    }
}

fn edge(tc: &TestCase, depth: usize) -> String {
    let n = tc.draw(gs::integers::<usize>().min_value(2).max_value(3));
    let ends: Vec<String> = (0..n).map(|_| endpoint(tc, depth)).collect();
    let mut s = ends.join(" -> ");
    if tc.draw(gs::weighted_booleans(0.2)) {
        s.push_str(" [label=\"{x}\"]");
    }
    s
}

fn statements(tc: &TestCase, depth: usize) -> String {
    let n = tc.draw(gs::integers::<usize>().max_value(if depth == 0 { 5 } else { 3 }));
    let mut out = String::new();
    for _ in 0..n {
        match tc.draw(gs::integers::<u8>().max_value(5)) {
            0 => {
                out.push_str(tc.draw(gs::sampled_from(IDS.to_vec())));
                match tc.draw(gs::integers::<u8>().max_value(3)) {
                    0 => {}
                    1 => out.push_str(&format!(" [label={}]", label(tc))),
                    2 => out.push_str(&format!(" [shape=box, label={}; color=red]", label(tc))),
                    _ => out.push_str(&format!(" [shape=box][label={}]", label(tc))),
                }
            }
            1 | 2 => out.push_str(&edge(tc, depth)),
            3 => out.push_str(&format!("{} [label={}]", keyword(tc, "node"), label(tc))),
            4 => out.push_str(tc.draw(gs::sampled_from(vec![
                "edge [color=red]",
                "graph [rankdir=LR]",
                "rankdir=LR",
                "Edge [label=\"{e}\"]",
            ]))),
            _ => out.push_str(&subgraph(tc, depth)),
        }
        out.push_str(gap(tc));
    }
    out
}

#[hegel::composite]
fn dot_texts(tc: &TestCase) -> String {
    let strict = if tc.draw(gs::booleans()) {
        format!("{} ", keyword(tc, "strict"))
    } else {
        String::new()
    };
    let id = tc.draw(gs::sampled_from(vec!["", "G ", "\"my graph\" "]));
    format!(
        "{strict}{} {id}{{\n{}}}\n",
        keyword(tc, "digraph"),
        statements(tc, 0)
    )
}

#[hegel::test(test_cases = 300)]
fn jj_graph_reads_dot_as_graphviz_does(tc: TestCase) {
    let text = tc.draw(dot_texts());
    tc.event(agrees(&text));
}
