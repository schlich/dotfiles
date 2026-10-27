//! Change graphs and their normal form.
//!
//! This module is the executable twin of `spec/Normalize.qnt`: each function
//! here has a namesake there, and `tests/conformance.rs` replays the
//! specification's traces against them. The module documentation of the
//! specification explains the model; in short, a change must keep as an
//! ancestor every change it *requires*, and the normal form is the transitive
//! reduction of the closure of those requirements together with the base each
//! change was built on.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::{Deserialize, Serialize};

/// A change or base commit: a jj change ID, or a commit ID for a base.
pub type Id = String;

/// What one change's diff defines, references, and touches.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Change {
    /// Symbols whose definitions the diff adds, changes, or removes.
    pub defs: BTreeSet<String>,
    /// The definitions among `defs` that make up the change's contract part:
    /// contracts (traits, interfaces, protocols, schemas, module option
    /// declarations) that a split can move before the rest.
    pub contracts: BTreeSet<String>,
    /// Symbols the diff's added code references.
    pub refs: BTreeSet<String>,
    /// Paths the diff touches, on both sides of a rename.
    pub files: BTreeSet<String>,
    /// The change's tree must not change: it is a working copy, or it has a
    /// child outside the rewrite.
    pub anchor: bool,
    /// References made by the change's contract part.
    pub crefs: BTreeSet<String>,
    /// Files the change's contract part touches.
    pub cfiles: BTreeSet<String>,
}

/// The changes in scope, their parents, and the base commits below them.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Graph {
    /// Each change in scope and its parents, in scope or among `bases`.
    pub parents: BTreeMap<Id, BTreeSet<Id>>,
    /// Each change's facts; the keys are the keys of `parents`.
    pub info: BTreeMap<Id, Change>,
    /// Out-of-scope commits the scope sits on, such as trunk.
    pub bases: BTreeSet<Id>,
    /// Ancestry among `bases`: `(x, y)` when `x` is a proper ancestor of `y`.
    pub base_ancestry: BTreeSet<(Id, Id)>,
    /// Pairs of changes whose diffs commute: jj rebases each past the other
    /// without a conflict, and each keeps its own patch (see `commute.rs`).
    /// A pair counts in either order.
    #[serde(default)]
    pub commutes: BTreeSet<(Id, Id)>,
}

/// Why a graph is not a valid change graph.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
    /// A change has no facts, or facts belong to no change.
    MissingInfo(Id),
    /// A parent is neither in scope nor a base.
    UnknownParent { change: Id, parent: Id },
    /// A change has no parents.
    NoParents(Id),
    /// A base is also in scope.
    BaseInScope(Id),
    /// The parent relation has a cycle through these changes.
    Cycle(BTreeSet<Id>),
    /// A pair of the bases' ancestry names a commit that is not a base, or
    /// one commit twice.
    BaseAncestry { ancestor: Id, descendant: Id },
    /// The bases' ancestry has a cycle through these bases.
    BaseCycle(BTreeSet<Id>),
}

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Invalid::MissingInfo(id) => write!(f, "{id} has no facts"),
            Invalid::UnknownParent { change, parent } => {
                write!(
                    f,
                    "{change} has parent {parent}, which is neither in scope nor a base"
                )
            }
            Invalid::NoParents(id) => write!(f, "{id} has no parents"),
            Invalid::BaseInScope(id) => write!(f, "{id} is both in scope and a base"),
            Invalid::BaseAncestry {
                ancestor,
                descendant,
            } => write!(
                f,
                "{ancestor} below {descendant} is not ancestry between two bases"
            ),
            Invalid::BaseCycle(ids) => {
                write!(f, "the bases' ancestry has a cycle through {}", join(ids))
            }
            Invalid::Cycle(ids) => write!(f, "the graph has a cycle through {}", join(ids)),
        }
    }
}

impl std::error::Error for Invalid {}

/// The requirements form a cycle, so no graph satisfies them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequirementCycle {
    /// Every change on some requirement cycle.
    pub members: BTreeSet<Id>,
    /// The requirements among them.
    pub edges: BTreeSet<(Id, Id)>,
}

impl fmt::Display for RequirementCycle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "these changes require each other, so no order satisfies them: {}",
            join(&self.members)
        )
    }
}

impl std::error::Error for RequirementCycle {}

fn join(ids: &BTreeSet<Id>) -> String {
    ids.iter().cloned().collect::<Vec<_>>().join(", ")
}

/// A relation on a fixed, indexed set of nodes, as one bitset per node.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Relation {
    ids: Vec<Id>,
    index: BTreeMap<Id, usize>,
    /// `rows[i]` holds `j` when `(ids[i], ids[j])` is in the relation.
    rows: Vec<Vec<u64>>,
}

impl Relation {
    fn empty(nodes: impl IntoIterator<Item = Id>) -> Self {
        let ids: Vec<Id> = nodes
            .into_iter()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let index = ids
            .iter()
            .enumerate()
            .map(|(i, id)| (id.clone(), i))
            .collect();
        let words = ids.len().div_ceil(64);
        let rows = vec![vec![0; words]; ids.len()];
        Relation { ids, index, rows }
    }

    fn insert(&mut self, from: &str, to: &str) {
        let (i, j) = (self.index[from], self.index[to]);
        self.rows[i][j / 64] |= 1 << (j % 64);
    }

    fn has(&self, i: usize, j: usize) -> bool {
        self.rows[i][j / 64] & (1 << (j % 64)) != 0
    }

    /// Whether `(from, to)` is in the relation. Unknown nodes are in no pair.
    pub fn contains(&self, from: &str, to: &str) -> bool {
        match (self.index.get(from), self.index.get(to)) {
            (Some(&i), Some(&j)) => self.has(i, j),
            _ => false,
        }
    }

    /// The transitive closure (Warshall's algorithm over bitsets).
    fn closure(mut self) -> Self {
        for k in 0..self.ids.len() {
            let via = self.rows[k].clone();
            for i in 0..self.ids.len() {
                if self.has(i, k) {
                    for (word, extra) in self.rows[i].iter_mut().zip(&via) {
                        *word |= extra;
                    }
                }
            }
        }
        self
    }

    /// Every `x` with `(x, to)` in the relation.
    pub fn preds(&self, to: &str) -> BTreeSet<Id> {
        let Some(&j) = self.index.get(to) else {
            return BTreeSet::new();
        };
        (0..self.ids.len())
            .filter(|&i| self.has(i, j))
            .map(|i| self.ids[i].clone())
            .collect()
    }

    /// Every pair in the relation.
    pub fn pairs(&self) -> BTreeSet<(Id, Id)> {
        let mut out = BTreeSet::new();
        for i in 0..self.ids.len() {
            for j in 0..self.ids.len() {
                if self.has(i, j) {
                    out.insert((self.ids[i].clone(), self.ids[j].clone()));
                }
            }
        }
        out
    }

    /// Whether some node is related to itself.
    pub fn is_reflexive_anywhere(&self) -> bool {
        (0..self.ids.len()).any(|i| self.has(i, i))
    }
}

impl Graph {
    /// The changes in scope.
    pub fn scope(&self) -> BTreeSet<Id> {
        self.parents.keys().cloned().collect()
    }

    /// Changes in scope and bases.
    pub fn nodes(&self) -> BTreeSet<Id> {
        self.parents.keys().chain(&self.bases).cloned().collect()
    }

    /// Check that the graph is a valid change graph: every change has facts
    /// and at least one parent, every parent is known, and nothing is its
    /// own ancestor.
    pub fn validate(&self) -> Result<(), Invalid> {
        for id in self.parents.keys() {
            if !self.info.contains_key(id) {
                return Err(Invalid::MissingInfo(id.clone()));
            }
            if self.bases.contains(id) {
                return Err(Invalid::BaseInScope(id.clone()));
            }
        }
        if let Some(id) = self.info.keys().find(|id| !self.parents.contains_key(*id)) {
            return Err(Invalid::MissingInfo(id.clone()));
        }
        for (id, ps) in &self.parents {
            if ps.is_empty() {
                return Err(Invalid::NoParents(id.clone()));
            }
            if let Some(p) = ps
                .iter()
                .find(|p| !self.parents.contains_key(*p) && !self.bases.contains(*p))
            {
                return Err(Invalid::UnknownParent {
                    change: id.clone(),
                    parent: p.clone(),
                });
            }
        }
        for (x, y) in &self.base_ancestry {
            if x == y || !self.bases.contains(x) || !self.bases.contains(y) {
                return Err(Invalid::BaseAncestry {
                    ancestor: x.clone(),
                    descendant: y.clone(),
                });
            }
        }
        // The bases' ancestry must be a partial order: no base below itself
        // once it is closed.
        let mut below = self.base_ancestry.clone();
        for k in &self.bases {
            let into: Vec<Id> = below
                .iter()
                .filter(|(_, y)| y == k)
                .map(|(x, _)| x.clone())
                .collect();
            let out: Vec<Id> = below
                .iter()
                .filter(|(x, _)| x == k)
                .map(|(_, y)| y.clone())
                .collect();
            for x in &into {
                for y in &out {
                    below.insert((x.clone(), y.clone()));
                }
            }
        }
        let base_cycle: BTreeSet<Id> = below
            .iter()
            .filter(|(x, y)| x == y)
            .map(|(x, _)| x.clone())
            .collect();
        if !base_cycle.is_empty() {
            return Err(Invalid::BaseCycle(base_cycle));
        }
        let a = self.ancestry();
        let cycle: BTreeSet<Id> = self
            .parents
            .keys()
            .filter(|v| a.contains(v, v))
            .cloned()
            .collect();
        if !cycle.is_empty() {
            return Err(Invalid::Cycle(cycle));
        }
        Ok(())
    }

    /// Edges `(parent, child)` into scope, and the base ancestry.
    pub fn edges(&self) -> BTreeSet<(Id, Id)> {
        let mut out: BTreeSet<(Id, Id)> = self.base_ancestry.clone();
        for (c, ps) in &self.parents {
            for p in ps {
                out.insert((p.clone(), c.clone()));
            }
        }
        out
    }

    fn relation(&self, pairs: impl IntoIterator<Item = (Id, Id)>) -> Relation {
        let mut r = Relation::empty(self.nodes());
        for (x, y) in pairs {
            if r.index.contains_key(&x) && r.index.contains_key(&y) {
                r.insert(&x, &y);
            }
        }
        r
    }

    /// Proper ancestry: `(x, y)` when `x` is a proper ancestor of `y`.
    pub fn ancestry(&self) -> Relation {
        self.relation(self.edges()).closure()
    }

    /// Proper ancestors of `v` among changes and bases.
    pub fn ancestors(&self, v: &str) -> BTreeSet<Id> {
        self.ancestry().preds(v)
    }

    /// The same graph with other parents.
    pub fn with_parents(&self, parents: BTreeMap<Id, BTreeSet<Id>>) -> Graph {
        Graph {
            parents,
            ..self.clone()
        }
    }

    /// Whether the diffs of `u` and `v` commute, in either order.
    pub fn commute(&self, u: &str, v: &str) -> bool {
        let pair = |x: &str, y: &str| self.commutes.contains(&(x.to_owned(), y.to_owned()));
        pair(u, v) || pair(v, u)
    }

    /// Whether `v` requires `u`: `v` references a symbol `u` defines; or `u`
    /// is an original ancestor of `v` and they define a common symbol, touch
    /// a common file and their diffs do not commute, or `v` is an anchor.
    pub fn requires(&self, a: &Relation, u: &str, v: &str) -> bool {
        if u == v {
            return false;
        }
        let (iu, iv) = (&self.info[u], &self.info[v]);
        let before = a.contains(u, v);
        !iv.refs.is_disjoint(&iu.defs)
            || before && !iu.defs.is_disjoint(&iv.defs)
            || before && !iu.files.is_disjoint(&iv.files) && !self.commute(u, v)
            || before && iv.anchor
    }

    /// The pairs `(u, v)` whose commuting would change what `v` requires:
    /// `u` is an original ancestor of `v`, they touch a common file, and
    /// nothing else makes `v` require `u`. Only these are worth asking jj
    /// about.
    pub fn commutation_candidates(&self) -> BTreeSet<(Id, Id)> {
        let a = self.ancestry();
        let mut out = BTreeSet::new();
        for (u, iu) in &self.info {
            for (v, iv) in &self.info {
                if a.contains(u, v)
                    && !iu.files.is_disjoint(&iv.files)
                    && iv.refs.is_disjoint(&iu.defs)
                    && iu.defs.is_disjoint(&iv.defs)
                    && !iv.anchor
                {
                    out.insert((u.clone(), v.clone()));
                }
            }
        }
        out
    }

    /// Every requirement `(u, v)`: `v` requires `u`.
    pub fn requirements_with(&self, a: &Relation) -> BTreeSet<(Id, Id)> {
        let mut out = BTreeSet::new();
        for u in self.parents.keys() {
            for v in self.parents.keys() {
                if self.requires(a, u, v) {
                    out.insert((u.clone(), v.clone()));
                }
            }
        }
        out
    }

    pub fn requirements(&self) -> BTreeSet<(Id, Id)> {
        self.requirements_with(&self.ancestry())
    }

    /// The bases `v` was built on.
    pub fn base_needs(&self, a: &Relation, v: &str) -> BTreeSet<Id> {
        a.preds(v).intersection(&self.bases).cloned().collect()
    }

    /// Every proper-ancestor pair the normal form must have.
    pub fn required_ancestry(&self) -> Relation {
        let a = self.ancestry();
        let mut pairs = self.requirements_with(&a);
        for v in self.parents.keys() {
            for x in self.base_needs(&a, v) {
                pairs.insert((x, v.clone()));
            }
        }
        pairs.extend(self.base_ancestry.iter().cloned());
        self.relation(pairs).closure()
    }

    /// The changes on a requirement cycle.
    pub fn cycle_members(&self) -> BTreeSet<Id> {
        let rs = self.relation(self.requirements()).closure();
        self.parents
            .keys()
            .filter(|v| rs.contains(v, v))
            .cloned()
            .collect()
    }

    pub fn normalizable(&self) -> bool {
        self.cycle_members().is_empty()
    }

    /// The normal form's parents: each change's required ancestors that no
    /// other required ancestor descends from.
    pub fn normal_parents(&self) -> Result<BTreeMap<Id, BTreeSet<Id>>, RequirementCycle> {
        let members = self.cycle_members();
        if !members.is_empty() {
            let edges = self
                .requirements()
                .into_iter()
                .filter(|(u, v)| members.contains(u) && members.contains(v))
                .collect();
            return Err(RequirementCycle { members, edges });
        }
        let n = self.required_ancestry();
        Ok(self
            .parents
            .keys()
            .map(|v| {
                let below = n.preds(v);
                let cover = below
                    .iter()
                    .filter(|x| !below.iter().any(|y| n.contains(x, y)))
                    .cloned()
                    .collect();
                (v.clone(), cover)
            })
            .collect())
    }

    pub fn normal_form(&self) -> Result<Graph, RequirementCycle> {
        Ok(self.with_parents(self.normal_parents()?))
    }

    pub fn is_normal(&self) -> bool {
        self.normal_parents().is_ok_and(|ps| ps == self.parents)
    }

    /// Requirements the graph does not satisfy: `v` references what `u`
    /// defines, but `u` is not an ancestor of `v`.
    pub fn unsatisfied(&self) -> BTreeSet<(Id, Id)> {
        let a = self.ancestry();
        self.requirements_with(&a)
            .into_iter()
            .filter(|(u, v)| !a.contains(u, v))
            .collect()
    }

    /// Parents that another parent of the same change descends from.
    pub fn redundant(&self) -> BTreeSet<(Id, Id)> {
        let a = self.ancestry();
        let mut out = BTreeSet::new();
        for (v, ps) in &self.parents {
            for p in ps {
                if ps.iter().any(|q| a.contains(p, q)) {
                    out.insert((p.clone(), v.clone()));
                }
            }
        }
        out
    }

    /// Parents no requirement asks for.
    pub fn unneeded(&self) -> BTreeSet<(Id, Id)> {
        let n = self.required_ancestry();
        let mut out = BTreeSet::new();
        for (v, ps) in &self.parents {
            for p in ps {
                if !n.contains(p, v) {
                    out.insert((p.clone(), v.clone()));
                }
            }
        }
        out
    }

    /// Everything `jj-graph check` reports about the graph's shape.
    pub fn check(&self) -> Check {
        Check {
            cycle: self.cycle_members(),
            unsatisfied: self.unsatisfied(),
            redundant: self.redundant(),
            unneeded: self.unneeded(),
            mixed: self
                .info
                .iter()
                .filter(|(_, c)| c.is_mixed())
                .map(|(id, _)| id.clone())
                .collect(),
        }
    }

    /// Soundness as the guide states it: every symbol `v` references that a
    /// change in scope defines is defined by `v` or an ancestor in scope.
    pub fn sound(&self) -> bool {
        let a = self.ancestry();
        let defined: BTreeSet<&String> = self.info.values().flat_map(|c| &c.defs).collect();
        self.parents.keys().all(|v| {
            let lineage: BTreeSet<&String> = a
                .preds(v)
                .iter()
                .filter(|u| self.parents.contains_key(*u))
                .chain(std::iter::once(v))
                .flat_map(|u| &self.info[u].defs)
                .collect();
            self.info[v]
                .refs
                .iter()
                .filter(|s| defined.contains(s))
                .all(|s| lineage.contains(s))
        })
    }

    /// Minimality: every edge is a direct requirement (or a base the change
    /// was built on), and no parent is an ancestor of another.
    pub fn minimal(&self) -> bool {
        let a = self.ancestry();
        let r = self.requirements_with(&a);
        self.parents.iter().all(|(v, ps)| {
            let needs = self.base_needs(&a, v);
            ps.iter().all(|p| {
                (r.contains(&(p.clone(), v.clone())) || self.bases.contains(p) && needs.contains(p))
                    && !ps.iter().any(|q| q != p && a.contains(p, q))
            })
        })
    }

    /// Removing any one edge loses a required ancestor.
    pub fn every_edge_needed(&self) -> bool {
        let need = self.required_ancestry().pairs();
        self.parents.iter().all(|(v, ps)| {
            ps.iter().all(|p| {
                let mut rest = ps.clone();
                rest.remove(p);
                if rest.is_empty() {
                    return true;
                }
                let mut parents = self.parents.clone();
                parents.insert(v.clone(), rest);
                !need.is_subset(&self.with_parents(parents).ancestry().pairs())
            })
        })
    }

    /// Each change in scope with its ancestors in scope.
    fn lineages(&self) -> BTreeMap<Id, BTreeSet<Id>> {
        let a = self.ancestry();
        self.parents
            .keys()
            .map(|v| {
                let mut l: BTreeSet<Id> = a
                    .preds(v)
                    .into_iter()
                    .filter(|u| self.parents.contains_key(u))
                    .collect();
                l.insert(v.clone());
                (v.clone(), l)
            })
            .collect()
    }

    /// Pairs of changes that touch a common file and that `target` puts in
    /// one lineage (a change and its ancestors) when this graph never did.
    /// jj has never merged their edits to that file, so rewriting into
    /// `target` could conflict; the requirements cannot see it, because the
    /// two were never ordered.
    pub fn new_combinations(&self, target: &Graph) -> BTreeSet<(Id, Id)> {
        let pairs = |g: &Graph| {
            let mut out = BTreeSet::new();
            for l in g.lineages().into_values() {
                for x in &l {
                    for y in
                        l.range::<Id, _>((std::ops::Bound::Excluded(x), std::ops::Bound::Unbounded))
                    {
                        out.insert((x.clone(), y.clone()));
                    }
                }
            }
            out
        };
        let before = pairs(self);
        pairs(target)
            .into_iter()
            .filter(|p| !before.contains(p))
            // A change this graph does not know might touch anything.
            .filter(|(x, y)| match (self.info.get(x), self.info.get(y)) {
                (Some(ix), Some(iy)) => !ix.files.is_disjoint(&iy.files),
                _ => true,
            })
            .collect()
    }

    /// The changes in scope each anchor would gain in `target`, which would
    /// change its files. Soundness forces it when an ancestor of the anchor
    /// uses a change outside the anchor's lineage: that change must go below
    /// the ancestor, so below the anchor, in every valid graph.
    pub fn anchor_growth(&self, target: &Graph) -> BTreeMap<Id, BTreeSet<Id>> {
        let (before, after) = (self.ancestry(), target.ancestry());
        self.info
            .iter()
            .filter(|(_, c)| c.anchor)
            .filter_map(|(h, _)| {
                let gained: BTreeSet<Id> = after
                    .preds(h)
                    .into_iter()
                    .filter(|x| self.parents.contains_key(x) && !before.contains(x, h))
                    .collect();
                (!gained.is_empty()).then(|| (h.clone(), gained))
            })
            .collect()
    }

    /// Why `v` requires `u`, or why `u` must stay below `v` as a base.
    pub fn reasons(&self, a: &Relation, u: &str, v: &str) -> Vec<Reason> {
        let mut out = Vec::new();
        // A change does not require itself.
        if u == v {
            return out;
        }
        if self.bases.contains(u) {
            if self.base_needs(a, v).contains(u) {
                out.push(Reason::Base);
            }
            return out;
        }
        let (iu, iv) = (&self.info[u], &self.info[v]);
        let before = a.contains(u, v);
        let uses: BTreeSet<String> = iv.refs.intersection(&iu.defs).cloned().collect();
        if !uses.is_empty() {
            out.push(Reason::References(uses));
        }
        if before {
            let both: BTreeSet<String> = iu.defs.intersection(&iv.defs).cloned().collect();
            if !both.is_empty() {
                out.push(Reason::Redefines(both));
            }
            let files: BTreeSet<String> = iu.files.intersection(&iv.files).cloned().collect();
            if !files.is_empty() && !self.commute(u, v) {
                out.push(Reason::SharesFiles(files));
            }
            if iv.anchor {
                out.push(Reason::Anchor);
            }
        }
        out
    }

    /// Insert a contract twin before every hoistable change. `twin` names
    /// the twin of a change. Returns the hoisted graph and the hoisted
    /// changes. Splitting a change changes its diff, so the hoisted graph
    /// forgets every commuting pair with a hoisted change.
    pub fn hoist(&self, twin: impl Fn(&str) -> Id) -> (Graph, BTreeSet<Id>) {
        let hoisted: BTreeSet<Id> = self
            .info
            .iter()
            .filter(|(_, c)| c.hoistable())
            .map(|(id, _)| id.clone())
            .collect();
        let mut g = self.clone();
        g.commutes
            .retain(|(x, y)| !hoisted.contains(x) && !hoisted.contains(y));
        for v in &hoisted {
            let t = twin(v);
            let c = &self.info[v];
            g.parents.insert(t.clone(), self.parents[v].clone());
            g.parents.insert(v.clone(), BTreeSet::from([t.clone()]));
            g.info.insert(
                t,
                Change {
                    defs: c.contracts.clone(),
                    contracts: c.contracts.clone(),
                    refs: c.crefs.clone(),
                    files: c.cfiles.clone(),
                    anchor: false,
                    crefs: c.crefs.clone(),
                    cfiles: c.cfiles.clone(),
                },
            );
            g.info.insert(
                v.clone(),
                Change {
                    defs: c.impl_defs(),
                    contracts: BTreeSet::new(),
                    crefs: BTreeSet::new(),
                    cfiles: BTreeSet::new(),
                    ..c.clone()
                },
            );
        }
        (g, hoisted)
    }
}

impl Change {
    pub fn impl_defs(&self) -> BTreeSet<String> {
        self.defs.difference(&self.contracts).cloned().collect()
    }

    /// The change defines both a contract and an implementation.
    pub fn is_mixed(&self) -> bool {
        !self.contracts.is_empty() && !self.impl_defs().is_empty()
    }

    /// A mixed change whose contract part does not reference its own
    /// implementation, so the contract can move before it.
    pub fn hoistable(&self) -> bool {
        self.is_mixed() && self.crefs.is_disjoint(&self.impl_defs())
    }
}

/// Why one change must stay below another.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "reason", content = "items", rename_all = "kebab-case")]
pub enum Reason {
    /// The upper change references symbols the lower one defines.
    References(BTreeSet<String>),
    /// Both define these symbols; the upper one's definition comes last.
    Redefines(BTreeSet<String>),
    /// Both touch these files, and their diffs do not commute.
    SharesFiles(BTreeSet<String>),
    /// The upper change is an anchor and keeps every ancestor.
    Anchor,
    /// The upper change was built on this base.
    Base,
}

impl fmt::Display for Reason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let list = |s: &BTreeSet<String>| s.iter().cloned().collect::<Vec<_>>().join(", ");
        match self {
            Reason::References(s) => write!(f, "uses {}", list(s)),
            Reason::Redefines(s) => write!(f, "also defines {}", list(s)),
            Reason::SharesFiles(s) => write!(f, "also touches {}", list(s)),
            Reason::Anchor => write!(f, "keeps its tree"),
            Reason::Base => write!(f, "was built on it"),
        }
    }
}

/// What `check` found.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Check {
    /// Changes on a requirement cycle; the graph has no normal form.
    pub cycle: BTreeSet<Id>,
    /// `(u, v)`: `v` references what `u` defines without descending from it.
    pub unsatisfied: BTreeSet<(Id, Id)>,
    /// `(p, v)`: parent `p` of `v` is an ancestor of another parent of `v`.
    pub redundant: BTreeSet<(Id, Id)>,
    /// `(p, v)`: parent `p` of `v` is not required.
    pub unneeded: BTreeSet<(Id, Id)>,
    /// Changes that define both contracts and implementations.
    pub mixed: BTreeSet<Id>,
}

impl Check {
    /// No cycle, no unsatisfied requirement, and no extra edge: the graph is
    /// its own normal form.
    pub fn is_normal(&self) -> bool {
        self.cycle.is_empty()
            && self.unsatisfied.is_empty()
            && self.redundant.is_empty()
            && self.unneeded.is_empty()
    }
}

/// `jj rebase -s v -o onto...`: `v` takes new parents and keeps its
/// descendants.
pub fn rebase_source(g: &Graph, v: &str, onto: &BTreeSet<Id>) -> Graph {
    let mut parents = g.parents.clone();
    parents.insert(v.to_owned(), onto.clone());
    g.with_parents(parents)
}

/// `jj rebase -r v -o onto...`: `v` takes new parents, and its children
/// take its old parents in its place.
pub fn rebase_revision(g: &Graph, v: &str, onto: &BTreeSet<Id>) -> Graph {
    let old = &g.parents[v];
    let parents = g
        .parents
        .iter()
        .map(|(x, ps)| {
            let ps = if x == v {
                onto.clone()
            } else if ps.contains(v) {
                ps.iter().filter(|p| *p != v).chain(old).cloned().collect()
            } else {
                ps.clone()
            };
            (x.clone(), ps)
        })
        .collect();
    g.with_parents(parents)
}
