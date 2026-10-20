//! The graph core against `spec/Normalize.qnt`.
//!
//! quint-connect simulates the specification's `NormalizeWide` instance and
//! replays every trace here: the driver builds the traced graph with this
//! crate, hoists and normalizes it, and places changes in the order the trace
//! chose. After every step, all six state variables must equal the
//! specification's. The constants below are `NormalizeWide`'s.

use std::collections::{BTreeMap, BTreeSet};

use jj_graph::graph::{Change, Graph, Id, rebase_source};
use quint_connect::*;
use serde::Deserialize;

const ORDER: [&str; 4] = ["a", "b", "c", "d"];
const CONTRACTS: [&str; 1] = ["S"];

fn bases() -> BTreeSet<Id> {
    BTreeSet::from(["t0".to_owned(), "t1".to_owned()])
}

fn base_ancestry() -> BTreeSet<(Id, Id)> {
    BTreeSet::from([("t0".to_owned(), "t1".to_owned())])
}

fn twin(v: &str) -> Id {
    format!("{v}~c")
}

/// The specification's change: it has no `contracts` field, since a symbol is
/// a contract when it is in `CONTRACTS`.
#[derive(Debug, PartialEq, Eq, Deserialize)]
struct SpecChange {
    defs: BTreeSet<String>,
    refs: BTreeSet<String>,
    files: BTreeSet<String>,
    anchor: bool,
    crefs: BTreeSet<String>,
    cfiles: BTreeSet<String>,
}

#[derive(Debug, PartialEq, Eq, Deserialize)]
struct SpecGraph {
    scope: BTreeSet<Id>,
    parents: BTreeMap<Id, BTreeSet<Id>>,
    info: BTreeMap<Id, SpecChange>,
    commutes: BTreeSet<(Id, Id)>,
}

impl From<&Graph> for SpecGraph {
    fn from(g: &Graph) -> Self {
        SpecGraph {
            scope: g.scope(),
            commutes: g.commutes.clone(),
            parents: g.parents.clone(),
            info: g
                .info
                .iter()
                .map(|(id, c)| {
                    let c = c.clone();
                    let spec = SpecChange {
                        defs: c.defs,
                        refs: c.refs,
                        files: c.files,
                        anchor: c.anchor,
                        crefs: c.crefs,
                        cfiles: c.cfiles,
                    };
                    (id.clone(), spec)
                })
                .collect(),
        }
    }
}

/// The instance's variables, which the trace names by their module path.
#[derive(Debug, PartialEq, Eq, Deserialize)]
struct SpecState {
    #[serde(rename = "NormalizeWide::Normalize::original")]
    original: SpecGraph,
    #[serde(rename = "NormalizeWide::Normalize::hoisted")]
    hoisted: SpecGraph,
    #[serde(rename = "NormalizeWide::Normalize::target")]
    target: SpecGraph,
    #[serde(rename = "NormalizeWide::Normalize::current")]
    current: SpecGraph,
    #[serde(rename = "NormalizeWide::Normalize::placed")]
    placed: BTreeSet<Id>,
    #[serde(rename = "NormalizeWide::Normalize::commands")]
    commands: u64,
}

impl State<Normalizer> for SpecState {
    fn from_driver(d: &Normalizer) -> Result<Self> {
        Ok(SpecState {
            original: (&d.original).into(),
            hoisted: (&d.hoisted).into(),
            target: (&d.target).into(),
            current: (&d.current).into(),
            placed: d.placed.clone(),
            commands: d.commands,
        })
    }
}

#[derive(Default)]
struct Normalizer {
    original: Graph,
    hoisted: Graph,
    target: Graph,
    current: Graph,
    placed: BTreeSet<Id>,
    commands: u64,
}

type Pairs = BTreeSet<(String, String)>;

fn related(rel: &Pairs, c: &str) -> BTreeSet<String> {
    rel.iter()
        .filter(|(x, _)| x == c)
        .map(|(_, y)| y.clone())
        .collect()
}

impl Normalizer {
    /// The specification's `build`: the picked edges, or the change before
    /// in ORDER (the newest base for the first change) when none were picked.
    #[allow(clippy::too_many_arguments)]
    fn init(
        &mut self,
        edges: Pairs,
        defs: Pairs,
        refs: Pairs,
        files: Pairs,
        anchors: BTreeSet<String>,
        crefs: Pairs,
        cfiles: Pairs,
        commutes: Pairs,
    ) {
        let newest_base = bases()
            .into_iter()
            .find(|b| !base_ancestry().iter().any(|(x, _)| x == b))
            .expect("the bases form a chain");
        let contracts: BTreeSet<String> = CONTRACTS.iter().map(|s| s.to_string()).collect();
        let mut g = Graph {
            bases: bases(),
            base_ancestry: base_ancestry(),
            commutes,
            ..Graph::default()
        };
        for (i, c) in ORDER.iter().enumerate() {
            let mut ps: BTreeSet<Id> = edges
                .iter()
                .filter(|(_, y)| y == c)
                .map(|(x, _)| x.clone())
                .collect();
            if ps.is_empty() {
                ps.insert(if i == 0 {
                    newest_base.clone()
                } else {
                    ORDER[i - 1].to_owned()
                });
            }
            g.parents.insert(c.to_string(), ps);
            let refs = related(&refs, c);
            let files = related(&files, c);
            let defs = related(&defs, c);
            let change = Change {
                contracts: defs.intersection(&contracts).cloned().collect(),
                defs,
                crefs: related(&crefs, c).intersection(&refs).cloned().collect(),
                cfiles: related(&cfiles, c).intersection(&files).cloned().collect(),
                refs,
                files,
                anchor: anchors.contains(*c),
            };
            g.info.insert(c.to_string(), change);
        }
        let (hoisted, _) = g.hoist(twin);
        self.target = hoisted.normal_form().unwrap_or_else(|_| hoisted.clone());
        self.current = hoisted.clone();
        self.hoisted = hoisted;
        self.original = g;
        self.placed = BTreeSet::new();
        self.commands = 0;
    }

    fn place(&mut self, v: String) {
        let onto = self.target.parents[&v].clone();
        if self.current.parents[&v] != onto {
            self.commands += 1;
        }
        self.current = rebase_source(&self.current, &v, &onto);
        self.placed.insert(v);
    }
}

impl Driver for Normalizer {
    type State = SpecState;

    fn step(&mut self, step: &Step) -> Result {
        switch!(step {
            init(
                edges: Pairs,
                defs: Pairs,
                refs: Pairs,
                files: Pairs,
                anchors: BTreeSet<String>,
                crefs: Pairs,
                cfiles: Pairs,
                commutes: Pairs
            ) => self.init(edges, defs, refs, files, anchors, crefs, cfiles, commutes),
            place(v: String) => self.place(v),
            finished => {},
        })
    }
}

#[quint_run(
    spec = "spec/Normalize.qnt",
    main = "NormalizeWide",
    max_samples = 300,
    max_steps = 10
)]
fn normal_form_and_plan_follow_the_specification() -> impl Driver {
    Normalizer::default()
}
