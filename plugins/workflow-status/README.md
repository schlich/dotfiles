# Workflow status

An OpenCode TUI plugin that keeps the agentic workflow around a session in
view and current. `modules/tooling/ai/plugins.nix` installs it as
`~/.config/opencode/plugins/workflow-status`, a directory whose `tui.tsx`
entry OpenCode's TUI loads; its server skips a directory without a server
entry.

## Views

- **Sidebar**: a Workflow section with one line per source — always version
  control and CI, the others while they report or need attention. A line opens
  the panel at its section.
- **Home footer**: the same summary in one item.
- **Workflow panel** (`ctrl+x o` or `/workflow`): every row of every section,
  in the session's side panel, or full screen outside a session.
- **Toasts**: a failed or lost job, CI turning red, nixbot passing, a task
  blocked or in review, and a switch finishing, failing, or reverting. Errors
  also go through OpenCode's attention notifications when they are enabled.

| Section | Shows                                                                                                                                          | Source                                                                                                            |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| VCS     | JJ: the working-copy change, its bookmarks, commits ahead of trunk, and, when colocated, Git's live edits. Git: branch, upstream, and changes. | `jj log --ignore-working-copy` (never snapshots), `git status --porcelain=v2` without optional locks              |
| CI      | Check runs and commit statuses on the latest pushed commit, nixbot's gate first among equals, and its pull requests                            | `gh api repos/OWNER/REPO/commits/SHA/{check-runs,status,pulls}`                                                   |
| Jobs    | Running and recently finished `job-log` and ci MCP jobs with their latest progress report, Claude Code background tasks, and OpenCode shells   | cross.stream `job.*` frames, `LOG.job.nuon`, `LOG.status.jsonl`; Fieldnotes' agent-tasks records; OpenCode's data |
| Tasks   | This checkout's luvus task and the repository's other open tasks                                                                               | `luvus task list --json`                                                                                          |
| Deploy  | The staged NixOS switch in progress, the last generation, and the last revert                                                                  | `/var/lib/nixos-switch-main/{status,generations,reverts}.jsonl`                                                   |

A section with nothing to show on a host, such as Tasks without luvus or Deploy
off a switching NixOS host, is left out.

## Keys and modes

The panel's bottom line always shows the current mode and every key that works
in it. While the docked panel does not have focus, the mode reads `PROMPT` and
the line shows how to focus it (`ctrl+x →`) or close it.

| Mode   | Enter with         | Leave with             | Keys                                                                                                                                                    |
| ------ | ------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NORMAL | focusing the panel | `esc` or `q` closes it | `j`/`k` move, `g`/`G` top/bottom, `h`/`l` or `tab` section, `1`–`5` jump, `⏎` details, `o` open, `y` copy, `r`/`R` refresh section/all, `f` full screen |
| DETAIL | `⏎`                | `esc`, `⏎`, or `q`     | `j`/`k` scroll, `o` open, `y` copy, `r` refresh                                                                                                         |

The keys follow Fieldnotes' NORMAL and DETAIL modes. `ctrl+x o` toggles the
panel from anywhere, as `ctrl+space o` opens Luvus's board. `o` opens a URL in
the desktop's browser; without a desktop session it copies the URL instead.

## Refresh

Version control refreshes every 6 seconds, on changes to the Git directory or
JJ's operation heads, and after OpenCode finishes a turn or a shell. CI polls
every 20 seconds while a check runs and every 2 minutes otherwise, and at once
when the pushed commit changes. Jobs follow cross.stream as frames arrive.
Collectors run only while a view needs them.

## Development

`tools.ts` names the programs it runs; the Nix package replaces it with store
paths. `model.ts` holds the parsing and summaries, and `bun test model.test.ts`
covers it; the `opencode-workflow-status` flake check runs those tests and
transpiles every source file.
