//! The guide's boundary shapes (Section 5, "Automated Actions by Boundary
//! Shape") and the checks each one calls for.
//!
//! - A contract root has two or more children in scope and defines
//!   contracts: a shared interface every child realizes.
//! - A sibling is a child of a contract root: one realization of it.
//! - A merge has two or more parents in scope: a composition root, which
//!   should wire its branches through their contracts, not their private
//!   internals. Its leaks are the private implementations of the branches it
//!   joins that it references.
//! - A mutated contract is a change whose contract definitions differ from
//!   its previous version (`jj evolog`); its descendants may no longer build.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::extract::Symbols;
use crate::graph::{Graph, Id};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Shape {
    ContractRoot,
    Sibling,
    Merge,
}

/// Each change's shapes; `symbols` says which contracts each defines.
pub fn classify(g: &Graph, symbols: &BTreeMap<Id, Symbols>) -> BTreeMap<Id, BTreeSet<Shape>> {
    let mut children: BTreeMap<&Id, BTreeSet<&Id>> = BTreeMap::new();
    for (v, ps) in &g.parents {
        for p in ps.iter().filter(|p| g.parents.contains_key(*p)) {
            children.entry(p).or_default().insert(v);
        }
    }
    let roots: BTreeSet<&Id> = g
        .parents
        .keys()
        .filter(|v| {
            children.get(v).is_some_and(|c| c.len() >= 2)
                && symbols.get(*v).is_some_and(|s| !s.contracts.is_empty())
        })
        .collect();
    g.parents
        .iter()
        .map(|(v, ps)| {
            let mut s = BTreeSet::new();
            if roots.contains(v) {
                s.insert(Shape::ContractRoot);
            }
            if ps.iter().any(|p| roots.contains(p)) {
                s.insert(Shape::Sibling);
            }
            if ps.iter().filter(|p| g.parents.contains_key(*p)).count() >= 2 {
                s.insert(Shape::Merge);
            }
            (v.clone(), s)
        })
        .collect()
}

/// A merge that references a private implementation from a branch it joins.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Leak {
    pub merge: Id,
    /// The change in the branch that defines what leaked.
    pub from: Id,
    pub symbols: BTreeSet<String>,
}

/// The leaks of every merge. `private` holds each change's private
/// implementations.
pub fn leaks(g: &Graph, private: &BTreeMap<Id, BTreeSet<String>>) -> Vec<Leak> {
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
    let mut out = Vec::new();
    for (m, ps) in &g.parents {
        let branches: Vec<BTreeSet<Id>> = ps
            .iter()
            .filter(|p| g.parents.contains_key(*p))
            .map(lineage)
            .collect();
        if branches.len() < 2 {
            continue;
        }
        let common: BTreeSet<Id> = branches.iter().skip(1).fold(branches[0].clone(), |acc, b| {
            acc.intersection(b).cloned().collect()
        });
        let joined: BTreeSet<&Id> = branches
            .iter()
            .flatten()
            .filter(|u| !common.contains(*u))
            .collect();
        for u in joined {
            let used: BTreeSet<String> = g.info[m]
                .refs
                .intersection(private.get(u).unwrap_or(&BTreeSet::new()))
                .cloned()
                .collect();
            if !used.is_empty() {
                out.push(Leak {
                    merge: m.clone(),
                    from: u.clone(),
                    symbols: used,
                });
            }
        }
    }
    out
}
