//! Materializing a ghost graph: one change per diagram node, feature, and
//! scenario, before any code exists (the guide's Section 3, Step 2).
//! `spec/Skeleton.qnt` models it.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, bail};

use crate::dot::Diagram;
use crate::gherkin::FeatureSpec;
use crate::jj::{Jj, change, commit};
use crate::plan::topological_order;

/// What a node of the skeleton is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    /// A component of the diagram: an empty change.
    Component,
    /// A feature's spec: a change that adds the feature file at `path`.
    Spec { path: String },
    /// A scenario: an empty change on its spec and what it needs.
    Scenario,
}

/// The changes a diagram and its features become.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Skeleton {
    /// Each node's kind, description, and parent nodes, after dropping
    /// edges another path implies. Roots have no parent nodes.
    pub kinds: BTreeMap<String, Kind>,
    pub description: BTreeMap<String, String>,
    pub parents: BTreeMap<String, BTreeSet<String>>,
    /// Edges that another path already implies.
    pub dropped: BTreeSet<(String, String)>,
    /// Nodes in creation order: parents first, then input order.
    pub order: Vec<String>,
}

impl Skeleton {
    /// A node's title: the first line of its description.
    pub fn title(&self, node: &str) -> &str {
        self.description[node].lines().next().unwrap_or_default()
    }
}

fn closure(edges: &BTreeSet<(String, String)>, nodes: &[String]) -> BTreeSet<(String, String)> {
    let mut r = edges.clone();
    for k in nodes {
        let into: Vec<String> = r
            .iter()
            .filter(|(_, y)| y == k)
            .map(|(x, _)| x.clone())
            .collect();
        let out: Vec<String> = r
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

/// The node of a feature's spec, and of its `i`th scenario. Diagram node
/// IDs never contain `:`, so these never collide with them, and their
/// prefixes keep them from colliding with each other.
pub fn spec_node(f: &FeatureSpec) -> String {
    format!("spec:{}", f.slug)
}

pub fn scenario_node(f: &FeatureSpec, i: usize) -> String {
    format!("scenario:{}:{i}", f.slug)
}

/// The diagram's components that no other component builds on: its surface
/// layer, which a scenario that names nothing needs.
pub fn sinks(d: &Diagram) -> BTreeSet<String> {
    d.order
        .iter()
        .filter(|n| !d.edges.iter().any(|(a, _)| a == *n))
        .cloned()
        .collect()
}

/// Validate a diagram and its features and turn them into the changes to
/// create.
pub fn plan(d: &Diagram, features: &[FeatureSpec]) -> Result<Skeleton> {
    let mut kinds = BTreeMap::new();
    let mut description = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut edges = d.edges.clone();
    for id in &d.order {
        let label = &d.labels[id];
        let mut lines = label.lines();
        let title = lines.next().unwrap_or(id).trim().to_owned();
        let body: Vec<&str> = lines.collect();
        let text = if body.is_empty() {
            title
        } else {
            format!("{title}\n\n{}", body.join("\n"))
        };
        kinds.insert(id.clone(), Kind::Component);
        description.insert(id.clone(), text);
        order.push(id.clone());
    }
    let surface = sinks(d);
    let mut slugs = BTreeSet::new();
    for f in features {
        if !slugs.insert(&f.slug) {
            bail!(
                "two feature files are named {:?}; their changes would share titles",
                f.slug
            );
        }
        let spec = spec_node(f);
        kinds.insert(
            spec.clone(),
            Kind::Spec {
                path: f.path.clone(),
            },
        );
        description.insert(spec.clone(), f.spec_description());
        order.push(spec.clone());
        for (i, s) in f.scenarios.iter().enumerate() {
            let node = scenario_node(f, i);
            if let Some(unknown) = s.needs.iter().find(|n| !d.labels.contains_key(*n)) {
                bail!(
                    "{}: scenario {:?} needs {unknown}, which the diagram does not have",
                    f.path,
                    s.name
                );
            }
            let needs = if s.needs.is_empty() {
                &surface
            } else {
                &s.needs
            };
            edges.insert((spec.clone(), node.clone()));
            for n in needs {
                edges.insert((n.clone(), node.clone()));
            }
            kinds.insert(node.clone(), Kind::Scenario);
            description.insert(node.clone(), f.scenario_description(s));
            order.push(node);
        }
    }
    let c = closure(&edges, &order);
    let cyclic: Vec<&String> = order
        .iter()
        .filter(|n| c.contains(&((*n).clone(), (*n).clone())))
        .collect();
    if !cyclic.is_empty() {
        bail!(
            "the diagram has a cycle through {}; a change graph cannot",
            cyclic
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    let mut titles: BTreeMap<&str, &String> = BTreeMap::new();
    for id in &order {
        let title = description[id].lines().next().unwrap_or_default();
        if let Some(other) = titles.insert(title, id) {
            bail!(
                "{other} and {id} have the same title {title:?}; a rerun could not tell them apart"
            );
        }
    }
    let dropped: BTreeSet<(String, String)> = edges
        .iter()
        .filter(|(a, b)| {
            order
                .iter()
                .any(|m| c.contains(&(a.clone(), m.clone())) && c.contains(&(m.clone(), b.clone())))
        })
        .cloned()
        .collect();
    let mut parents: BTreeMap<String, BTreeSet<String>> =
        order.iter().map(|n| (n.clone(), BTreeSet::new())).collect();
    for (a, b) in edges.difference(&dropped) {
        parents.get_mut(b).expect("node").insert(a.clone());
    }
    let prefer: BTreeMap<String, usize> = order
        .iter()
        .enumerate()
        .map(|(i, n)| (n.clone(), i))
        .collect();
    let order = topological_order(&parents, &prefer).expect("checked acyclic");
    Ok(Skeleton {
        kinds,
        description,
        parents,
        dropped,
        order,
    })
}

/// A node and the change it became.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Made {
    pub node: String,
    pub change: String,
    pub created: bool,
    /// A reused change whose description or feature file was brought up to
    /// date.
    pub updated: bool,
}

/// A fileset naming exactly one path from the workspace root.
fn root_file(path: &str) -> String {
    format!(
        "root-file:\"{}\"",
        path.replace('\\', "\\\\").replace('"', "\\\"")
    )
}

/// Create the skeleton's changes on `onto` as one operation. A node reuses
/// the mutable change a previous run made for it, with its title and
/// exactly its parents, and brings its description and (for a spec) its
/// feature file up to date; what else that change holds stays. A spec's
/// feature file comes from the working copy. With `apply` unset, plan
/// without integrating anything.
pub fn materialize(jj: &Jj, s: &Skeleton, onto: &str, apply: bool) -> Result<Vec<Made>> {
    jj.snapshot()?;
    let op0 = jj.head_op()?;
    let base = jj.commits(&op0, onto)?;
    let [base] = base.as_slice() else {
        bail!(
            "--onto must name one revision; {onto:?} names {}",
            base.len()
        );
    };
    let wc = jj.commits(&op0, "@")?;
    let [wc] = wc.as_slice() else {
        bail!("this workspace has no working-copy commit");
    };
    for kind in s.kinds.values() {
        if let Kind::Spec { path } = kind
            && jj
                .read(
                    &op0,
                    &[
                        "file",
                        "list",
                        "-r",
                        &commit(&wc.commit_id),
                        &root_file(path),
                    ],
                )?
                .trim()
                .is_empty()
        {
            bail!(
                "{path} is not in the working copy; save it in the workspace (and not as an ignored file)"
            );
        }
    }
    let mut op = op0.clone();
    let mut made: BTreeMap<String, String> = BTreeMap::new();
    let mut out = Vec::new();
    for node in &s.order {
        let (parent_revs, parent_changes): (Vec<String>, BTreeSet<String>) = if s.parents[node]
            .is_empty()
        {
            (
                vec![commit(&base.commit_id)],
                BTreeSet::from([base.change_id.clone()]),
            )
        } else {
            let ids: BTreeSet<String> = s.parents[node].iter().map(|p| made[p].clone()).collect();
            (ids.iter().map(|id| change(id)).collect(), ids)
        };
        let children = parent_revs
            .iter()
            .map(|p| format!("children({p})"))
            .collect::<Vec<_>>()
            .join(" & ");
        let want = &s.description[node];
        let title = s.title(node);
        let existing = jj
            .commits(&op, &format!("({children}) & mutable()"))?
            .into_iter()
            .find(|c| {
                c.description.lines().next().unwrap_or_default() == title
                    && c.parent_changes.iter().cloned().collect::<BTreeSet<_>>() == parent_changes
            });
        let (id, created, mut updated) = match existing {
            Some(c) => {
                let stale = c.description.trim_end() != want.trim_end();
                if stale {
                    let args = vec![
                        "describe".to_owned(),
                        "-r".into(),
                        change(&c.change_id),
                        "--message".into(),
                        want.clone(),
                    ];
                    op = jj.detached(&op, &args)?;
                }
                (c.change_id, false, stale)
            }
            None => {
                let before: BTreeSet<String> = jj
                    .commits(&op, &children)?
                    .into_iter()
                    .map(|c| c.change_id)
                    .collect();
                let mut args = vec![
                    "new".to_owned(),
                    "--no-edit".into(),
                    "--message".into(),
                    want.clone(),
                ];
                args.extend(parent_revs.iter().cloned());
                op = jj.detached(&op, &args)?;
                let new: Vec<String> = jj
                    .commits(&op, &children)?
                    .into_iter()
                    .map(|c| c.change_id)
                    .filter(|c| !before.contains(c))
                    .collect();
                let [id] = new.as_slice() else {
                    bail!("creating {node} made {} changes instead of one", new.len());
                };
                (id.clone(), true, false)
            }
        };
        if let Kind::Spec { path } = &s.kinds[node] {
            let current = jj.read(
                &op,
                &[
                    "file",
                    "show",
                    "-r",
                    &commit(&wc.commit_id),
                    &root_file(path),
                ],
            )?;
            let held = jj
                .read(&op, &["file", "show", "-r", &change(&id), &root_file(path)])
                .ok();
            if held.as_deref() != Some(current.as_str()) {
                let args = vec![
                    "restore".to_owned(),
                    "--from".into(),
                    commit(&wc.commit_id),
                    "--into".into(),
                    change(&id),
                    root_file(path),
                ];
                op = jj.detached(&op, &args)?;
                updated |= !created;
            }
        }
        made.insert(node.clone(), id.clone());
        out.push(Made {
            node: node.clone(),
            change: id,
            created,
            updated,
        });
    }
    if apply && op != op0 {
        if jj.head_op()? != op0 {
            bail!(
                "the repository changed while jj-graph was creating the skeleton; nothing was applied"
            );
        }
        jj.integrate(&op)?;
    }
    Ok(out)
}
