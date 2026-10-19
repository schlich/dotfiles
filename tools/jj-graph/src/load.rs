//! Reading a revset into a [`Graph`]: the changes in scope by change ID, the
//! commits below them by commit ID, each change's symbols, and its anchors.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, bail};

use crate::diff::parse_git_diff;
use crate::extract::{Symbols, change_symbols};
use crate::graph::{Change, Graph, Id};
use crate::jj::{Commit, Jj, commits};

/// What to read.
#[derive(Clone, Debug)]
pub struct Scope {
    /// The changes to normalize.
    pub revset: String,
    /// More changes whose trees must not change, beyond working copies and
    /// changes with children outside the scope.
    pub anchors: Option<String>,
    /// Read conflicted changes instead of refusing them.
    pub allow_conflicts: bool,
}

/// A graph read at one operation.
#[derive(Clone, Debug)]
pub struct Loaded {
    pub op: String,
    pub graph: Graph,
    /// The changes in scope, by change ID.
    pub commits: BTreeMap<Id, Commit>,
    pub symbols: BTreeMap<Id, Symbols>,
    /// Why each anchor is one.
    pub anchors: BTreeMap<Id, String>,
}

impl Loaded {
    /// The commit ID each change had when it was read.
    pub fn commit_id(&self, change: &str) -> &str {
        &self.commits[change].commit_id
    }
}

/// Read the changes of `scope` at operation `op`.
pub fn load(jj: &Jj, op: &str, scope: &Scope) -> Result<Loaded> {
    let found = jj.commits(op, &scope.revset)?;
    let mut by_change: BTreeMap<Id, Commit> = BTreeMap::new();
    for c in found {
        if c.immutable {
            bail!(
                "{} is immutable; jj-graph only rewrites mutable changes ({})",
                short(&c.change_id),
                first_line(&c)
            );
        }
        if c.divergent || by_change.contains_key(&c.change_id) {
            bail!(
                "{} is divergent; resolve it before normalizing",
                short(&c.change_id)
            );
        }
        if c.conflict && !scope.allow_conflicts {
            bail!(
                "{} has conflicts; resolve them before normalizing ({})",
                short(&c.change_id),
                first_line(&c)
            );
        }
        by_change.insert(c.change_id.clone(), c);
    }
    let in_scope: BTreeMap<&str, &str> = by_change
        .values()
        .map(|c| (c.commit_id.as_str(), c.change_id.as_str()))
        .collect();

    let mut graph = Graph::default();
    for (id, c) in &by_change {
        let parents: BTreeSet<Id> = c
            .parents
            .iter()
            .map(|p| {
                in_scope
                    .get(p.as_str())
                    .map_or_else(|| p.clone(), |ch| ch.to_string())
            })
            .collect();
        for p in &parents {
            if !by_change.contains_key(p) {
                graph.bases.insert(p.clone());
            }
        }
        graph.parents.insert(id.clone(), parents);
    }
    for b in &graph.bases {
        let below = jj.commit_ids(
            op,
            &format!(
                "({}) & ::{} ~ {}",
                commits(&graph.bases),
                crate::jj::commit(b),
                crate::jj::commit(b)
            ),
        )?;
        for a in below {
            graph.base_ancestry.insert((a, b.clone()));
        }
    }

    // The `working_copies()` revset, not the template keyword: the keyword
    // lists workspaces only when there are several.
    let mut anchors: BTreeMap<Id, String> = BTreeMap::new();
    let scope_set = commits(by_change.values().map(|c| &c.commit_id));
    if !by_change.is_empty() {
        for cid in jj.commit_ids(op, &format!("({scope_set}) & working_copies()"))? {
            let id = in_scope[cid.as_str()].to_owned();
            let names = &by_change[&id].working_copies;
            let why = if names.is_empty() {
                "working copy".to_owned()
            } else {
                format!("working copy of {}", names.join(", "))
            };
            anchors.insert(id, why);
        }
        let with_outside_children = jj.commit_ids(
            op,
            &format!("({scope_set}) & parents(children({scope_set}) ~ ({scope_set}))"),
        )?;
        for cid in with_outside_children {
            anchors
                .entry(in_scope[cid.as_str()].to_owned())
                .or_insert_with(|| "has children outside the scope".into());
        }
        if let Some(extra) = &scope.anchors {
            for cid in jj.commit_ids(op, &format!("({scope_set}) & ({extra})"))? {
                anchors
                    .entry(in_scope[cid.as_str()].to_owned())
                    .or_insert_with(|| "named by --anchor".into());
            }
        }
    }

    let mut symbols = BTreeMap::new();
    for (id, c) in &by_change {
        let mut s = change_symbols(&parse_git_diff(
            &jj.whole_diff(op, &crate::jj::commit(&c.commit_id))?,
        )?);
        s.files.extend(c.sources.iter().chain(&c.targets).cloned());
        graph.info.insert(
            id.clone(),
            Change {
                defs: s.defs.clone(),
                // The contracts a split would move, so the graph hoists
                // exactly what the split does.
                contracts: s.hoisted.clone(),
                refs: s.refs.clone(),
                files: s.files.clone(),
                anchor: anchors.contains_key(id),
                crefs: s.crefs.clone(),
                cfiles: s.cfiles.clone(),
            },
        );
        symbols.insert(id.clone(), s);
    }
    graph.validate()?;
    Ok(Loaded {
        op: op.to_owned(),
        graph,
        commits: by_change,
        symbols,
        anchors,
    })
}

/// A change ID's usual short form.
pub fn short(id: &str) -> &str {
    &id[..id.len().min(12)]
}

fn first_line(c: &Commit) -> &str {
    c.description.lines().next().unwrap_or("(no description)")
}
