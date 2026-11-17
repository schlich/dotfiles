---
type: plan
description: Add an OpenCode TUI plugin with live views of version control, CI, background jobs, luvus tasks, and the staged NixOS switch.
created: 2026-11-06
generated:
  by: claude-code/opus-5
  at: 2026-11-06T17:50:00Z
sources:
- id: tui-api
  resource: opencode:packages/plugin/src/tui/context.ts
  title: OpenCode 2 TUI plugin API (slots, panel, keymap layers, modes)
- id: tui-loader
  resource: opencode:packages/tui/src/plugin/context.tsx
  title: TUI plugin discovery and loading
- id: server-scan
  resource: opencode:packages/core/src/config/plugin/source.ts
  title: server plugin scan, which skips a directory without a server entry
- id: fieldnotes
  resource: fieldnotes:README.md
  title: Fieldnotes' panels, sources, and NORMAL/DETAIL keys
---

# Add an OpenCode workflow-status plugin

## Context

Agents here leave state in several places at once: the checkout's JJ or Git
state, GitHub checks and nixbot's gate on the pushed commit, `job-log` and ci
MCP jobs on cross.stream, Claude Code's background tasks, luvus tasks, and the
host's staged switch. Fieldnotes shows much of it on homelab's wallpaper, but
nothing shows it beside an OpenCode session. OpenCode 2's TUI plugin API offers
sidebar and home-footer slots, a session side panel, and keymap layers with
input modes[^tui-api], so a plugin can keep those views in the session and
current.

## Approach

One TUI plugin, `plugins/workflow-status`, in three layers: `model.ts` parses
each source's output and summarizes it (pure, unit-tested); `collect.ts` runs
the commands and follows the files, in hubs shared by every view and started
only while a view needs them; `tui.tsx` renders a sidebar section, a home-footer
item, and the workflow panel (`ctrl+x o`, `/workflow`), with a full-screen route
outside sessions. The panel follows the keymap rule: its bottom line always
names the mode (NORMAL, DETAIL, or PROMPT while unfocused) and lists the keys
that work, which follow Fieldnotes' NORMAL and DETAIL modes[^fieldnotes].

It ships as a directory under `~/.config/opencode/plugins/`, through the
existing `dotfiles.tooling.opencodeConfig` links: the TUI loads a directory's
`tui` entry[^tui-loader], and the server skips a directory with no server
entry[^server-scan]. A generated `tools.ts` names every program by store path,
so the plugin reads the wrapped Git and JJ configuration whatever PATH the TUI
inherits.

Rejected: listing the plugin in `cli.json` through `programs.opencode.cli` would
merge a store path into a file OpenCode rewrites, and an explicit entry turns a
missing plugin into a startup error; a server plugin that pushes state to the
TUI over RPC would add a protocol where the TUI can run the read-only commands
itself.

## Implementation Steps

### Task 1: Write the plugin

**Files:** Create: `plugins/workflow-status/model.ts`,
`plugins/workflow-status/collect.ts`, `plugins/workflow-status/tui.tsx`,
`plugins/workflow-status/tools.ts`, `plugins/workflow-status/model.test.ts`,
`plugins/workflow-status/README.md`

- [x] Parse `git status --porcelain=v2`, the `jj log` template, remotes, check
  runs, commit statuses, pull requests, cross.stream job frames, NUON job
  records, OSC 7501 reports, Fieldnotes task records, luvus tasks, and the
  switch's status, generation, and revert records.
- [x] Collect without side effects: `jj --ignore-working-copy`, Git without
  optional locks, watchers on the Git directory and JJ's operation heads, CI
  polling that tightens while checks run, and a cross.stream follower.
- [x] Render the sidebar, home footer, panel, and route, with the mode badge and
  hint line, and toast failures and reverts.

### Task 2: Wire it into OpenCode

**Files:** Modify: `modules/tooling/ai/plugins.nix`,
`modules/tooling/interface.nix`

- [x] Package the plugin directory with a generated `tools.ts` and register it
  as `workflow-status`.
- [x] Add the `opencode-workflow-status` check, which transpiles every source
  and runs `bun test`.

### Task 3: Deliver and try it

- [x] Run the task gate in the t40 worktree, which builds the new check: passed
  on 2026-11-17, its 27 model tests among the checks. The task has no linked
  branch, so the gate ran there directly rather than through `luvus task done`.
- [ ] Deliver through `luvus-deliver`, activate the home, and open OpenCode in a
  JJ repository, a Git worktree, and the home screen.

## Spec changes

None — this graph has no `data/spec/` documents, and the plugin changes no
behavior a spec describes. The plugin's README holds its views, keys, and
sources.

## Verification

- `nix build path:.#homeConfigurations."schlich@asus".config.dotfiles.tooling.checks.opencode-workflow-status`
  (or the task gate, through `checks.x86_64-linux.home-manager`) transpiles
  `collect.ts`, `model.ts`, `tools.ts`, the generated tools file, and `tui.tsx`,
  and runs `model.test.ts`.
- After activation, `/plugins` in OpenCode lists `dotfiles.workflow-status` as
  active; the sidebar shows the Workflow section, and `ctrl+x o` opens the
  panel, which shows the NORMAL badge and its keys once focused (`ctrl+x →`).

## Out of scope

- The `ci` workflow's own status in ci repositories: its jobs appear through
  cross.stream, but `ci status` stays in the terminal.
- Tangled and spindle CI, which `main` no longer gates on.
- Porting `jj-main-changeset.ts` and `jj-shell-environment.ts` to OpenCode 2's
  plugin API: the server rejects both V1 files today ("Plugin must export a
  default definition with an id and an effect or setup function").

## Key references

Verified anchor points (line numbers as of 2026-11-06):

- `plugins/workflow-status/tui.tsx:906` — `Plugin.define`
  (`dotfiles.workflow-status`)
- `plugins/workflow-status/tui.tsx:397` — `WorkflowView`, the panel and route
- `plugins/workflow-status/tui.tsx:896` — `<leader>o`, the toggle command
- `plugins/workflow-status/collect.ts:1041` — `createHubs`
- `plugins/workflow-status/collect.ts:257` — `inspect`, JJ, Git, or nested
  worktree
- `plugins/workflow-status/collect.ts:734` — `createHostHub`, jobs and the
  switch
- `plugins/workflow-status/model.ts:215` — `JJ_TEMPLATE`
- `plugins/workflow-status/model.ts:845` — `applyFrame`
- `modules/tooling/ai/plugins.nix:16` — `workflowTools`, the generated program
  paths
- `modules/tooling/ai/plugins.nix:61` —
  `dotfiles.tooling.checks.opencode-workflow-status`
- `modules/tooling/ai/opencode.nix:38` — `xdg.configFile` links for
  `opencodeConfig`

[^tui-api]: `packages/plugin/src/tui/context.ts` in the pinned `opencode` input.

[^tui-loader]: `packages/tui/src/plugin/context.tsx` and `discovery.ts`.

[^server-scan]: `packages/core/src/config/plugin/source.ts`, `scan`.

[^fieldnotes]: Fieldnotes' README, "Modes and keys".
