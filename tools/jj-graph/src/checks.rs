//! Running a project's own check command at chosen revisions: every sibling
//! realization of a contract root, and every descendant of a change whose
//! contracts changed since its previous version. Each revision's tree is
//! written to a scratch directory, so neither the repository nor any working
//! copy changes.

use std::collections::BTreeSet;
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde::Serialize;

use crate::diff::parse_git_diff;
use crate::extract::contract_api;
use crate::graph::Id;
use crate::jj::{Jj, commit};
use crate::load::Loaded;
use crate::plan::topological_order;

/// One run of the check command.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Run {
    pub change: Id,
    pub passed: bool,
    pub output: String,
}

/// Run `argv` in the tree of each change, in topological order. The command
/// sees `JJ_GRAPH_CHANGE` and `JJ_GRAPH_COMMIT`.
pub fn run_at(
    jj: &Jj,
    loaded: &Loaded,
    changes: &BTreeSet<Id>,
    argv: &[String],
) -> Result<Vec<Run>> {
    let Some((program, args)) = argv.split_first() else {
        bail!("no check command given");
    };
    let order = topological_order(&loaded.graph.parents, &Default::default())
        .context("the graph has a cycle")?;
    let mut out = Vec::new();
    for v in order.iter().filter(|v| changes.contains(*v)) {
        let c = &loaded.commits[v];
        if c.conflict {
            out.push(Run {
                change: v.clone(),
                passed: false,
                output: "the change has conflicts".into(),
            });
            continue;
        }
        let dir = tempfile::tempdir()?;
        jj.materialize(&c.commit_id, dir.path())?;
        let result = Command::new(program)
            .args(args)
            .current_dir(dir.path())
            .env("JJ_GRAPH_CHANGE", v)
            .env("JJ_GRAPH_COMMIT", &c.commit_id)
            .output()
            .with_context(|| format!("running {program}"))?;
        let mut output = String::from_utf8_lossy(&result.stdout).into_owned();
        output.push_str(&String::from_utf8_lossy(&result.stderr));
        out.push(Run {
            change: v.clone(),
            passed: result.status.success(),
            output,
        });
    }
    Ok(out)
}

/// The changes whose contracts differ from their previous version, or from
/// `against` when given.
pub fn mutated_contracts(jj: &Jj, loaded: &Loaded, against: Option<&str>) -> Result<BTreeSet<Id>> {
    let mut out = BTreeSet::new();
    for (v, c) in &loaded.commits {
        let old = match against {
            Some(rev) => jj.commit_ids(&loaded.op, rev)?.into_iter().next(),
            None => jj.previous_version(&loaded.op, &commit(&c.commit_id))?,
        };
        let Some(old) = old else { continue };
        let now = contract_api(&parse_git_diff(
            &jj.whole_diff(&loaded.op, &commit(&c.commit_id))?,
        )?);
        let then = contract_api(&parse_git_diff(&jj.whole_diff(&loaded.op, &commit(&old))?)?);
        if now != then {
            out.insert(v.clone());
        }
    }
    Ok(out)
}
