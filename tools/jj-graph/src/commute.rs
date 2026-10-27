//! Whether the diffs of two changes that touch one file commute, asked of
//! jj itself.
//!
//! For each pair whose order only a shared file keeps
//! (`Graph::commutation_candidates`), jj-graph moves the earlier change `u`
//! past the later one `v` on an operation it never integrates:
//! `jj rebase -r u -A v`, so `v` and the changes between them go on without
//! `u`, and `u` goes on top of `v`. The pair commutes when none of them
//! conflicts, `u` and `v` each keep their own patch (`patch_signature`), and
//! `u` on top has the tree `v` had: the pair ends where it started.
//!
//! With mergiraf allowed, a conflict jj's text merge leaves in `v` or `u`
//! goes to mergiraf, a structural merge tool jj runs as an external program
//! (`jj resolve`). Its resolution counts when each of the two keeps its edit
//! item by item (`extract::piece_edit`), and `u` on top holds the pieces `v`
//! held, though their order and layout may differ.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Context, Result};
use serde::Serialize;
use similar::{Algorithm, DiffOp, capture_diff_slices};

use crate::diff::{FileDiff, parse_git_diff, patch_signature};
use crate::extract::{Lang, piece_edit, pieces};
use crate::graph::Id;
use crate::jj::{Commit, Jj, change, changes, check_mergiraf, commit, mergiraf_resolve};
use crate::load::Loaded;

/// How `load` decides whether two changes that touch one file commute.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Commutation {
    /// It does not ask, so changes that touch one file keep their order.
    Off,
    /// jj's own rebase must commute them.
    #[default]
    Jj,
    /// jj's rebase, or where its text merge conflicts, mergiraf's.
    Mergiraf,
}

/// What made a pair commute.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum How {
    /// jj's text merge, with every patch unchanged.
    Jj,
    /// mergiraf's structural merge, with every edit unchanged item by item.
    Mergiraf,
}

/// Decide every candidate pair of `l` and record the commuting ones in its
/// graph and in `l.commutations`.
pub fn fill(jj: &Jj, l: &mut Loaded, mode: Commutation) -> Result<()> {
    l.commutations = commutations(jj, l, mode)?;
    l.graph.commutes = l.commutations.keys().cloned().collect();
    Ok(())
}

/// Every candidate pair of `l`'s graph whose diffs commute, and how.
pub fn commutations(jj: &Jj, l: &Loaded, mode: Commutation) -> Result<BTreeMap<(Id, Id), How>> {
    let mut out = BTreeMap::new();
    let candidates = match mode {
        Commutation::Off => return Ok(out),
        _ => l.graph.commutation_candidates(),
    };
    if candidates.is_empty() {
        return Ok(out);
    }
    // mergiraf keeps every merge it makes for `mergiraf review`, under its
    // data directory; the probes keep theirs in a directory of their own.
    let scratch = tempfile::tempdir()?;
    let jj = if mode == Commutation::Mergiraf {
        check_mergiraf()?;
        jj.clone().with_env("XDG_DATA_HOME", scratch.path())
    } else {
        jj.clone()
    };
    let a = l.graph.ancestry();
    let mut own = Patches::default();
    for (u, v) in candidates {
        if l.commits[&u].conflict || l.commits[&v].conflict {
            continue;
        }
        let between: Vec<Id> = l
            .graph
            .parents
            .keys()
            .filter(|x| a.contains(&u, x) && a.contains(x, &v))
            .cloned()
            .collect();
        if let Some(how) = swap(&jj, l, &u, &v, &between, mode, &mut own)
            .with_context(|| format!("testing whether {u} and {v} commute"))?
        {
            out.insert((u, v), how);
        }
    }
    Ok(out)
}

/// Each change's own patch where it was read, computed once.
#[derive(Default)]
struct Patches(BTreeMap<Id, Vec<crate::diff::FilePatch>>);

impl Patches {
    fn of(&mut self, jj: &Jj, l: &Loaded, v: &str) -> Result<&Vec<crate::diff::FilePatch>> {
        if !self.0.contains_key(v) {
            let p = patch_signature(&jj.diff(&l.op, &commit(l.commit_id(v)))?);
            self.0.insert(v.to_owned(), p);
        }
        Ok(&self.0[v])
    }
}

/// Move `u` past `v` on a detached operation and judge the result.
fn swap(
    jj: &Jj,
    l: &Loaded,
    u: &Id,
    v: &Id,
    between: &[Id],
    mode: Commutation,
    own: &mut Patches,
) -> Result<Option<How>> {
    let mut op = jj.detached(
        &l.op,
        &[
            "rebase".into(),
            "--revisions".into(),
            change(u),
            "--insert-after".into(),
            change(v),
        ],
    )?;
    let ids: Vec<Id> = [u.clone(), v.clone()]
        .into_iter()
        .chain(between.iter().cloned())
        .collect();
    let read = |op: &str| -> Result<Option<BTreeMap<Id, Commit>>> {
        let found = jj.commits(op, &changes(&ids))?;
        let by_change: BTreeMap<Id, Commit> = found
            .into_iter()
            .map(|c| (c.change_id.clone(), c))
            .collect();
        let whole = by_change.len() == ids.len() && by_change.values().all(|c| !c.divergent);
        Ok(whole.then_some(by_change))
    };
    let Some(mut now) = read(&op)? else {
        return Ok(None);
    };
    // A change between them that needs `u` conflicts without it, and `v`
    // would be judged on top of that conflict.
    if between.iter().any(|x| now[x].conflict) {
        return Ok(None);
    }
    let mut resolved = BTreeSet::new();
    // `v` first: `u` now sits on it, and resolving `v` rebases `u`.
    for x in [v, u] {
        if !now[x].conflict {
            continue;
        }
        if mode != Commutation::Mergiraf {
            return Ok(None);
        }
        // mergiraf refuses what it cannot merge: a file it cannot parse, or
        // a conflict of more than two sides.
        match jj.detached(&op, &mergiraf_resolve(&change(x))) {
            Ok(next) => op = next,
            Err(_) => return Ok(None),
        }
        resolved.insert(x.clone());
        now = match read(&op)? {
            Some(now) => now,
            None => return Ok(None),
        };
    }
    if now[u].conflict || now[v].conflict {
        return Ok(None);
    }
    for x in [u, v] {
        let is = patch_signature(&jj.diff(&op, &change(x))?);
        if *own.of(jj, l, x)? == is {
            continue;
        }
        let kept = resolved.contains(x)
            && same_edit(
                &parse_git_diff(&jj.whole_diff(&l.op, &commit(l.commit_id(x)))?)?,
                &parse_git_diff(&jj.whole_diff(&op, &change(x))?)?,
            );
        if !kept {
            return Ok(None);
        }
    }
    let top = commit(l.commit_id(v));
    if jj.same_tree(&op, &top, &change(u))? {
        return Ok(Some(if resolved.is_empty() {
            How::Jj
        } else {
            How::Mergiraf
        }));
    }
    let same = !resolved.is_empty()
        && same_pieces(&parse_git_diff(&jj.whole_diff_between(
            &op,
            &top,
            &change(u),
        )?)?);
    Ok(same.then_some(How::Mergiraf))
}

/// The lines an edit of a file removes and adds, in order.
fn line_edit(f: &FileDiff) -> Vec<String> {
    let old: Vec<&str> = f.old.split_inclusive('\n').collect();
    let new: Vec<&str> = f.new.split_inclusive('\n').collect();
    let mut out = Vec::new();
    for op in capture_diff_slices(Algorithm::Myers, &old, &new) {
        let (removed, added) = match op {
            DiffOp::Equal { .. } => continue,
            DiffOp::Delete {
                old_index, old_len, ..
            } => (old_index..old_index + old_len, 0..0),
            DiffOp::Insert {
                new_index, new_len, ..
            } => (0..0, new_index..new_index + new_len),
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => (
                old_index..old_index + old_len,
                new_index..new_index + new_len,
            ),
        };
        out.extend(old[removed].iter().map(|l| format!("-{l}")));
        out.extend(new[added].iter().map(|l| format!("+{l}")));
    }
    out
}

/// Whether two versions of a change make the same edit: in each file, the
/// same lines removed and added, or, in a file jj-graph can read, the same
/// pieces removed and added, whatever their order or layout. A file only
/// one of them touches must keep its pieces, moved or reformatted at most.
pub fn same_edit(was: &[FileDiff], is: &[FileDiff]) -> bool {
    let by_paths = |files: &[FileDiff]| -> BTreeMap<(Option<String>, Option<String>), FileDiff> {
        files
            .iter()
            .map(|f| ((f.old_path.clone(), f.new_path.clone()), f.clone()))
            .collect()
    };
    let (was, is) = (by_paths(was), by_paths(is));
    let paths: BTreeSet<_> = was.keys().chain(is.keys()).collect();
    paths
        .into_iter()
        .all(|paths| match (was.get(paths), is.get(paths)) {
            (Some(x), Some(y)) => same_file_edit(x, y),
            (Some(f), None) | (None, Some(f)) => keeps_pieces(f),
            (None, None) => unreachable!("every path comes from one side"),
        })
}

fn same_file_edit(x: &FileDiff, y: &FileDiff) -> bool {
    if x.binary || y.binary || x.same_text || y.same_text {
        // jj shows neither side of these; their paths and modes are all a
        // diff says.
        return x.binary == y.binary && x.same_text == y.same_text;
    }
    if line_edit(x) == line_edit(y) {
        return true;
    }
    let Some(lang) = Lang::of_path(x.path()) else {
        return false;
    };
    let sides = |f: &FileDiff| {
        piece_edit(
            lang,
            f.old_path.as_ref().map(|_| f.old.as_str()),
            f.new_path.as_ref().map(|_| f.new.as_str()),
        )
    };
    matches!((sides(x), sides(y)), (Some(p), Some(q)) if p == q)
}

/// Whether a file's edit keeps every piece: it moves or reformats items,
/// statements, and comments, and changes none.
fn keeps_pieces(f: &FileDiff) -> bool {
    if f.binary || f.same_text || f.old_path.is_none() || f.old_path != f.new_path {
        return false;
    }
    let Some(lang) = Lang::of_path(f.path()) else {
        return false;
    };
    matches!((pieces(lang, &f.old), pieces(lang, &f.new)), (Some(a), Some(b)) if a == b)
}

/// Whether every file of a diff keeps its pieces.
pub fn same_pieces(diff: &[FileDiff]) -> bool {
    diff.iter().all(keeps_pieces)
}
