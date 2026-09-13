---
name: jj-ci
description: Use the repository's jj-ci workflow to inspect, synchronize, validate, publish, and reconcile JJ changes. Apply when jj-ci is available; do not use it as a generic Jujutsu tutorial.
---

# jj-ci workflow

Use this skill when the repository provides the `jj-ci` command. It is the
repository's policy layer around Jujutsu, Prek, GitHub pull requests, and the
trunk workflow.

## Before acting

- Start with `jj status`, `jj diff`, and a focused `jj log` for the current
  change and its ancestors.
- Preserve unrelated working-copy changes. Jujutsu has no staging area, so
  every file in the working copy belongs to the current change unless the
  user says otherwise.
- Treat change IDs as the stable identity of a change and commit IDs as
  content hashes that can change when the change is rewritten.
- Inspect conflicts and emptiness before choosing a workflow.
- Before a synchronization that rebases history, create a checkpoint with
  `.agents/skills/jj/scripts/jj-checkpoint`.

## JJ MCP integration

When the `jj` MCP server is available, use its read-only status, log, diff,
show, file, bookmark, and operation-log tools for repository inspection. Read
the server's workflow guidance before a non-trivial JJ operation.

Use `jj-ci` for repository policy workflows even when the MCP server exposes
equivalent low-level commands:

- `jj-ci validate` for formatting and Prek gates;
- `jj-ci publish` for stable bookmark, push, and pull-request handling while
  retaining the same working-copy change;
- `jj-ci rebase` for updating that topic in place;
- `jj-ci finish` for verified delivery and workspace cleanup before archiving;
- `jj-ci github reconcile` for declared GitHub policy;
- `jj-ci stack-merge` for validated stack submission.

Do not use low-level MCP mutation tools such as restore, abandon, direct push,
or rebase unless the user explicitly requests that specific operation and the
repository workflow does not provide the appropriate policy command.

## Command routing

Use the narrowest workflow that matches the request:

| User intent | Command | Notes |
| --- | --- | --- |
| Inspect local and open-PR state | `jj-ci status` | Read-only, but includes GitHub PR state. |
| Align an empty working copy with trunk | `jj-ci sync` | Fetches `origin`, advances `main`, and rebases onto `main@origin`. |
| Check readiness and run repository gates | `jj-ci validate` | Describes an undescribed change, runs `jj fix -s @`, then Prek on the JJ file list. |
| Publish the current change | `jj-ci publish` | Validates, creates or updates a stable bookmark and PR, and keeps editing the same change. |
| Update a topic from trunk | `jj-ci rebase` | Checkpoints, fetches, and rebases the same change. |
| Finish a merged topic | `jj-ci finish` | Verifies the current head was merged and leaves an empty workspace on main before archiving. |
| Publish and request auto-merge | `jj-ci publish --auto-merge` | Requires an explicit user request because it changes GitHub PR state. |
| Inspect declared GitHub policy | `jj-ci github reconcile` | Dry run by default. |
| Apply GitHub policy changes | `jj-ci github reconcile --apply` | Requires an explicit user request. |
| Submit a validated PR stack | `jj-ci stack-merge <stack-or-pr>` | Requires an explicit user request and an already-ready stack. |

## Safety rules

- `jj-ci sync` rejects nonempty changes and active Codex task ownership.
  Use `jj-ci rebase` to update an active topic without creating another change.
- Do not publish an empty or conflicted change. `jj-ci publish` enforces this,
  but inspect the state first so the user understands the blocker.
- Do not add `--auto-merge`, use `github reconcile --apply`, or run
  `stack-merge` unless the user explicitly asks for that external mutation.
- Do not activate NixOS configuration as part of validation. Home-only changes
  may be activated with `home-activate` when that is part of the requested
  implementation; it runs without `sudo`. For NixOS changes, keep the
  privileged activation separate and obtain authorization through the standard
  clickable follow-up defined in the repository's `AGENTS.md`.
- Prefer `jj-ci` over manually reproducing its fetch, bookmark, push, PR, and
  validation sequence. Use raw JJ commands only for focused inspection or when
  the user explicitly asks for a different history operation.

## Publication expectations

Keep one topic and one stable JJ change ID per task, in a dedicated workspace.
`jj-ci publish` uses `jj-<full-change-id>` as its bookmark, preserving its identity
through title changes and repeated edits. It does not start a follow-up change.
Report the PR URL and existing change ID. Existing PRs published under old
slug bookmarks need deliberate migration; do not create a duplicate PR for them.

Enable auto-merge only at requested topic closeout. Once GitHub has merged the
current head, `jj-ci finish` verifies that merge is on main and prepares a clean
workspace. Then archive through the app tool. Leave the task open if delivery
is pending or there are later local edits. SessionEnd also fires on exit and
idle timeout, so it must never trigger publication or merging. A direct archive
button click does not run this workflow.

For stacked work, inspect the stack before acting. Use the repository's JJ and
GitHub stack workflow; do not bypass it with direct branch or merge commands.
