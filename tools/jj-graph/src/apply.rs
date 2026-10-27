//! Normalizing a repository: hoist, plan, run the plan on a detached chain
//! of operations, check the result, and integrate it only if every check
//! passes and nothing else happened meanwhile. `spec/Apply.qnt` models this
//! protocol.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};

use crate::commute::{Commutation, fill, same_edit};
use crate::diff::{FileDiff, parse_git_diff, patch_signature};
use crate::graph::{Graph, Id};
use crate::hoist::Split;
use crate::jj::{Jj, change, changes, check_mergiraf, commit, mergiraf_resolve, toml_string};
use crate::load::{Loaded, Scope, load, short};
use crate::plan::{Step, plan, topological_order};

/// The name jj-graph registers itself under as a diff editor.
pub const SPLIT_TOOL: &str = "jj-graph-split";

/// The environment variable that names the file holding a split's plan.
pub const PLAN_VARIABLE: &str = "JJ_GRAPH_SPLIT_PLAN";

/// Move `split`'s part of change `v` into a new change inserted before it,
/// on the detached chain ending at `op`, and return the new change; None
/// when none of v moves. The part is planned from v's diff as it stands at
/// `op`, so an earlier split of v is taken into account.
fn split_off(
    jj: &Jj,
    op: &mut String,
    before: &Loaded,
    opts: &Options,
    v: &Id,
    split: Split,
) -> Result<Option<Id>> {
    let plan = crate::hoist::plan(&parse_git_diff(&jj.whole_diff(op, &change(v))?)?, split);
    if plan.is_empty() {
        return Ok(None);
    }
    let file = tempfile::NamedTempFile::new()?;
    serde_json::to_writer(&file, &plan)?;
    let jj = jj.clone().with_env(PLAN_VARIABLE, file.path());
    let line = before.commits[v]
        .description
        .lines()
        .next()
        .unwrap_or("")
        .to_owned();
    let what = match split {
        Split::Contracts => "contracts",
        Split::Cosmetic => "formatting",
    };
    let message = if line.is_empty() {
        what.to_owned()
    } else {
        format!("{line}: {what}")
    };
    let args: Vec<String> = vec![
        "squash".into(),
        "--from".into(),
        change(v),
        "--insert-before".into(),
        change(v),
        "--tool".into(),
        SPLIT_TOOL.into(),
        "--config".into(),
        format!(
            "merge-tools.{SPLIT_TOOL}.program={}",
            toml_string(&opts.editor.to_string_lossy())
        ),
        "--config".into(),
        format!(
            r#"merge-tools.{SPLIT_TOOL}.edit-args=["split-editor", "{}", "$left", "$right"]"#,
            split.name()
        ),
        "--message".into(),
        message,
    ];
    *op = jj.detached(op, &args)?;
    let twin = jj.commits(op, &format!("parents({})", change(v)))?;
    let [twin] = twin.as_slice() else {
        bail!(
            "splitting {} left it with {} parents instead of one; nothing was applied",
            short(v),
            twin.len()
        );
    };
    if twin.empty {
        bail!(
            "splitting the {what} out of {} moved nothing; nothing was applied",
            short(v)
        );
    }
    if !jj.same_tree(op, &commit(before.commit_id(v)), &change(v))? {
        bail!(
            "splitting {} changed its tree; nothing was applied",
            short(v)
        );
    }
    Ok(Some(twin.change_id.clone()))
}

#[derive(Clone, Debug)]
pub struct Options {
    pub scope: Scope,
    /// Move each change's cosmetic edits into a change before it first (the
    /// guide's refactor precursor).
    pub cosmetic: bool,
    /// Hoist contracts out of mixed changes first (Pass 2).
    pub hoist: bool,
    /// The program jj runs as the splitting diff editor: this one.
    pub editor: PathBuf,
    /// Allow a rewrite that merges edits to a file for the first time.
    pub allow_new_combinations: bool,
    /// Allow an anchor (a working copy, or a change with children outside
    /// the scope) to gain changes it uses through an ancestor, which changes
    /// its files.
    pub allow_tree_changes: bool,
    /// Rewrite the repository; otherwise only plan.
    pub apply: bool,
}

/// What a normalization did or would do.
#[derive(Clone, Debug)]
pub struct Outcome {
    pub before: Loaded,
    /// Each change given a refactor precursor, and the precursor.
    pub precursors: Vec<(Id, Id)>,
    /// Each hoisted change and its new contract change.
    pub hoisted: Vec<(Id, Id)>,
    /// The graph after hoisting, its normal form, and the rebases between.
    pub start: Loaded,
    pub target: Graph,
    pub steps: Vec<Step>,
    /// The changes each anchor gains, when that was allowed.
    pub growth: BTreeMap<Id, BTreeSet<Id>>,
    /// Every pair of changes that touch one file found to commute, in the
    /// graph the plan starts from or in a read of its normal form, and how.
    pub commutations: BTreeMap<(Id, Id), crate::commute::How>,
    /// The changes whose conflicts mergiraf resolved, and the anchors given
    /// their own trees back, with mergiraf allowed: each keeps its edit
    /// item by item rather than line by line.
    pub merged: BTreeSet<Id>,
    /// The operation integrated, when `apply` was set and there was work.
    pub integrated: Option<String>,
}

/// A revision argument for a node of the graph: a change in scope, or a
/// base commit.
fn node_ref(g: &Graph, id: &str) -> String {
    if g.parents.contains_key(id) {
        change(id)
    } else {
        commit(id)
    }
}

/// Run `opts` against the repository.
pub fn normalize(jj: &Jj, opts: &Options) -> Result<Outcome> {
    jj.snapshot()?;
    let op0 = jj.head_op()?;
    // Which changes commute is asked of the graph the plan starts from,
    // after any split, once.
    let before = load(
        jj,
        &op0,
        &Scope {
            commutation: Commutation::Off,
            ..opts.scope.clone()
        },
    )?;
    let mut op = op0.clone();

    // The guide's refactor precursor, then Pass 2: give each change that
    // mixes cosmetic edits with others a change of its cosmetic edits below
    // it, and each hoistable change a change of its contracts.
    // Every operation of the detached chain, oldest first.
    let mut chain = Vec::new();
    let mut precursors = Vec::new();
    if opts.cosmetic {
        for (v, s) in &before.symbols {
            if s.has_separable_cosmetics()
                && let Some(twin) = split_off(jj, &mut op, &before, opts, v, Split::Cosmetic)?
            {
                chain.push(op.clone());
                precursors.push((v.clone(), twin));
            }
        }
    }
    let mut hoisted = Vec::new();
    if opts.hoist {
        for (v, c) in &before.graph.info {
            if c.hoistable()
                && let Some(twin) = split_off(jj, &mut op, &before, opts, v, Split::Contracts)?
            {
                chain.push(op.clone());
                hoisted.push((v.clone(), twin));
            }
        }
    }
    let scope_ids: BTreeSet<Id> = before
        .graph
        .parents
        .keys()
        .cloned()
        .chain(precursors.iter().chain(&hoisted).map(|(_, t)| t.clone()))
        .collect();
    let start = if hoisted.is_empty() && precursors.is_empty() {
        let mut start = before.clone();
        fill(jj, &mut start, opts.scope.commutation)?;
        start
    } else {
        load(
            jj,
            &op,
            &Scope {
                revset: changes(&scope_ids),
                ..opts.scope.clone()
            },
        )?
    };

    // Whether two diffs commute can depend on the changes between them, and
    // the normal form moves those. So the normal form settles: it is made on
    // the detached chain and read back, which asks again in its own
    // contexts, until a read finds it normal. Only then is it judged, and
    // a second run finds nothing to do.
    let mut target = start.graph.normal_form().map_err(|c| cycle(&start, c))?;
    let mut commutations = start.commutations.clone();
    let mut realized = Realized::none(&op);
    let mut seen = BTreeSet::from([start.graph.parents.clone()]);
    while target.parents != start.graph.parents {
        let growth = start.graph.anchor_growth(&target);
        realized = realize(jj, &op, &before, &start, &target, &growth, opts)?;
        let read = load(
            jj,
            &realized.op,
            &Scope {
                revset: changes(&scope_ids),
                allow_conflicts: true,
                ..opts.scope.clone()
            },
        )?;
        commutations.extend(read.commutations.clone());
        // A conflict leaves nothing to judge; the check below refuses it.
        if read.commits.values().any(|c| c.conflict) {
            break;
        }
        let next = read.graph.normal_form().map_err(|c| cycle(&read, c))?;
        if next.parents == target.parents {
            target = next;
            break;
        }
        if !seen.insert(target.parents.clone()) || seen.contains(&next.parents) {
            bail!(
                "the normal form does not settle: reading it back keeps finding other changes \
                 that commute; nothing was applied"
            );
        }
        target = next;
    }
    let combined = start.graph.new_combinations(&target);
    if !combined.is_empty() && !opts.allow_new_combinations {
        let pairs: Vec<String> = combined
            .iter()
            .map(|(x, y)| {
                let files: Vec<String> = start.graph.info[x]
                    .files
                    .intersection(&start.graph.info[y].files)
                    .cloned()
                    .collect();
                format!("{} and {} ({})", short(x), short(y), files.join(", "))
            })
            .collect();
        bail!(
            "the normal form merges edits to the same file that were never merged before, which \
             could conflict:\n  {}\nPass --allow-new-combinations to try anyway; the result is \
             checked before anything changes.",
            pairs.join("\n  ")
        );
    }
    let growth = start.graph.anchor_growth(&target);
    if !growth.is_empty() && !opts.allow_tree_changes {
        let lines: Vec<String> = growth
            .iter()
            .map(|(h, gained)| {
                let names: Vec<String> = gained
                    .iter()
                    .map(|x| {
                        format!(
                            "{} ({})",
                            short(x),
                            start.commits[x].description.lines().next().unwrap_or("")
                        )
                    })
                    .collect();
                let what = start.anchors.get(h).map_or("anchor", String::as_str);
                format!("{} ({what}) would gain {}", short(h), names.join(", "))
            })
            .collect();
        bail!(
            "normalizing would change files that must stay as they are, because changes below them use \
             changes they do not descend from:\n  {}\nPass --allow-tree-changes to let them change.",
            lines.join("\n  ")
        );
    }
    let steps = plan(&start.graph, &target.parents);
    let mut outcome = Outcome {
        before,
        precursors,
        hoisted,
        start,
        target,
        steps,
        growth,
        commutations,
        merged: realized.merged,
        integrated: None,
    };
    let splits = outcome.precursors.len() + outcome.hoisted.len();
    if !opts.apply || (outcome.steps.is_empty() && splits == 0) {
        return Ok(outcome);
    }

    // The last realization is the plan's: its rebases, then its merges.
    let op = realized.op;
    chain.extend(realized.chain);
    verify(jj, &op, &outcome)?;

    if jj.head_op()? != op0 {
        bail!("the repository changed while jj-graph was planning; nothing was applied");
    }
    jj.integrate(&op)?;
    // An operation that raced the head check merged with ours; if that made
    // a change divergent, take ours back and keep theirs.
    let after = jj.head_op()?;
    let divergent = jj.commits(&after, &format!("({}) & divergent()", changes(&scope_ids)))?;
    if !divergent.is_empty() {
        for o in chain.iter().rev() {
            jj.revert(o)?;
        }
        bail!(
            "another operation raced jj-graph's and left changes divergent; jj-graph reverted its own"
        );
    }
    // This workspace's working copy may have been rewritten with the same
    // tree; tell jj its files are current.
    let _ = jj.update_stale();
    outcome.integrated = Some(op);
    Ok(outcome)
}

/// The requirement cycle that stops a graph, with each requirement's reason.
fn cycle(l: &Loaded, cycle: crate::graph::RequirementCycle) -> anyhow::Error {
    let a = l.graph.ancestry();
    let title = |id: &str| {
        format!(
            "{} ({})",
            short(id),
            l.commits[id].description.lines().next().unwrap_or("")
        )
    };
    let edges: Vec<String> = cycle
        .edges
        .iter()
        .map(|(u, v)| {
            let why: Vec<String> = l
                .graph
                .reasons(&a, u, v)
                .iter()
                .map(ToString::to_string)
                .collect();
            format!("{} needs {}: {}", title(v), title(u), why.join("; "))
        })
        .collect();
    anyhow::anyhow!(
        "these changes require each other, so no order satisfies them; squash them, or split the \
         part one needs from the other:\n  {}",
        edges.join("\n  ")
    )
}

/// A target made on the detached chain: the operation it ends on, the
/// operations it added, and the changes mergiraf merged.
struct Realized {
    op: String,
    chain: Vec<String>,
    merged: BTreeSet<Id>,
}

impl Realized {
    fn none(op: &str) -> Realized {
        Realized {
            op: op.to_owned(),
            chain: Vec::new(),
            merged: BTreeSet::new(),
        }
    }
}

/// Make `target` from `start` on top of `op`: the plan's rebases, then,
/// with mergiraf allowed, its merges. Nothing is integrated.
fn realize(
    jj: &Jj,
    op: &str,
    before: &Loaded,
    start: &Loaded,
    target: &Graph,
    growth: &BTreeMap<Id, BTreeSet<Id>>,
    opts: &Options,
) -> Result<Realized> {
    let mut r = Realized::none(op);
    for step in plan(&start.graph, &target.parents) {
        let mut args = vec!["rebase".to_owned(), "--source".into(), change(&step.change)];
        for p in &step.onto {
            args.push("--onto".into());
            args.push(node_ref(&start.graph, p));
        }
        r.op = jj.detached(&r.op, &args)?;
        r.chain.push(r.op.clone());
    }
    if opts.scope.commutation == Commutation::Mergiraf {
        merge_structurally(jj, &mut r, before, start, target, growth)?;
    }
    Ok(r)
}

/// With mergiraf allowed: after the plan's rebases, give each conflict
/// jj's text merge left to mergiraf, parents first, and give each anchor
/// that must keep its tree its own tree back, since its files must not
/// change. `verify` then holds each of them to its edit item by item.
fn merge_structurally(
    jj: &Jj,
    r: &mut Realized,
    before: &Loaded,
    start: &Loaded,
    target: &Graph,
    growth: &BTreeMap<Id, BTreeSet<Id>>,
) -> Result<()> {
    check_mergiraf()?;
    let order =
        topological_order(&target.parents, &BTreeMap::new()).expect("a normal form has no cycle");
    for v in order {
        let now = jj.commits(&r.op, &change(&v))?;
        let [c] = now.as_slice() else {
            bail!("{} became divergent; nothing was applied", short(&v));
        };
        let args = if before.anchors.contains_key(&v) && !growth.contains_key(&v) {
            let own = commit(before.commit_id(&v));
            if jj.same_tree(&r.op, &own, &change(&v))? {
                continue;
            }
            vec![
                "restore".to_owned(),
                "--from".into(),
                own,
                "--into".into(),
                change(&v),
            ]
        } else if c.conflict && !start.commits[&v].conflict {
            mergiraf_resolve(&change(&v))
        } else {
            continue;
        };
        r.op = jj
            .detached(&r.op, &args)
            .with_context(|| format!("merging {} with mergiraf; nothing was applied", short(&v)))?;
        r.chain.push(r.op.clone());
        r.merged.insert(v);
    }
    Ok(())
}

/// Check the chain's last operation before integrating it.
fn verify(jj: &Jj, op: &str, o: &Outcome) -> Result<()> {
    let scope: BTreeSet<Id> = o.start.graph.parents.keys().cloned().collect();
    let after = jj.commits(op, &changes(&scope))?;
    let mut by_change: BTreeMap<Id, crate::jj::Commit> = BTreeMap::new();
    for c in after {
        if c.divergent || by_change.contains_key(&c.change_id) {
            bail!(
                "{} became divergent; nothing was applied",
                short(&c.change_id)
            );
        }
        by_change.insert(c.change_id.clone(), c);
    }
    if by_change.keys().cloned().collect::<BTreeSet<_>>() != scope {
        bail!("the rewrite lost or gained changes; nothing was applied");
    }
    let commit_to_change: BTreeMap<&str, &str> = by_change
        .values()
        .map(|c| (c.commit_id.as_str(), c.change_id.as_str()))
        .collect();
    for (v, c) in &by_change {
        let parents: BTreeSet<Id> = c
            .parents
            .iter()
            .map(|p| {
                commit_to_change
                    .get(p.as_str())
                    .map_or_else(|| p.clone(), |x| x.to_string())
            })
            .collect();
        if parents != o.target.parents[v] {
            bail!(
                "{} did not land on its planned parents; nothing was applied",
                short(v)
            );
        }
        if c.conflict && !o.start.commits[v].conflict {
            bail!(
                "rewriting {} made a conflict; nothing was applied",
                short(v)
            );
        }
    }
    // Anchors keep their trees, except those allowed to grow, which must
    // differ only by the files of the changes they gain, and of the trunk
    // commits that come with them.
    for v in o.before.anchors.keys() {
        if let Some(gained) = o.growth.get(v) {
            let mut gained_files: BTreeSet<String> = gained
                .iter()
                .flat_map(|x| o.start.graph.info[x].files.iter().cloned())
                .collect();
            gained_files.extend(gained_trunk_files(jj, op, o, v)?);
            let summary = jj.read(
                op,
                &[
                    "diff",
                    "--name-only",
                    "--from",
                    &commit(o.before.commit_id(v)),
                    "--to",
                    &change(v),
                ],
            )?;
            if let Some(f) = summary.lines().find(|f| !gained_files.contains(*f)) {
                bail!(
                    "{} would change {f}, which no change it gains touches; nothing was applied",
                    short(v)
                );
            }
        } else if !jj.same_tree(op, &commit(o.before.commit_id(v)), &change(v))? {
            bail!(
                "the tree of {} ({}) would change; nothing was applied",
                short(v),
                o.before.anchors[v]
            );
        }
    }
    // Independently of how anchors were found: no workspace's files may
    // change, in scope or out of it, unless it was allowed to grow.
    for wc in jj.commits(&o.before.op, "working_copies()")? {
        if !o.growth.contains_key(&wc.change_id)
            && !jj.same_tree(op, &commit(&wc.commit_id), &change(&wc.change_id))?
        {
            bail!(
                "the working copy {} would change its files; nothing was applied",
                short(&wc.change_id)
            );
        }
    }
    for v in &scope {
        let old = patch_signature(&jj.diff(&o.start.op, &commit(o.start.commit_id(v)))?);
        let new = patch_signature(&jj.diff(op, &change(v))?);
        if old == new {
            continue;
        }
        // A change mergiraf merged keeps its edit item by item.
        if o.merged.contains(v)
            && same_edit(
                &parse_git_diff(&jj.whole_diff(&o.start.op, &commit(o.start.commit_id(v)))?)?,
                &merged_edit(jj, op, o, v)?,
            )
        {
            continue;
        }
        bail!(
            "rebasing {} would change its own diff; nothing was applied",
            short(v)
        );
    }
    Ok(())
}

/// The edit of a change mergiraf merged: the whole diff to its tree from
/// its parents' tree, which for several parents is their merge by mergiraf
/// where jj's text merge of them conflicts. That merge is made on a probe
/// operation off the chain, which nothing integrates.
fn merged_edit(jj: &Jj, op: &str, o: &Outcome, v: &str) -> Result<Vec<FileDiff>> {
    let parents = &o.target.parents[v];
    if parents.len() < 2 {
        return parse_git_diff(&jj.whole_diff(op, &change(v))?);
    }
    let mark = format!("jj-graph merges the parents of {v}");
    let mut args = vec![
        "new".to_owned(),
        "--no-edit".into(),
        "--message".into(),
        mark.clone(),
    ];
    args.extend(parents.iter().map(|p| node_ref(&o.start.graph, p)));
    let mut probe = jj.detached(op, &args)?;
    let rev = format!("description(substring:{})", toml_string(&mark));
    let made = jj.commits(&probe, &rev)?;
    let [merge] = made.as_slice() else {
        bail!("merging the parents of {} made no one commit", short(v));
    };
    if merge.conflict {
        // A probe's merge is no one's to review: mergiraf keeps its record
        // in a directory removed afterwards.
        let scratch = tempfile::tempdir()?;
        probe = jj
            .clone()
            .with_env("XDG_DATA_HOME", scratch.path())
            .detached(&probe, &mergiraf_resolve(&rev))?;
        if jj.commits(&probe, &rev)?.iter().any(|c| c.conflict) {
            bail!(
                "mergiraf cannot merge the parents of {}; nothing was applied",
                short(v)
            );
        }
    }
    parse_git_diff(&jj.whole_diff_between(&probe, &rev, &change(v))?)
}

/// The files of the commits an anchor gains below its bases: those below
/// the bases it sits on after the rewrite and not below those before.
fn gained_trunk_files(jj: &Jj, op: &str, o: &Outcome, v: &str) -> Result<BTreeSet<String>> {
    let bases = |g: &Graph| -> BTreeSet<Id> {
        g.ancestors(v)
            .into_iter()
            .filter(|b| g.bases.contains(b))
            .collect()
    };
    let (old, new) = (bases(&o.start.graph), bases(&o.target));
    if new.is_subset(&old) {
        return Ok(BTreeSet::new());
    }
    let revset = format!(
        "::({}) ~ ::({})",
        crate::jj::commits(&new),
        crate::jj::commits(&old)
    );
    let summary = jj.read(
        op,
        &["log", "-r", &revset, "--no-graph", "-T", "", "--summary"],
    )?;
    Ok(summary.lines().flat_map(summary_paths).collect())
}

/// The paths a line of `jj log --summary` names: `M path`, or both sides of
/// a move or copy, `R {old => new}`, which may sit between a prefix and a
/// suffix the two sides share.
fn summary_paths(line: &str) -> Vec<String> {
    let Some((_, path)) = line.split_once(' ') else {
        return Vec::new();
    };
    if let (Some(open), Some(close)) = (path.find('{'), path.rfind('}'))
        && open < close
        && let Some((a, b)) = path[open + 1..close].split_once(" => ")
    {
        let (prefix, suffix) = (&path[..open], &path[close + 1..]);
        return vec![
            format!("{prefix}{a}{suffix}"),
            format!("{prefix}{b}{suffix}"),
        ];
    }
    vec![path.to_owned()]
}

/// The rebase command a step runs, for showing to people.
pub fn command_line(g: &Graph, step: &Step) -> String {
    let mut out = format!("jj rebase -s '{}'", change(&step.change));
    for p in &step.onto {
        out.push_str(&format!(" -o '{}'", node_ref(g, p)));
    }
    out
}
