//! Reading jj's Git-format diffs, and line-level changes between two texts.
//!
//! jj-graph asks jj for each change's diff with enough context to cover whole
//! files (`jj diff --git --context N`), so every hunk carries the complete
//! before and after text. That works for merges too, whose "before" is the
//! auto-merged parents, which `jj file show` cannot print.

use std::ops::Range;

use anyhow::{Context, Result, bail};
use similar::{Algorithm, DiffOp, capture_diff_slices};

/// One file of a change's diff.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileDiff {
    /// The path before the change, if the file existed.
    pub old_path: Option<String>,
    /// The path after the change, if the file still exists.
    pub new_path: Option<String>,
    /// The whole text before and after, when the diff showed it.
    pub old: String,
    pub new: String,
    /// The file is binary, so jj showed no text.
    pub binary: bool,
    /// The file only moved or changed mode: its text is the same on both
    /// sides, and the diff did not show it, so `old` and `new` are empty.
    pub same_text: bool,
}

impl FileDiff {
    /// Every path the change touches for this file.
    pub fn paths(&self) -> impl Iterator<Item = &String> {
        self.old_path.iter().chain(
            self.new_path
                .iter()
                .filter(|p| Some(*p) != self.old_path.as_ref()),
        )
    }

    /// The path a language is chosen by: the new one, or the old one for a
    /// deletion.
    pub fn path(&self) -> &str {
        self.new_path
            .as_deref()
            .or(self.old_path.as_deref())
            .unwrap_or_default()
    }
}

/// Parse `jj diff --git` output whose context covers whole files. jj writes
/// paths as they are, never quoted.
pub fn parse_git_diff(text: &str) -> Result<Vec<FileDiff>> {
    let mut files = Vec::new();
    let mut lines = text.split_inclusive('\n').peekable();
    while let Some(line) = lines.next() {
        let Some(header) = line.strip_prefix("diff --git ") else {
            if line.trim().is_empty() {
                continue;
            }
            bail!("expected a `diff --git` header, found {line:?}");
        };
        let (a, b) = split_header(header.trim_end_matches('\n'))?;
        let mut file = FileDiff {
            old_path: Some(a),
            new_path: Some(b),
            ..FileDiff::default()
        };
        let (mut old, mut new) = (String::new(), String::new());
        let mut last_side = ' ';
        let mut saw_hunk = false;
        while let Some(line) = lines.peek() {
            if line.starts_with("diff --git ") {
                break;
            }
            let line = lines.next().expect("peeked");
            let body = line.trim_end_matches('\n');
            if !saw_hunk {
                if line.starts_with("new file mode") {
                    file.old_path = None;
                } else if line.starts_with("deleted file mode") {
                    file.new_path = None;
                } else if let Some(p) = body.strip_prefix("rename from ") {
                    file.old_path = Some(p.to_owned());
                } else if let Some(p) = body.strip_prefix("rename to ") {
                    file.new_path = Some(p.to_owned());
                } else if let Some(p) = body.strip_prefix("copy from ") {
                    file.old_path = Some(p.to_owned());
                } else if let Some(p) = body.strip_prefix("copy to ") {
                    file.new_path = Some(p.to_owned());
                } else if line.starts_with("Binary files ") || line.starts_with("GIT binary patch")
                {
                    file.binary = true;
                } else if line.starts_with("@@") {
                    saw_hunk = true;
                } else if !(file.binary
                    || line.starts_with("--- ")
                    || line.starts_with("+++ ")
                    || line.starts_with("index ")
                    || line.starts_with("old mode")
                    || line.starts_with("new mode")
                    || line.starts_with("similarity index")
                    || line.starts_with("dissimilarity index"))
                {
                    bail!("unexpected line in the header of {}: {line:?}", file.path());
                }
                continue;
            }
            // Inside the hunks every line is content, whatever it starts
            // with after its marker: a removed `-- x` is `--- x`.
            if line.starts_with("@@") {
            } else if line.starts_with("\\ ") {
                // "\ No newline at end of file" applies to the line before:
                // one side's line, or a context line on both sides.
                if last_side != '+' && old.ends_with('\n') {
                    old.pop();
                }
                if last_side != '-' && new.ends_with('\n') {
                    new.pop();
                }
            } else if let Some(rest) = line.strip_prefix(' ') {
                old.push_str(rest);
                new.push_str(rest);
                last_side = ' ';
            } else if let Some(rest) = line.strip_prefix('-') {
                old.push_str(rest);
                last_side = '-';
            } else if let Some(rest) = line.strip_prefix('+') {
                new.push_str(rest);
                last_side = '+';
            } else if line == "\n" {
                // An empty context line that lost its leading space.
                old.push('\n');
                new.push('\n');
                last_side = ' ';
            } else {
                bail!("unexpected line in the diff of {}: {line:?}", file.path());
            }
        }
        file.same_text =
            file.old_path.is_some() && file.new_path.is_some() && !saw_hunk && !file.binary;
        file.old = old;
        file.new = new;
        files.push(file);
    }
    Ok(files)
}

/// Split `a/X b/Y` into its two paths. A path may hold ` b/` itself, but
/// the two are the same unless the file moved or was copied: then the split
/// that gives two equal paths is the one, and a move or copy names its paths
/// again on lines of their own, which win.
fn split_header(header: &str) -> Result<(String, String)> {
    let rest = header
        .strip_prefix("a/")
        .context("no `a/` path in the diff header")?;
    let half = rest.len().saturating_sub(3) / 2;
    if rest.len() == 2 * half + 3
        && &rest.as_bytes()[half..half + 3] == b" b/"
        && rest[..half] == rest[half + 3..]
    {
        return Ok((rest[..half].to_owned(), rest[half + 3..].to_owned()));
    }
    let i = rest
        .find(" b/")
        .context("no `b/` path in the diff header")?;
    Ok((rest[..i].to_owned(), rest[i + 3..].to_owned()))
}

/// One file of a diff, reduced to what a clean rebase must keep: its paths,
/// whether it is binary, and its added and removed lines in order, without
/// context, line numbers, or missing-newline markers.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct FilePatch {
    pub header: String,
    pub binary: bool,
    pub lines: Vec<String>,
}

/// Reduce a Git-format diff to its [`FilePatch`]es.
pub fn patch_signature(text: &str) -> Vec<FilePatch> {
    let mut out: Vec<FilePatch> = Vec::new();
    let mut in_hunks = false;
    for line in text.lines() {
        if let Some(header) = line.strip_prefix("diff --git ") {
            out.push(FilePatch {
                header: header.to_owned(),
                binary: false,
                lines: Vec::new(),
            });
            in_hunks = false;
            continue;
        }
        let Some(file) = out.last_mut() else { continue };
        if line.starts_with("@@") {
            in_hunks = true;
        } else if line.starts_with("Binary files ") || line.starts_with("GIT binary patch") {
            file.binary = true;
        } else if !in_hunks {
            // Mode and rename lines describe the change; index lines name
            // blobs, which a rebase does not change for the files it keeps.
            if !line.starts_with("index ") && !line.starts_with("--- ") && !line.starts_with("+++ ")
            {
                file.lines.push(line.to_owned());
            }
        } else if line.starts_with('+') || line.starts_with('-') {
            // "\ No newline at end of file" is left out: jj prints it for a
            // context line under some context sizes and not others.
            file.lines.push(line.to_owned());
        }
    }
    out.sort();
    out
}

/// The lines (0-based) of `new` that are not in `old`, after a line diff.
/// A line ends at `\n` only, as tree-sitter counts rows, so a lone `\r`
/// stays inside its line.
pub fn added_lines(old: &str, new: &str) -> Vec<Range<usize>> {
    let old: Vec<&str> = old.split_inclusive('\n').collect();
    let new: Vec<&str> = new.split_inclusive('\n').collect();
    let mut out: Vec<Range<usize>> = Vec::new();
    for op in capture_diff_slices(Algorithm::Myers, &old, &new) {
        let (start, len) = match op {
            DiffOp::Insert {
                new_index, new_len, ..
            }
            | DiffOp::Replace {
                new_index, new_len, ..
            } => (new_index, new_len),
            DiffOp::Equal { .. } | DiffOp::Delete { .. } => continue,
        };
        if len == 0 {
            continue;
        }
        match out.last_mut() {
            Some(r) if r.end == start => r.end = start + len,
            _ => out.push(start..start + len),
        }
    }
    out
}
