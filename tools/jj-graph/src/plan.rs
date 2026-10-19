//! Turning a graph into its normal form with `jj rebase -s` commands.
//!
//! `spec/Normalize.qnt` runs every topological order of the target and checks
//! that jj never sees a cycle, that a placed change never moves again, and
//! that the plan ends on the target. This module picks one such order
//! deterministically.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::graph::{Graph, Id, Invalid, RequirementCycle, rebase_source};

/// `jj rebase -s change -o onto...`: give `change` these parents and keep its
/// descendants on it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Step {
    pub change: Id,
    pub onto: BTreeSet<Id>,
}

/// The changes of `parents` in a topological order: every change comes after
/// its parents in scope. Ties go to the change that comes first in `prefer`,
/// then to the smaller ID. Returns `None` if `parents` has a cycle.
pub fn topological_order(
    parents: &BTreeMap<Id, BTreeSet<Id>>,
    prefer: &BTreeMap<Id, usize>,
) -> Option<Vec<Id>> {
    let mut waiting: BTreeMap<&Id, usize> = parents
        .iter()
        .map(|(v, ps)| (v, ps.iter().filter(|p| parents.contains_key(*p)).count()))
        .collect();
    let mut children: BTreeMap<&Id, Vec<&Id>> = BTreeMap::new();
    for (v, ps) in parents {
        for p in ps.iter().filter(|p| parents.contains_key(*p)) {
            children.entry(p).or_default().push(v);
        }
    }
    let rank = |v: &Id| (prefer.get(v).copied().unwrap_or(usize::MAX), v.clone());
    let mut ready: BTreeSet<(usize, Id)> = waiting
        .iter()
        .filter(|(_, n)| **n == 0)
        .map(|(v, _)| rank(v))
        .collect();
    let mut order = Vec::with_capacity(parents.len());
    while let Some(next) = ready.pop_first() {
        let v = next.1;
        for c in children.get(&v).into_iter().flatten() {
            let n = waiting.get_mut(c).expect("child is in scope");
            *n -= 1;
            if *n == 0 {
                ready.insert(rank(c));
            }
        }
        order.push(v);
    }
    (order.len() == parents.len()).then_some(order)
}

/// The commands that give every change of `current` the parents `target`
/// gives it, in a topological order of `target` (ties follow `current`'s own
/// order), skipping changes whose parents are already right.
pub fn plan(current: &Graph, target: &BTreeMap<Id, BTreeSet<Id>>) -> Vec<Step> {
    let prefer: BTreeMap<Id, usize> = topological_order(&current.parents, &BTreeMap::new())
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .map(|(i, v)| (v, i))
        .collect();
    let order = topological_order(target, &prefer).expect("a normal form has no cycle");
    order
        .into_iter()
        .filter(|v| current.parents.get(v) != target.get(v))
        .map(|v| Step {
            onto: target[&v].clone(),
            change: v,
        })
        .collect()
}

/// Run `steps` on `g` as jj would, refusing any step that would make a
/// cycle (jj refuses those too).
pub fn simulate(g: &Graph, steps: &[Step]) -> Result<Graph, Invalid> {
    let mut g = g.clone();
    for step in steps {
        g = rebase_source(&g, &step.change, &step.onto);
        g.validate()?;
    }
    Ok(g)
}

/// Everything `normalize` decides before touching a repository.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Normalization {
    /// The changes whose contracts were hoisted, and the graph with their
    /// twins inserted.
    pub hoisted: BTreeSet<Id>,
    pub start: Graph,
    /// The normal form of `start`.
    pub target: Graph,
    /// The rebase commands from `start` to `target`.
    pub steps: Vec<Step>,
}

/// Hoist contracts (when `hoist` names twins), compute the normal form, and
/// plan the rebases.
pub fn normalize(
    g: &Graph,
    hoist: Option<&dyn Fn(&str) -> Id>,
) -> Result<Normalization, RequirementCycle> {
    let (start, hoisted) = match hoist {
        Some(twin) => g.hoist(twin),
        None => (g.clone(), BTreeSet::new()),
    };
    let target = start.normal_form()?;
    let steps = plan(&start, &target.parents);
    Ok(Normalization {
        hoisted,
        start,
        target,
        steps,
    })
}
