# Shell conventions

The user's interactive and configured automation shell is Nushell. When
producing a user-facing shell command, IntelliShell template, alias, or
script, use valid Nushell syntax.

- Use `;` to run commands sequentially. Do not use Bash operators such
  as `&&` or `||` unless deliberately invoking a POSIX shell.
- When a subsequent command must depend on an external command's exit
  status, use Nushell control flow and `complete`; do not emulate it
  with Bash chaining.
- A tool invocation may use its own execution shell, but never copy that
  shell's syntax into a command intended for the user's Nushell prompt.
- Use Nushell (`nu`) for shell pipelines and text processing instead of tools
  such as `jq`, `awk`, `sed`, `grep`, or `rg`; prefer structured Nushell
  commands and pipelines for searching, filtering, and transforming data.
- Prefer the Nushell evaluate tool for Nushell commands, pipelines, and
  interactive exploration. It preserves the Nushell session and structured
  results; do not invoke `nu -c` through a shell just to evaluate Nushell.
- Before saving a multi-command IntelliShell template, validate it with the
  Nushell evaluate tool when available. Use `nu -c` only when that tool is
  unavailable or when validation specifically requires a fresh Nushell process.

# Nix configuration

- Treat application-owned, self-mutating configuration as runtime state. Do
  not put such files under Home Manager's `home.file`, `xdg.configFile`, or
  `programs.*.settings`; couple immutable defaults to the package with a
  wrapper or command-line override, or use the application's system-level
  configuration layer. Codex Desktop rewrites `$CODEX_HOME/config.toml`, so
  static Codex defaults belong on its wrapped package; Home Manager can still
  manage non-mutating skills and context files.

# Jujutsu

Do not invoke `jj` in interactive mode. Use only non-interactive invocations,
supplying every required argument or message flag explicitly.

Codex shell commands and OpenCode server shell execution receive a no-op
`JJ_EDITOR` and an unpaginated `PAGER`. This prevents an accidental editor or
pager from blocking an agent command; it does not replace explicit
non-interactive flags for commands that prompt for other input. Use
`-m`/`--message`, explicit filesets and revsets, and `--no-interactive` where
the command provides it. Use `jjui` or the JJ dashboard for genuinely
interactive revision work in a terminal.

## Project task discipline

For JJ projects, use one coherent topic, one dedicated JJ workspace, and one
stable change ID for a single deliverable. When a task contains multiple
deliverables that should be split, keep them in one small stack in that
workspace and rewrite each in-scope change as needed; do not create unrelated
follow-up revisions after publishing. A new topic needs a new task and a
separate workspace; do not switch a working copy owned by another active task.
Where `jj-ci` is available, create it with `jj-ci start NAME`; otherwise use
`jj workspace add --revision main@origin --name NAME PATH` from the
repository. Then open that directory as a local Codex project.
The hook creates the topic revision when its task starts.
If Codex supplied the project as a linked Git worktree, the session hook
initializes a non-colocated JJ workspace in that directory first, using the
shared Git repository as its backend. It never automatically switches another
task's working copy.

When the working-copy diff contains multiple coherent deliverables, split it
into separate JJ changes before publishing or treating the work as complete.
Choose the topology from the dependency, not from file proximity: make a
parent/child chain only when the later change needs the earlier one to build,
test, or make sense; make siblings when both changes are independently
reviewable and can land independently. JJ provides this directly: `jj split`
creates a parent/child pair by default, and `jj split --parallel` creates two
sibling changes. After every split, set explicit descriptions, inspect `jj log`,
and repeat the classification if more than two changes remain. Create a
checkpoint before splitting, as for other history surgery. Do not use the
default parent/child shape just because it is convenient, and do not combine
changes merely because they touch related files.

When the working-copy diff contains multiple coherent deliverables, split it
into separate JJ changes before publishing or treating the work as complete.
Choose the topology from the dependency, not from file proximity: make a
parent/child chain only when the later change needs the earlier one to build,
test, or make sense; make siblings when both changes are independently
reviewable and can land independently. JJ provides this directly: `jj split`
creates a parent/child pair by default, and `jj split --parallel` creates two
sibling changes. After every split, set explicit descriptions, inspect `jj log`,
and repeat the classification if more than two changes remain. Create a
checkpoint before splitting, as for other history surgery. Do not use the
default parent/child shape just because it is convenient, and do not combine
changes merely because they touch related files.

Use JJ for version-control mutations. Do not use the desktop app's Git commit,
stage, branch, worktree, handoff, push, or merge actions for these tasks.
Keep Git available as an internal transport dependency. Use `jj-dashboard`
or the desktop Open in → JJ dashboard action for interactive revision work.

Where `jj-ci` is available, keep the topic in a dedicated workspace rooted at
`main@origin`; rebase after trunk advances and before review or queue updates.
`jj-ci publish` and `jj-ci stack-merge` perform a final rebase before updating
GitHub. Enable auto-merge only when the user is finished with the topic and has
requested delivery. Herdr or Paseo may supervise and report stale trunk or PR
state for that one workspace, but must not silently rebase or resolve
conflicts. Before archiving a delivered topic, run
`jj-ci finish`: it verifies that the current head was merged to main and
removes a workspace that `jj-ci start` created, or leaves any other one on a
clean change on main. Use `jj-ci abandon` for a topic that will not land. Only then call the archive tool. Failed
checks, conflicts, pending delivery, or unpublished edits leave the task open.
Do not treat app exit, idle timeout, or SessionEnd as authorization to publish
or merge. Direct archive-button clicks do not execute this closeout workflow.

For local Nix flake operations, use an explicit `path:` reference when new
files must be included, for example `nix develop path:.` or
`nix build path:.#OUTPUT`. Git-backed flake inputs omit untracked files; they
already include unstaged edits to tracked files. Path inputs include ignored
files too, so keep generated files and plaintext secrets outside the source
root used for Nix. Never stage files with Git as a flake workaround.
