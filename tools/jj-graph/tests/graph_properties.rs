//! Properties of the normal form and its plan, one per test. Each mirrors an
//! invariant of `spec/Normalize.qnt`, over larger and more varied graphs than
//! the model checker explores.

use std::collections::{BTreeMap, BTreeSet};

use hegel::TestCase;
use hegel::generators as gs;
use jj_graph::graph::{Change, Graph, Id, rebase_revision};
use jj_graph::plan::{normalize, plan, simulate};

const SYMBOLS: [&str; 6] = ["Store", "Net", "Codec", "db", "client", "run"];
const CONTRACTS: [&str; 3] = ["Store", "Net", "Codec"];
const FILES: [&str; 4] = ["types.rs", "db.rs", "engine.rs", "cli.rs"];

fn set<T: Ord>(items: impl IntoIterator<Item = T>) -> BTreeSet<T> {
    items.into_iter().collect()
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

/// A random subset of `items`.
fn subset(tc: &TestCase, items: &[String], max: usize) -> BTreeSet<String> {
    set(tc.draw(gs::subsequences(items.to_vec()).max_size(max)))
}

/// Transitive closure of a small relation.
fn close(mut r: BTreeSet<(Id, Id)>, nodes: &[Id]) -> BTreeSet<(Id, Id)> {
    for k in nodes {
        let into: Vec<Id> = r
            .iter()
            .filter(|(_, y)| y == k)
            .map(|(x, _)| x.clone())
            .collect();
        let out: Vec<Id> = r
            .iter()
            .filter(|(x, _)| x == k)
            .map(|(_, y)| y.clone())
            .collect();
        for i in &into {
            for j in &out {
                r.insert((i.clone(), j.clone()));
            }
        }
    }
    r
}

/// A valid change graph: up to `max_changes` changes over one to three
/// bases, each with parents among earlier changes and bases, and random
/// definitions, references, files, and anchors. Change names are a random
/// permutation, so no property can lean on names following the order.
#[hegel::composite]
fn graphs(tc: &TestCase, max_changes: usize) -> Graph {
    let n = tc.draw(gs::integers::<usize>().max_value(max_changes));
    let nb = tc.draw(gs::integers::<usize>().min_value(1).max_value(3));
    let bases: Vec<Id> = (0..nb).map(|i| format!("b{i}")).collect();
    let mut base_edges = BTreeSet::new();
    for j in 0..nb {
        for i in 0..j {
            if tc.draw(gs::booleans()) {
                base_edges.insert((bases[i].clone(), bases[j].clone()));
            }
        }
    }
    let base_ancestry = close(base_edges, &bases);
    let names: Vec<Id> = tc.draw(gs::permutations(
        (0..n).map(|i| format!("c{i}")).collect::<Vec<_>>(),
    ));
    let (symbols, contracts, files) =
        (strings(&SYMBOLS), set(strings(&CONTRACTS)), strings(&FILES));
    let mut g = Graph {
        bases: set(bases.clone()),
        base_ancestry,
        ..Graph::default()
    };
    for (i, name) in names.iter().enumerate() {
        let candidates: Vec<Id> = names[..i].iter().chain(&bases).cloned().collect();
        let mut ps = subset(tc, &candidates, 3);
        if ps.is_empty() {
            ps.insert(if i == 0 {
                tc.draw(gs::sampled_from(bases.clone()))
            } else {
                names[i - 1].clone()
            });
        }
        g.parents.insert(name.clone(), ps);
        let defs = subset(tc, &symbols, 2);
        let refs = subset(tc, &symbols, 3);
        let touched = subset(tc, &files, 2);
        let crefs = subset(tc, &refs.iter().cloned().collect::<Vec<_>>(), 2);
        let cfiles = subset(tc, &touched.iter().cloned().collect::<Vec<_>>(), 2);
        let change = Change {
            contracts: defs.intersection(&contracts).cloned().collect(),
            defs,
            refs,
            files: touched,
            anchor: tc.draw(gs::weighted_booleans(0.15)),
            crefs,
            cfiles,
        };
        g.info.insert(name.clone(), change);
    }
    g
}

fn normalizable_graph(tc: &TestCase, max_changes: usize) -> (Graph, Graph) {
    let g = tc.draw(graphs(max_changes));
    let n = g.normal_form();
    tc.event(if n.is_ok() {
        "normalizable"
    } else {
        "requirement cycle"
    });
    tc.assume(n.is_ok());
    (g, n.unwrap())
}

#[hegel::test(test_cases = 300)]
fn generated_graphs_are_valid(tc: TestCase) {
    let g = tc.draw(graphs(7));
    assert_eq!(g.validate(), Ok(()));
}

#[hegel::test(test_cases = 300)]
fn normal_form_is_a_valid_graph(tc: TestCase) {
    let (_, n) = normalizable_graph(&tc, 7);
    assert_eq!(n.validate(), Ok(()));
}

#[hegel::test(test_cases = 300)]
fn normal_form_satisfies_every_requirement(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    let a = n.ancestry();
    for (u, v) in g.requirements() {
        assert!(
            a.contains(&u, &v),
            "{v} requires {u} but does not descend from it in {n:?}"
        );
    }
}

#[hegel::test(test_cases = 300)]
fn normal_form_keeps_every_base_a_change_was_built_on(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    let (a, b) = (g.ancestry(), n.ancestry());
    for v in g.scope() {
        assert!(
            g.base_needs(&a, &v).is_subset(&n.base_needs(&b, &v)),
            "{v} lost a base"
        );
    }
}

#[hegel::test(test_cases = 300)]
fn anchors_keep_every_original_ancestor(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    for (v, c) in &g.info {
        if c.anchor {
            assert!(
                g.ancestors(v).is_subset(&n.ancestors(v)),
                "anchor {v} lost an ancestor"
            );
        }
    }
}

#[hegel::test(test_cases = 300)]
fn anchors_that_do_not_grow_keep_exactly_their_changes(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    let growth = g.anchor_growth(&n);
    tc.event(if growth.is_empty() {
        "no anchor grows"
    } else {
        "an anchor grows"
    });
    let scope = g.scope();
    for (h, c) in &g.info {
        if c.anchor && !growth.contains_key(h) {
            let before: BTreeSet<Id> = g.ancestors(h).intersection(&scope).cloned().collect();
            let after: BTreeSet<Id> = n.ancestors(h).intersection(&scope).cloned().collect();
            assert_eq!(
                before, after,
                "anchor {h} changed its changes without growing"
            );
        }
    }
}

#[hegel::test(test_cases = 300)]
fn every_change_an_anchor_gains_is_forced(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    let need = g.required_ancestry();
    for (h, gained) in g.anchor_growth(&n) {
        let mut lineage = g.ancestors(&h);
        lineage.insert(h.clone());
        for x in gained {
            assert!(
                lineage.iter().any(|u| need.contains(&x, u)),
                "{h} gains {x}, which nothing it already had requires"
            );
        }
    }
}

#[hegel::test(test_cases = 300)]
fn normal_form_is_sound(tc: TestCase) {
    let (_, n) = normalizable_graph(&tc, 7);
    assert!(n.sound());
}

#[hegel::test(test_cases = 300)]
fn normal_form_is_minimal(tc: TestCase) {
    let (_, n) = normalizable_graph(&tc, 7);
    assert!(n.minimal());
}

#[hegel::test(test_cases = 300)]
fn normal_form_needs_every_edge(tc: TestCase) {
    let (_, n) = normalizable_graph(&tc, 7);
    assert!(n.every_edge_needed());
}

#[hegel::test(test_cases = 300)]
fn normal_form_has_exactly_the_required_ancestry(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    assert_eq!(n.ancestry().pairs(), g.required_ancestry().pairs());
}

/// Every graph over the same changes that satisfies `g`'s requirements and
/// keeps its bases and anchors, found by enumerating every parent set.
fn every_valid_rewrite(g: &Graph) -> Vec<Graph> {
    let scope: Vec<Id> = g.scope().into_iter().collect();
    let a = g.ancestry();
    let required = g.requirements_with(&a);
    let mut out = vec![g.with_parents(BTreeMap::new())];
    for v in &scope {
        let candidates: Vec<Id> = scope
            .iter()
            .chain(&g.bases)
            .filter(|x| *x != v)
            .cloned()
            .collect();
        let mut next = Vec::new();
        for partial in &out {
            for mask in 1..(1u32 << candidates.len()) {
                let ps = set((0..candidates.len())
                    .filter(|i| mask & (1 << i) != 0)
                    .map(|i| candidates[i].clone()));
                let mut parents = partial.parents.clone();
                parents.insert(v.clone(), ps);
                next.push(partial.with_parents(parents));
            }
        }
        out = next;
    }
    out.into_iter()
        .filter(|h| h.validate().is_ok())
        .filter(|h| {
            let b = h.ancestry();
            required.iter().all(|(u, v)| b.contains(u, v))
                && scope.iter().all(|v| {
                    g.base_needs(&a, v).iter().all(|x| b.contains(x, v))
                        && (!g.info[v].anchor || a.preds(v).iter().all(|x| b.contains(x, v)))
                })
        })
        .collect()
}

#[hegel::test(test_cases = 100)]
fn normal_form_is_the_least_valid_rewrite(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 3);
    tc.assume(g.bases.len() <= 2);
    let rewrites = every_valid_rewrite(&g);
    assert!(
        rewrites.contains(&n),
        "the normal form is not a valid rewrite"
    );
    let least = n.ancestry().pairs();
    let edges = n.edges();
    for h in &rewrites {
        let anc = h.ancestry().pairs();
        assert!(
            least.is_subset(&anc),
            "a valid rewrite has less ancestry: {h:?}"
        );
        if anc == least {
            assert!(
                edges.is_subset(&h.edges()),
                "a rewrite with the same ancestry has fewer edges: {h:?}"
            );
        }
    }
}

#[hegel::test(test_cases = 300)]
fn normalizing_twice_changes_nothing(tc: TestCase) {
    let (_, n) = normalizable_graph(&tc, 7);
    assert_eq!(n.normal_form().as_ref(), Ok(&n));
}

#[hegel::test(test_cases = 300)]
fn check_is_clean_exactly_on_normal_graphs(tc: TestCase) {
    let g = tc.draw(graphs(7));
    tc.event(if g.is_normal() {
        "already normal"
    } else {
        "not normal"
    });
    assert_eq!(g.check().is_normal(), g.is_normal());
}

#[hegel::test(test_cases = 300)]
fn check_is_clean_on_the_normal_form(tc: TestCase) {
    let (_, n) = normalizable_graph(&tc, 7);
    assert!(n.check().is_normal(), "{:?}", n.check());
}

// A redundant parent can stay: it is redundant only next to the other
// parent, which the normal form may drop (c1 on {b0, c0} keeps b0 alone once
// it no longer needs c0). An unneeded one cannot.
#[hegel::test(test_cases = 300)]
fn check_findings_are_fixed_in_the_normal_form(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    let report = g.check();
    let a = n.ancestry();
    for (u, v) in &report.unsatisfied {
        assert!(a.contains(u, v), "{v} still does not descend from {u}");
    }
    for (p, v) in &report.unneeded {
        assert!(!n.parents[v].contains(p), "{p} is still a parent of {v}");
    }
}

#[hegel::test(test_cases = 300)]
fn a_requirement_cycle_is_what_blocks_normalizing(tc: TestCase) {
    let g = tc.draw(graphs(7));
    let members = g.cycle_members();
    tc.event(if members.is_empty() {
        "no cycle"
    } else {
        "cycle"
    });
    match g.normal_parents() {
        Ok(_) => assert!(members.is_empty()),
        Err(cycle) => {
            assert_eq!(cycle.members, members);
            // Each member reaches itself through the reported requirements.
            let closed = close(
                cycle.edges.clone(),
                &members.iter().cloned().collect::<Vec<_>>(),
            );
            for v in &members {
                assert!(
                    closed.contains(&(v.clone(), v.clone())),
                    "{v} is on no cycle"
                );
            }
        }
    }
}

fn rename(g: &Graph, to: &BTreeMap<Id, Id>) -> Graph {
    let r = |x: &Id| to.get(x).cloned().unwrap_or_else(|| x.clone());
    Graph {
        parents: g
            .parents
            .iter()
            .map(|(v, ps)| (r(v), ps.iter().map(r).collect()))
            .collect(),
        info: g.info.iter().map(|(v, c)| (r(v), c.clone())).collect(),
        bases: g.bases.iter().map(r).collect(),
        base_ancestry: g.base_ancestry.iter().map(|(x, y)| (r(x), r(y))).collect(),
    }
}

#[hegel::test(test_cases = 300)]
fn renaming_changes_renames_the_normal_form(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    let names: Vec<Id> = g.scope().into_iter().collect();
    let shuffled: Vec<Id> = tc.draw(gs::permutations(
        names.iter().map(|v| format!("x{v}")).collect::<Vec<_>>(),
    ));
    let to: BTreeMap<Id, Id> = names.into_iter().zip(shuffled).collect();
    assert_eq!(rename(&g, &to).normal_form(), Ok(rename(&n, &to)));
}

#[hegel::test(test_cases = 300)]
fn the_plan_reaches_the_normal_form(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    assert_eq!(simulate(&g, &plan(&g, &n.parents)), Ok(n));
}

#[hegel::test(test_cases = 300)]
fn the_plan_moves_each_change_at_most_once_and_only_when_needed(tc: TestCase) {
    let (g, n) = normalizable_graph(&tc, 7);
    let steps = plan(&g, &n.parents);
    let moved = set(steps.iter().map(|s| s.change.clone()));
    assert_eq!(moved.len(), steps.len(), "a change moved twice");
    let wrong = set(g
        .scope()
        .into_iter()
        .filter(|v| g.parents[v] != n.parents[v]));
    assert_eq!(moved, wrong);
}

#[hegel::test(test_cases = 300)]
fn a_normal_graph_needs_no_commands(tc: TestCase) {
    let (_, n) = normalizable_graph(&tc, 7);
    assert!(plan(&n, &n.parents).is_empty());
}

fn twin(v: &str) -> Id {
    format!("{v}~contract")
}

#[hegel::test(test_cases = 300)]
fn hoisting_leaves_nothing_hoistable(tc: TestCase) {
    let g = tc.draw(graphs(7));
    let (h, hoisted) = g.hoist(twin);
    tc.event(if hoisted.is_empty() {
        "nothing hoisted"
    } else {
        "hoisted"
    });
    assert!(h.info.values().all(|c| !c.hoistable()));
}

#[hegel::test(test_cases = 300)]
fn hoisting_inserts_each_twin_between_its_change_and_its_parents(tc: TestCase) {
    let g = tc.draw(graphs(7));
    let (h, hoisted) = g.hoist(twin);
    assert_eq!(h.validate(), Ok(()));
    for v in &hoisted {
        assert_eq!(h.parents[&twin(v)], g.parents[v]);
        assert_eq!(h.parents[v], set([twin(v)]));
        assert_eq!(h.info[&twin(v)].defs, g.info[v].contracts);
        assert_eq!(h.info[v].defs, g.info[v].impl_defs());
    }
}

#[hegel::test(test_cases = 300)]
fn hoisting_keeps_every_original_ancestor(tc: TestCase) {
    let g = tc.draw(graphs(7));
    let (h, _) = g.hoist(twin);
    for v in g.scope() {
        assert!(
            g.ancestors(&v).is_subset(&h.ancestors(&v)),
            "{v} lost an ancestor"
        );
    }
}

#[hegel::test(test_cases = 300)]
fn hoisting_keeps_a_normalizable_graph_normalizable(tc: TestCase) {
    let (g, _) = normalizable_graph(&tc, 7);
    let (h, _) = g.hoist(twin);
    assert!(
        h.normalizable(),
        "hoisting made a cycle: {:?}",
        h.cycle_members()
    );
}

#[hegel::test(test_cases = 300)]
fn normalize_hoists_then_reaches_the_hoisted_graphs_normal_form(tc: TestCase) {
    let (g, _) = normalizable_graph(&tc, 7);
    let twin: &dyn Fn(&str) -> Id = &twin;
    let run = normalize(&g, Some(twin)).expect("hoisting keeps it normalizable");
    assert_eq!(run.start, g.hoist(twin).0);
    assert_eq!(simulate(&run.start, &run.steps), Ok(run.target.clone()));
    assert!(run.target.is_normal());
}

#[hegel::test(test_cases = 300)]
fn a_requirement_always_has_a_reason_and_only_then(tc: TestCase) {
    let g = tc.draw(graphs(7));
    let scope: Vec<Id> = g.scope().into_iter().collect();
    tc.assume(!scope.is_empty());
    let v = tc.draw(gs::sampled_from(scope.clone()));
    let a = g.ancestry();
    for u in scope.iter().filter(|u| **u != v) {
        assert_eq!(
            g.reasons(&a, u, &v).is_empty(),
            !g.requires(&a, u, &v),
            "{u} below {v}"
        );
    }
    for b in &g.bases {
        assert_eq!(
            !g.reasons(&a, b, &v).is_empty(),
            g.base_needs(&a, &v).contains(b),
            "base {b} below {v}"
        );
    }
    assert!(g.reasons(&a, &v, &v).is_empty());
}

#[hegel::test(test_cases = 300)]
fn a_graph_combines_nothing_new_with_itself(tc: TestCase) {
    let g = tc.draw(graphs(7));
    assert!(g.new_combinations(&g).is_empty());
}

#[hegel::test(test_cases = 300)]
fn base_ancestry_that_is_cyclic_or_names_no_base_is_refused(tc: TestCase) {
    let g = tc.draw(graphs(5));
    let bases: Vec<Id> = g.bases.iter().cloned().collect();
    let (x, y) = (
        tc.draw(gs::sampled_from(bases.clone())),
        tc.draw(gs::sampled_from(bases.clone())),
    );
    let mut cyclic = g.clone();
    cyclic.base_ancestry.insert((x.clone(), y.clone()));
    cyclic.base_ancestry.insert((y, x));
    assert!(cyclic.validate().is_err());
    let mut stray = g.clone();
    stray
        .base_ancestry
        .insert((bases[0].clone(), "not-a-base".into()));
    assert!(stray.validate().is_err());
}

#[hegel::test(test_cases = 300)]
fn rebase_revision_fills_the_hole_with_the_old_parents(tc: TestCase) {
    let g = tc.draw(graphs(7));
    let scope: Vec<Id> = g.scope().into_iter().collect();
    tc.assume(!scope.is_empty());
    let v = tc.draw(gs::sampled_from(scope));
    let onto = g.parents[&v].clone();
    let h = rebase_revision(&g, &v, &onto);
    for (x, ps) in &g.parents {
        if ps.contains(&v) && *x != v {
            assert!(!h.parents[x].contains(&v));
            assert!(g.parents[&v].is_subset(&h.parents[x]));
        }
    }
}
