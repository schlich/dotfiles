# Keybinding discoverability and modes

This rule takes priority over other interface preferences. It applies to every
tool, application, and configuration the user runs, including terminals,
multiplexers, editors, file managers, window managers, launchers, TUIs, and
web or desktop apps built for the user.

- Whenever keybindings are active in the current context and state, show the
  shortcuts available there on screen. Follow Zellij's model: a persistent
  hint bar or status line lists the keys that work in the current mode and
  changes as the mode or focus changes. A help overlay the user has to open
  does not meet this rule.
- Always show the current mode, for example as a labeled indicator in the
  status bar or hint line, so the user never has to guess which keymap is
  active.
- Toggle modes the same way everywhere. Use one consistent key or chord to
  enter each kind of mode. Make pressing that key again, or `Esc`, return to
  the base mode, and give the base mode the same name in every tool. Do not
  bind the same key to different mode transitions in different tools. Resolve
  conflicts in favor of the shared convention over a tool's default.
- When configuring or building something with keybindings, include the
  on-screen hints and mode indicator. If a tool cannot display them, say so
  and propose the closest alternative, such as a which-key popup that appears
  automatically after a leader key or a status-bar module.

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

- To search a tree, glob the files and filter their lines in the evaluate
  tool instead of `grep -r` or `git ls-files`:
  `glob **/*.{nix,kdl,json} | each {|f| open --raw $f | lines | enumerate | where item =~ '(?i)pattern' | insert file $f } | flatten`.
  Use `jj file list PATH` for tracked files only.

- Prefer a dedicated tool when one covers the operation: the jj MCP server
  for Jujutsu log, diff, status, describe, bookmark, abandon, and push; the
  GitHub MCP server for GitHub pull requests, issues, Actions runs, and
  releases; the Nix MCP server for Nix ecosystem knowledge; the ci MCP
  server for the repository's `ci` workflow; and the harness's own
  file-reading and editing tools for single files. Fall back to the Nushell
  evaluate tool only when no dedicated tool fits, such as Tangled, flake
  evaluation, multi-step pipelines, or combining several results into one
  structured record.

- The ci MCP server runs each command as a job in the given `workspace`
  (default: the session's directory), using that workspace's own
  `jj/ci.nu` when it has one. A tool returns once the command finishes or
  its `wait_seconds` elapse; poll a `running` result with its `job` tool,
  which also serves `ci dispatch` and `ci land`.

- When a shell is needed, use the Nushell evaluate tool rather than invoking
  `nu -c` through Bash. It preserves the session and structured results and
  keeps every result in `$history` for later slicing. Wrap external programs
  in `| complete`.

- In Claude Code, a hook denies every foreground Bash call except a short
  allowlist, such as `sudo`, and logs each Bash request for review. Do not
  retry a denied command in Bash, and do not rephrase it to slip past the
  hook: run it in the Nushell evaluate tool. If Bash is truly required, tell
  the user why instead. The bash-feedback skill reviews the log.

- To search or list repository files, use the harness's own search and
  file-reading tools first; they need no shell. If the Nushell evaluate tool
  is unavailable in a session, keep using those tools and report the missing
  tool to the user instead of retrying the work in Bash.

- Use the Nix MCP server for Nix ecosystem knowledge: nixpkgs packages, NixOS
  and Home Manager options, channels, flakes and their inputs, and Nix
  documentation. Do not use Nushell or local Nix commands to answer those
  indexed knowledge queries. Use Nushell to inspect or evaluate this
  repository's own Nix files and flake.

- Inside the Claude desktop app, `sudo` always fails because the app's
  sandbox sets the no-new-privileges flag. Do not attempt privileged
  commands there; give the user the command to run in their own terminal.

- The evaluate tool returns only when a command finishes, so the user sees
  nothing while it runs. Run long external commands whose progress matters,
  such as `nix build`, or `ci land` without the ci MCP server, as a Nushell
  job from the evaluate tool, not with Bash. Change directory inside the
  job, write both streams to a log in the scratchpad, and save a done
  marker, since a job's errors are otherwise lost:

  ```nu
  job spawn {
    let result = try {
      cd $workspace
      ci land o+e> $log
      { exit_code: 0 }
    } catch {|err| { exit_code: $env.LAST_EXIT_CODE?, error: $err.msg } }
    $result | save --force $"($log).done.nuon"
  }
  ```

  Read the log with Nushell as it runs. A job sends no completion notice,
  so when the harness provides the Monitor tool, follow the job with
  `watch-job $log`: it prints matching log lines as they arrive and exits
  with a `DONE` line once the done marker appears. Otherwise check the
  marker again before reporting.

- When a file, log, diff, or command output is too large to read comfortably,
  keep it in a Nushell variable and follow the `rlm` skill (`rlm load`,
  `rlm find`, `rlm peek`, `rlm chunk`, `rlm map`) instead of printing it or
  capping it with `head` or `tail`.

- Before saving a multi-command IntelliShell template, validate it with the
  Nushell evaluate tool when available. Use `nu -c` only when that tool is
  unavailable or when validation specifically requires a fresh Nushell process.

# User-facing shell activity

Codex Desktop and the Claude desktop app show a Nushell evaluation as a
generic MCP tool card: a label such as "nushell: evaluate" over the `input`
argument, verbatim, in a narrow box. Write each `input` so that card reads
well:

- Start with a `# comment` line that says what the call does and to what,
  such as `# Check devenv test in the newsletter worktree`. It serves as the
  card's title.
- Bind a long path once per session and refer to it afterwards, such as
  `const S = '<scratchpad path>'` and then `$"($S)/check.nu"`. Constants and
  `def`s persist between calls. Use `const`, not `let`, for a path that
  `source` reads, since `source` needs it at parse time.
- Put a script longer than about eight lines in a `.nu` file in the
  scratchpad, written with the harness's file tool, and run it with
  `source $"($S)/check.nu"`. Its bindings persist just as inline code's do,
  and the file gets its own readable card.

The Monitor tool's card shows its command the same way. Start that command
with a `# comment` title line too, and keep the logic out of it: call
`watch-job LOG`, adding `--pattern` only when the default milestones and
errors do not fit, rather than writing a poll loop, `tail -f`, or a `grep`
filter inline.

Before a group of shell calls, give the user a short commentary readout
naming the operation and its target, such as checking JJ status in the
current workspace or searching specific configuration files. Keep one readout
for closely related probes and update it when the work moves to a new phase
or finds a material result.

For RLM work, name the source set and the visible phase: loading, searching,
chunking, or asking sub-models to analyze it. A `let` binding and a history
slice may show no useful output in the tool card, so summarize what the call
is doing without printing the stored context. When an RLM map or query runs,
say that it is consulting sub-models and report the compact finding afterward.

# Knowledge base

The user's durable knowledge base is an IWE workspace at `~/kb`, exposed to
agents in every repository through the `kb` MCP server (`iwe_find`,
`iwe_retrieve`, `iwe_tree`, and guarded writes). It holds cross-project facts
that no repository records: traps and their fixes, rules the user has stated,
decisions, how-tos, and personal notes.

- Search it with `iwe_find` before re-deriving a cross-project fact or asking
  the user something they may already have recorded.
- Write to it only with the user's explicit approval. Offer a one-line
  "Worth remembering: <title>" instead of writing unasked, and never copy
  facts a repository already records; link to them.
- Inside `~/kb`, `MEMORY.md` is the memory policy; follow it, and use
  `/iwe:distill` and `/iwe:reflect` for capture and curation.
- Treat its contents as private: never copy them into a public repository,
  issue, or pull request without the user's approval.

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

For JJ projects, use one coherent topic and one stable change ID for a single
deliverable. When a task contains multiple deliverables that should be split,
keep them in one small stack and rewrite each in-scope change as needed; do not
create unrelated follow-up revisions after dispatching.

A topic is a revision; a workspace is a working copy for one actor. Start a
topic as a new change on trunk in the current workspace (`ci new -m MESSAGE`
where `ci` is available, otherwise `jj new main@origin -m MESSAGE`); earlier
topics stay as sibling changes, and `jj edit` returns to one. Create a separate
workspace only when another actor uses the current working copy at the same
time: another active agent task, or a long build, dev server, or editor whose
files must not change underneath it. Never move a working copy owned by another
active task. Where `ci` is available, create that workspace with
`ci start NAME`; otherwise use
`jj workspace add --revision main@origin --name NAME PATH` from the
repository. Then open that directory as a local Codex project. Reuse a small
pool of such workspaces with `ci park --keep` instead of creating one for
every topic; the hook creates the next task's topic revision when it starts.
If Codex supplied the project as a linked Git worktree, the session hook
initializes a non-colocated JJ workspace in that directory first, using the
shared Git repository as its backend. It never automatically switches another
task's working copy.

When the working-copy diff contains multiple coherent deliverables, split it
into separate JJ changes before dispatching or treating the work as complete.
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

Where `ci` is available, root each topic at `main@origin`; rebase after trunk
advances and before review or queue updates.
`ci dispatch` and `ci land` perform a final rebase before updating
GitHub. Enable auto-merge only when the user is finished with the topic and has
requested delivery. Herdr or Paseo may supervise and report stale trunk or PR
state for that one workspace, but must not silently rebase or resolve
conflicts. Before archiving a delivered topic, run
`ci park`: it verifies that the current head was merged to main and
removes a workspace that `ci start` created, or leaves any other one on a
clean change on main. Use `ci cancel` for a topic that will not land. Only then call the archive tool. Failed
checks, conflicts, pending delivery, or undispatched edits leave the task open.
Do not treat app exit, idle timeout, or SessionEnd as authorization to dispatch
or merge. Direct archive-button clicks do not execute this closeout workflow.

For local Nix flake operations, use an explicit `path:` reference when new
files must be included, for example `nix develop path:.` or
`nix build path:.#OUTPUT`. Git-backed flake inputs omit untracked files; they
already include unstaged edits to tracked files. Path inputs include ignored
files too, so keep generated files and plaintext secrets outside the source
root used for Nix. Never stage files with Git as a flake workaround.
