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
- Before saving a multi-command IntelliShell template, validate it with
  `nu -c` when practical.

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

## Project task discipline

For JJ projects, use one topic, one dedicated JJ workspace, and one stable
change ID per Codex task. Treat the session hook's recorded change as the task's
revision. Rewrite that change throughout the task; do not run `jj new`,
`jj commit`, or create a follow-up revision after publishing. A new topic needs
a new task and a separate workspace; do not switch a working copy owned by
another active task. Use `jj workspace add --revision main@origin --name NAME
PATH` from the repository, then open that directory as a local Codex project.
The hook creates the topic revision when its task starts.

Use JJ for version-control mutations. Do not use the desktop app's Git commit,
stage, branch, worktree, handoff, push, or merge actions for these tasks.
Keep Git available as an internal transport dependency. Use `jj-dashboard`
or the desktop Open in → JJ dashboard action for interactive revision work.

Where `jj-ci` is available, publish in place with `jj-ci publish`; rebase the
same topic with `jj-ci rebase`. Enable auto-merge only when the user is finished
with the topic and has requested delivery. Before archiving a delivered topic,
run `jj-ci finish`: it verifies that the current head was merged to main and
leaves a clean working copy on main. Only then call the archive tool. Failed
checks, conflicts, pending delivery, or unpublished edits leave the task open.
Do not treat app exit, idle timeout, or SessionEnd as authorization to publish
or merge. Direct archive-button clicks do not execute this closeout workflow.

For local Nix flake operations, use an explicit `path:` reference when new
files must be included, for example `nix develop path:.` or
`nix build path:.#OUTPUT`. Git-backed flake inputs omit untracked files; they
already include unstaged edits to tracked files. Path inputs include ignored
files too, so keep generated files and plaintext secrets outside the source
root used for Nix. Never stage files with Git as a flake workaround.
