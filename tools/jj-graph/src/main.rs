use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use serde::Serialize;

use jj_graph::apply::{Options, Outcome, command_line, normalize};
use jj_graph::checks::{mutated_contracts, run_at};
use jj_graph::graph::{Check, Id};
use jj_graph::jj::Jj;
use jj_graph::load::{Loaded, Scope, load, short};
use jj_graph::shapes::{Shape, classify, leaks};
use jj_graph::{dot, hoist, skeleton};

/// Plan, check, and normalize Jujutsu change graphs against the code's
/// dependency graph.
#[derive(Parser)]
#[command(name = "jj-graph", version)]
struct Cli {
    /// A directory inside the workspace to work in.
    #[arg(short = 'R', long, global = true)]
    repository: Option<PathBuf>,
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Args, Clone)]
struct ScopeArgs {
    /// The changes to work on.
    #[arg(short = 'r', long = "revisions", default_value = "trunk()..@")]
    revisions: String,
    /// More changes whose trees must not change, beyond working copies and
    /// changes with children outside the scope.
    #[arg(long)]
    anchor: Option<String>,
    /// Print JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args, Clone)]
struct NormalizeArgs {
    #[command(flatten)]
    scope: ScopeArgs,
    /// First move the formatting- and comment-only edits of each change that
    /// also makes other edits into a new change before it (the guide's
    /// refactor precursor).
    #[arg(long)]
    cosmetic: bool,
    /// First move the contracts of each change that defines contracts and
    /// implementations into a new change before it (Pass 2).
    #[arg(long)]
    hoist: bool,
    /// Rewrite even where the normal form merges edits to one file that
    /// were never merged; the result is still checked before it lands.
    #[arg(long)]
    allow_new_combinations: bool,
    /// Let a working copy, or a change with children outside the scope,
    /// gain the changes that changes below it use without descending from
    /// them. Its files change: the gained changes' files appear.
    #[arg(long)]
    allow_tree_changes: bool,
}

#[derive(Subcommand)]
enum Cmd {
    /// Report how far the changes are from their normal form. Exits 1 when
    /// they are not normal.
    Check(ScopeArgs),
    /// Show the normal form and the rebases that reach it; change nothing.
    Plan(NormalizeArgs),
    /// Rewrite the changes into their normal form, as one operation.
    Normalize(NormalizeArgs),
    /// Show what each change defines and references.
    Symbols(ScopeArgs),
    /// Show boundary shapes, merges that use their branches' private
    /// internals, and changes whose contracts moved; optionally run a check
    /// command in each affected change's tree.
    Shapes {
        #[command(flatten)]
        scope: ScopeArgs,
        /// Compare contracts with this revision instead of each change's
        /// previous version.
        #[arg(long)]
        against: Option<String>,
        /// Run the command in every change, not only the affected ones: the
        /// guide's atomicity, where every change builds and passes its tests.
        #[arg(long)]
        every: bool,
        /// The command to run, after `--`, in each sibling of a contract
        /// root and each descendant of a changed contract.
        #[arg(last = true)]
        run: Vec<String>,
    },
    /// Create a ghost graph from a Graphviz digraph and Gherkin features:
    /// an empty change per component, a change adding each feature file,
    /// and an empty change per scenario on its spec and the components its
    /// `@needs:<node>` tags name (the diagram's sinks when none).
    Skeleton {
        /// A digraph (.dot or .gv) and any number of feature files
        /// (.feature).
        #[arg(required = true)]
        files: Vec<PathBuf>,
        /// The revision the diagram's roots go on.
        #[arg(long, default_value = "trunk()")]
        onto: String,
        /// Show what would be created; change nothing.
        #[arg(long)]
        dry_run: bool,
        /// Print JSON.
        #[arg(long)]
        json: bool,
    },
    /// The diff editor jj runs while splitting a change.
    #[command(hide = true)]
    SplitEditor {
        part: String,
        left: PathBuf,
        right: PathBuf,
    },
}

fn scope(a: &ScopeArgs) -> Scope {
    Scope {
        revset: a.revisions.clone(),
        anchors: a.anchor.clone(),
        allow_conflicts: false,
    }
}

fn title(l: &Loaded, id: &str) -> String {
    match l.commits.get(id) {
        Some(c) => c
            .description
            .lines()
            .next()
            .unwrap_or("(no description)")
            .to_owned(),
        None => "(base)".to_owned(),
    }
}

fn name(l: &Loaded, id: &str) -> String {
    if l.graph.parents.contains_key(id) {
        short(id).to_owned()
    } else {
        format!("{} (base)", &id[..id.len().min(8)])
    }
}

fn print_json(value: &impl Serialize) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

fn check(jj: &Jj, a: &ScopeArgs) -> Result<ExitCode> {
    let op = {
        jj.snapshot()?;
        jj.head_op()?
    };
    let l = load(jj, &op, &scope(a))?;
    let report = l.graph.check();
    if a.json {
        print_json(&report)?;
    } else {
        print_check(&l, &report);
    }
    Ok(if report.is_normal() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    })
}

fn print_check(l: &Loaded, r: &Check) {
    println!("{} changes in scope", l.graph.parents.len());
    let a = l.graph.ancestry();
    if !r.cycle.is_empty() {
        let names: Vec<String> = r.cycle.iter().map(|v| name(l, v)).collect();
        println!("✗ these changes require each other: {}", names.join(", "));
    }
    for (u, v) in &r.unsatisfied {
        let why: Vec<String> = l
            .graph
            .reasons(&a, u, v)
            .iter()
            .map(ToString::to_string)
            .collect();
        println!(
            "✗ {} {} from {} but does not descend from it",
            name(l, v),
            why.join("; "),
            name(l, u)
        );
    }
    for (p, v) in &r.unneeded {
        println!(
            "✗ {} sits on {}, which it does not need",
            name(l, v),
            name(l, p)
        );
    }
    for (p, v) in &r.redundant {
        println!(
            "✗ {} lists {} as a parent, but another parent already descends from it",
            name(l, v),
            name(l, p)
        );
    }
    for v in &r.mixed {
        let c = &l.graph.info[v];
        let contracts: Vec<&String> = c.contracts.iter().collect();
        let impls: Vec<String> = c.impl_defs().into_iter().collect();
        println!(
            "! {} defines contracts ({}) and implementations ({}); `jj-graph normalize --hoist` splits it",
            name(l, v),
            contracts
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", "),
            impls.join(", ")
        );
    }
    if r.is_normal() {
        println!("✓ the graph is in normal form");
    }
}

#[derive(Serialize)]
struct PlanJson<'a> {
    precursors: &'a [(Id, Id)],
    hoisted: &'a [(Id, Id)],
    target: &'a BTreeMap<Id, BTreeSet<Id>>,
    commands: Vec<String>,
    integrated: Option<&'a String>,
}

fn print_plan(o: &Outcome, applied: bool) {
    let l = &o.start;
    for (v, twin) in &o.precursors {
        println!(
            "split  {} ({}) gets its formatting edits in {}",
            short(v),
            title(l, v),
            short(twin)
        );
    }
    for (v, twin) in &o.hoisted {
        println!(
            "hoist  {} ({}) gets its contracts in {}",
            short(v),
            title(l, v),
            short(twin)
        );
    }
    let a = o.target.ancestry();
    let mut moved = 0;
    for step in &o.steps {
        moved += 1;
        let v = &step.change;
        println!("move   {} {}", short(v), title(l, v));
        let was: Vec<String> = l.graph.parents[v].iter().map(|p| name(l, p)).collect();
        println!("         was on {}", was.join(", "));
        for p in &step.onto {
            let why: Vec<String> = o
                .target
                .reasons(&a, p, v)
                .iter()
                .map(ToString::to_string)
                .collect();
            println!(
                "         onto {} ({})",
                name(l, p),
                if why.is_empty() {
                    "required".into()
                } else {
                    why.join("; ")
                }
            );
        }
    }
    if moved == 0 && o.hoisted.is_empty() && o.precursors.is_empty() {
        println!("✓ already in normal form; nothing to do");
        return;
    }
    if !applied {
        println!();
        for step in &o.steps {
            println!("  {}", command_line(&o.start.graph, step));
        }
    }
}

fn run_normalize(jj: &Jj, a: &NormalizeArgs, apply: bool) -> Result<ExitCode> {
    let opts = Options {
        scope: scope(&a.scope),
        cosmetic: a.cosmetic,
        hoist: a.hoist,
        editor: std::env::current_exe().context("finding jj-graph's own path")?,
        allow_new_combinations: a.allow_new_combinations,
        allow_tree_changes: a.allow_tree_changes,
        apply,
    };
    let o = normalize(jj, &opts)?;
    if a.scope.json {
        print_json(&PlanJson {
            precursors: &o.precursors,
            hoisted: &o.hoisted,
            target: &o.target.parents,
            commands: o
                .steps
                .iter()
                .map(|s| command_line(&o.start.graph, s))
                .collect(),
            integrated: o.integrated.as_ref(),
        })?;
    } else {
        print_plan(&o, apply);
        if let Some(op) = &o.integrated {
            println!("✓ applied as operation {}", &op[..12.min(op.len())]);
        }
    }
    Ok(ExitCode::SUCCESS)
}

#[derive(Serialize)]
struct SymbolsJson<'a> {
    change: &'a Id,
    description: String,
    #[serde(flatten)]
    symbols: &'a jj_graph::extract::Symbols,
}

fn symbols(jj: &Jj, a: &ScopeArgs) -> Result<ExitCode> {
    let op = {
        jj.snapshot()?;
        jj.head_op()?
    };
    let l = load(jj, &op, &scope(a))?;
    if a.json {
        let rows: Vec<SymbolsJson> = l
            .symbols
            .iter()
            .map(|(v, s)| SymbolsJson {
                change: v,
                description: title(&l, v),
                symbols: s,
            })
            .collect();
        return print_json(&rows).map(|_| ExitCode::SUCCESS);
    }
    let join = |s: &BTreeSet<String>| s.iter().cloned().collect::<Vec<_>>().join(", ");
    for (v, s) in &l.symbols {
        println!("{} {}", short(v), title(&l, v));
        if !s.contracts.is_empty() {
            println!("  contracts  {}", join(&s.contracts));
        }
        let impls: BTreeSet<String> = s.defs.difference(&s.contracts).cloned().collect();
        if !impls.is_empty() {
            println!("  defines    {}", join(&impls));
        }
        if !s.refs.is_empty() {
            println!("  references {}", join(&s.refs));
        }
        println!("  files      {}", join(&s.files));
    }
    Ok(ExitCode::SUCCESS)
}

#[derive(Serialize)]
struct ShapesJson {
    shapes: BTreeMap<Id, BTreeSet<Shape>>,
    leaks: Vec<jj_graph::shapes::Leak>,
    mutated: BTreeSet<Id>,
    runs: Vec<jj_graph::checks::Run>,
}

fn shapes(
    jj: &Jj,
    a: &ScopeArgs,
    against: Option<&str>,
    every: bool,
    run: &[String],
) -> Result<ExitCode> {
    let op = {
        jj.snapshot()?;
        jj.head_op()?
    };
    let l = load(jj, &op, &scope(a))?;
    let shapes = classify(&l.graph, &l.symbols);
    let private: BTreeMap<Id, BTreeSet<String>> = l
        .symbols
        .iter()
        .map(|(v, s)| (v.clone(), s.private.clone()))
        .collect();
    let leaks = leaks(&l.graph, &private);
    let mutated = mutated_contracts(jj, &l, against)?;
    let anc = l.graph.ancestry();
    let mut targets: BTreeSet<Id> = shapes
        .iter()
        .filter(|(_, s)| s.contains(&Shape::Sibling))
        .map(|(v, _)| v.clone())
        .collect();
    for m in &mutated {
        targets.extend(
            l.graph
                .parents
                .keys()
                .filter(|w| anc.contains(m, w))
                .cloned(),
        );
    }
    if every {
        targets.extend(l.graph.parents.keys().cloned());
    }
    let runs = if run.is_empty() {
        Vec::new()
    } else {
        run_at(jj, &l, &targets, run)?
    };
    let failed = !leaks.is_empty() || runs.iter().any(|r| !r.passed);
    if a.json {
        print_json(&ShapesJson {
            shapes,
            leaks,
            mutated,
            runs,
        })?;
    } else {
        for (v, s) in &shapes {
            if !s.is_empty() {
                let names: Vec<&str> = s
                    .iter()
                    .map(|x| match x {
                        Shape::ContractRoot => "contract root",
                        Shape::Sibling => "sibling realization",
                        Shape::Merge => "merge",
                    })
                    .collect();
                println!("{} {} — {}", short(v), title(&l, v), names.join(", "));
            }
        }
        for leak in &leaks {
            let syms: Vec<&String> = leak.symbols.iter().collect();
            println!(
                "✗ merge {} uses private internals of {}: {}",
                short(&leak.merge),
                short(&leak.from),
                syms.iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        for m in &mutated {
            println!(
                "! {} changed its contracts since its previous version",
                short(m)
            );
        }
        for r in &runs {
            println!(
                "{} {} {}",
                if r.passed { "✓" } else { "✗" },
                short(&r.change),
                title(&l, &r.change)
            );
            if !r.passed {
                for line in r
                    .output
                    .lines()
                    .rev()
                    .take(20)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                {
                    println!("    {line}");
                }
            }
        }
    }
    Ok(if failed {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    })
}

#[derive(Serialize)]
struct SkeletonJson {
    node: String,
    change: String,
    created: bool,
    updated: bool,
}

fn skeleton(jj: &Jj, files: &[PathBuf], onto: &str, dry_run: bool, json: bool) -> Result<ExitCode> {
    let root = std::fs::canonicalize(jj.root())?;
    let mut diagram: Option<dot::Diagram> = None;
    let mut features = Vec::new();
    for file in files {
        let text =
            std::fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?;
        match file.extension().and_then(|e| e.to_str()) {
            Some("feature") => {
                let full = std::fs::canonicalize(file)?;
                let rel = full
                    .strip_prefix(&root)
                    .with_context(|| format!("{} is not in this workspace", file.display()))?;
                features.push(jj_graph::gherkin::read_feature(
                    &rel.to_string_lossy(),
                    &text,
                )?);
            }
            Some("dot" | "gv") => {
                if diagram.is_some() {
                    anyhow::bail!("give one diagram; {} is a second", file.display());
                }
                diagram =
                    Some(dot::parse(&text).with_context(|| format!("reading {}", file.display()))?);
            }
            _ => anyhow::bail!(
                "{} is neither a Graphviz diagram (.dot, .gv) nor a Gherkin feature (.feature)",
                file.display()
            ),
        }
    }
    let plan = skeleton::plan(&diagram.unwrap_or_default(), &features)?;
    let made = skeleton::materialize(jj, &plan, onto, !dry_run)?;
    if json {
        let rows: Vec<SkeletonJson> = made
            .into_iter()
            .map(|m| SkeletonJson {
                node: m.node,
                change: m.change,
                created: m.created,
                updated: m.updated,
            })
            .collect();
        return print_json(&rows).map(|_| ExitCode::SUCCESS);
    }
    for (a, b) in &plan.dropped {
        println!("! dropped {a} --> {b}: another path already makes {b} build on {a}");
    }
    for m in &made {
        let verb = match (m.created, m.updated, dry_run) {
            (true, _, true) => "would create",
            (true, _, false) => "created",
            (false, true, true) => "would update",
            (false, true, false) => "updated",
            (false, false, _) => "reused",
        };
        let first = plan.description[&m.node]
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        println!("{verb:>12} {} {first}", short(&m.change));
    }
    Ok(ExitCode::SUCCESS)
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = (|| -> Result<ExitCode> {
        if let Cmd::SplitEditor { part, left, right } = &cli.command {
            let path = std::env::var_os(jj_graph::apply::PLAN_VARIABLE).with_context(|| {
                format!(
                    "jj-graph runs as jj's diff editor only while it splits a change, which sets {}",
                    jj_graph::apply::PLAN_VARIABLE
                )
            })?;
            let plan: hoist::Plan = serde_json::from_reader(std::fs::File::open(&path)?)
                .with_context(|| format!("reading the plan of the {part} split"))?;
            hoist::apply_plan(&plan, left, right)?;
            return Ok(ExitCode::SUCCESS);
        }
        let dir = match &cli.repository {
            Some(d) => d.clone(),
            None => std::env::current_dir()?,
        };
        let jj = Jj::discover(&dir)?;
        match &cli.command {
            Cmd::Check(a) => check(&jj, a),
            Cmd::Plan(a) => run_normalize(&jj, a, false),
            Cmd::Normalize(a) => run_normalize(&jj, a, true),
            Cmd::Symbols(a) => symbols(&jj, a),
            Cmd::Shapes {
                scope,
                against,
                every,
                run,
            } => shapes(&jj, scope, against.as_deref(), *every, run),
            Cmd::Skeleton {
                files,
                onto,
                dry_run,
                json,
            } => skeleton(&jj, files, onto, *dry_run, *json),
            Cmd::SplitEditor { .. } => unreachable!(),
        }
    })();
    match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("jj-graph: {e:#}");
            ExitCode::from(2)
        }
    }
}
