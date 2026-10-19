//! Running jj: reading commits and diffs at an operation, and building
//! detached chains of operations that nothing sees until they are integrated.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{Context, Result, bail};
use serde::Deserialize;

/// Enough context lines that every hunk covers its whole file.
const WHOLE_FILE: &str = "1000000000";

/// One commit, as jj-graph reads it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Commit {
    pub change_id: String,
    pub commit_id: String,
    /// Parents' commit and change IDs, in order.
    pub parents: Vec<String>,
    pub parent_changes: Vec<String>,
    pub description: String,
    pub empty: bool,
    pub conflict: bool,
    pub immutable: bool,
    pub divergent: bool,
    /// Workspaces whose working copy this commit is.
    pub working_copies: Vec<String>,
    pub bookmarks: Vec<String>,
    /// Paths the diff touches, before and after (they differ for renames).
    pub sources: Vec<String>,
    pub targets: Vec<String>,
}

const COMMIT_TEMPLATE: &str = r#"json({
  "change_id" => change_id,
  "commit_id" => commit_id,
  "parents" => parents.map(|p| p.commit_id()),
  "parent_changes" => parents.map(|p| p.change_id()),
  "description" => description,
  "empty" => empty,
  "conflict" => conflict,
  "immutable" => immutable,
  "divergent" => divergent,
  "working_copies" => working_copies.map(|w| w.name()),
  "bookmarks" => local_bookmarks.map(|b| b.name()),
  "sources" => self.diff().files().map(|f| f.source().path()),
  "targets" => self.diff().files().map(|f| f.target().path()),
}) ++ "\n""#;

/// A jj workspace, driven through its command line.
#[derive(Clone, Debug)]
pub struct Jj {
    root: PathBuf,
    program: OsString,
    /// Environment every jj command gets, such as `JJ_CONFIG` in tests.
    env: Vec<(OsString, OsString)>,
}

impl Jj {
    /// The workspace containing `dir`. `JJ_GRAPH_JJ` names another `jj`.
    pub fn discover(dir: &Path) -> Result<Jj> {
        let program = std::env::var_os("JJ_GRAPH_JJ").unwrap_or_else(|| "jj".into());
        let out = Command::new(&program)
            .current_dir(dir)
            .args([
                "--no-pager",
                "--color=never",
                "--ignore-working-copy",
                "root",
            ])
            .output()
            .with_context(|| format!("running {}", program.to_string_lossy()))?;
        if !out.status.success() {
            bail!(
                "{} is not in a jj workspace: {}",
                dir.display(),
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        let root = PathBuf::from(String::from_utf8(out.stdout)?.trim());
        Ok(Jj {
            root,
            program,
            env: Vec::new(),
        })
    }

    /// The same workspace, with `key=value` in every jj command's
    /// environment.
    pub fn with_env(mut self, key: impl Into<OsString>, value: impl Into<OsString>) -> Self {
        self.env.push((key.into(), value.into()));
        self
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn base(&self) -> Command {
        let mut c = Command::new(&self.program);
        c.envs(self.env.iter().map(|(k, v)| (k, v)));
        c
    }

    fn command(&self, at: Option<&str>) -> Command {
        let mut c = self.base();
        c.current_dir(&self.root)
            .args([
                "--no-pager",
                "--color=never",
                "--config",
                "ui.diff-instructions=false",
            ])
            // Any editor jj would open means a missing message: fail instead.
            .env("JJ_EDITOR", "false");
        match at {
            Some(op) => c.args(["--at-op", op]),
            None => c.arg("--ignore-working-copy"),
        };
        c
    }

    fn run(&self, mut cmd: Command, what: &str) -> Result<Output> {
        let out = cmd.output().with_context(|| format!("running jj {what}"))?;
        if !out.status.success() {
            bail!(
                "jj {what} failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Ok(out)
    }

    /// Run a read-only command at `at` and return its output.
    pub fn read(&self, at: &str, args: &[&str]) -> Result<String> {
        let mut c = self.command(Some(at));
        c.args(args);
        Ok(String::from_utf8(self.run(c, &args.join(" "))?.stdout)?)
    }

    /// Snapshot the working copy, so the head operation has its edits.
    pub fn snapshot(&self) -> Result<()> {
        let mut c = self.base();
        c.current_dir(&self.root)
            .args(["--no-pager", "--color=never", "util", "snapshot"]);
        self.run(c, "util snapshot").map(|_| ())
    }

    /// The repository's head operation.
    pub fn head_op(&self) -> Result<String> {
        let mut c = self.command(None);
        c.args(["op", "log", "--no-graph", "-n1", "-T", "id"]);
        Ok(String::from_utf8(self.run(c, "op log")?.stdout)?
            .trim()
            .to_owned())
    }

    /// Run a mutating command on top of operation `at` without integrating
    /// it, and return the operation it made.
    pub fn detached(&self, at: &str, args: &[String]) -> Result<String> {
        let mut c = self.command(Some(at));
        c.arg("--no-integrate-operation").args(args);
        let out = self.run(c, &args.join(" "))?;
        let err = String::from_utf8_lossy(&out.stderr);
        let short = err
            .lines()
            .find_map(|l| l.split("was requested: ").nth(1))
            .map(str::trim)
            .with_context(|| format!("jj {} reported no operation:\n{err}", args.join(" ")))?
            .to_owned();
        // Resolve the short ID to the full one.
        Ok(self
            .read(&short, &["op", "log", "--no-graph", "-n1", "-T", "id"])?
            .trim()
            .to_owned())
    }

    /// Make `op` (and the detached chain below it) the repository's head.
    pub fn integrate(&self, op: &str) -> Result<()> {
        let mut c = self.command(None);
        c.args(["op", "integrate", op]);
        self.run(c, "op integrate").map(|_| ())
    }

    /// Revert one operation with a new one, keeping any made since.
    pub fn revert(&self, op: &str) -> Result<()> {
        let mut c = self.command(None);
        c.args(["op", "revert", op]);
        self.run(c, "op revert").map(|_| ())
    }

    /// Update this workspace's files after its working-copy commit was
    /// rewritten elsewhere. Its tree is the same, so no file changes.
    pub fn update_stale(&self) -> Result<()> {
        let mut c = self.base();
        c.current_dir(&self.root).args([
            "--no-pager",
            "--color=never",
            "workspace",
            "update-stale",
        ]);
        self.run(c, "workspace update-stale").map(|_| ())
    }

    /// The commits of `revset` at operation `at`, newest first.
    pub fn commits(&self, at: &str, revset: &str) -> Result<Vec<Commit>> {
        let out = self.read(
            at,
            &["log", "--no-graph", "-r", revset, "-T", COMMIT_TEMPLATE],
        )?;
        out.lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| {
                serde_json::from_str(l).with_context(|| format!("reading jj's commit JSON: {l}"))
            })
            .collect()
    }

    /// The commit IDs of `revset` at `at`.
    pub fn commit_ids(&self, at: &str, revset: &str) -> Result<Vec<String>> {
        let out = self.read(
            at,
            &[
                "log",
                "--no-graph",
                "-r",
                revset,
                "-T",
                "commit_id ++ \"\\n\"",
            ],
        )?;
        Ok(out
            .lines()
            .filter(|l| !l.is_empty())
            .map(str::to_owned)
            .collect())
    }

    /// A change's Git-format diff from its parents, each hunk covering its
    /// whole file.
    pub fn whole_diff(&self, at: &str, rev: &str) -> Result<String> {
        self.read(at, &["diff", "--git", "--context", WHOLE_FILE, "-r", rev])
    }

    /// A change's Git-format diff with ordinary context.
    pub fn diff(&self, at: &str, rev: &str) -> Result<String> {
        self.read(at, &["diff", "--git", "-r", rev])
    }

    /// The commit a change was before its latest rewrite, if any.
    pub fn previous_version(&self, at: &str, rev: &str) -> Result<Option<String>> {
        let out = self.read(
            at,
            &[
                "evolog",
                "--no-graph",
                "-n",
                "2",
                "-r",
                rev,
                "-T",
                "commit.commit_id() ++ \"\\n\"",
            ],
        )?;
        Ok(out.lines().nth(1).map(str::to_owned))
    }

    /// Write a commit's tree into `dir`, which must be empty, through the
    /// Git backend; nothing in the repository changes.
    pub fn materialize(&self, commit_id: &str, dir: &Path) -> Result<()> {
        let mut c = self.command(None);
        c.args(["git", "root"]);
        let git_dir = String::from_utf8(self.run(c, "git root")?.stdout)?
            .trim()
            .to_owned();
        let mut archive = Command::new("git")
            .args(["--git-dir", &git_dir, "archive", "--format=tar", commit_id])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .context("running git archive")?;
        let stdout = archive.stdout.take().context("git archive has no output")?;
        let tar = Command::new("tar")
            .arg("-x")
            .arg("-C")
            .arg(dir)
            .stdin(stdout)
            .output()
            .context("running tar")?;
        let status = archive.wait()?;
        if !status.success() || !tar.status.success() {
            bail!(
                "could not write the tree of {commit_id}: {}",
                String::from_utf8_lossy(&tar.stderr).trim()
            );
        }
        Ok(())
    }

    /// Whether two revisions have the same tree.
    pub fn same_tree(&self, at: &str, from: &str, to: &str) -> Result<bool> {
        Ok(self
            .read(at, &["diff", "--summary", "--from", from, "--to", to])?
            .trim()
            .is_empty())
    }
}

/// The revset naming one change. Explicit, so no bookmark of the same name
/// can shadow it.
pub fn change(id: &str) -> String {
    format!("change_id({id})")
}

/// The revset naming one commit.
pub fn commit(id: &str) -> String {
    format!("commit_id({id})")
}

/// A revset that is exactly these commits.
pub fn commits<'a>(ids: impl IntoIterator<Item = &'a String>) -> String {
    let ids: Vec<String> = ids.into_iter().map(|id| commit(id)).collect();
    if ids.is_empty() {
        "none()".to_owned()
    } else {
        ids.join(" | ")
    }
}
