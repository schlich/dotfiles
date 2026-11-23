---
type: architecture
description: In a repository colocated with jj, each luvus task worktree is also a jj workspace on the task branch, and `luvus-jj sync` points that branch at the latest change before the gate.
generated:
  by: claude-code/opus-5.5
  at: 2026-11-23T21:40:00Z
sources:
- id: provider
  resource: tools/luvus-jj.nu
  title: The worktree provider, sync, prune, and register commands
- id: module
  resource: modules/programs/multiplexers/luvus.nix
  title: The provider module, its registration unit, and worktree.provider
- id: tests
  resource: tests/luvus-jj.nu
  title: The provider checked the way luvus checks a worktree
- id: luvus-worktree
  resource: https://github.com/RizRiyz/luvus/blob/main/src/worktree.rs
  title: luvus's worktree provider boundary and its validation
---

# luvus jj workspaces

On 2026-10-20 this repository moved from jj and `ci` to Git and luvus. luvus
made each task a plain Git worktree under `~/.luvus/worktrees/`, which jj could
not see, and in every other jj repository the jj write guard refused the Git
commits a task worker would need. On 2026-11-23 the author asked for luvus and
jj to work together, in every repository colocated with jj, with jj as this
repository's way to make changes.

- luvus lets a module own worktree creation and removal (`[worktree_provider]`,
  chosen by `worktree.provider`). luvus then checks that the returned path is a
  Git worktree of the same repository with HEAD on the task branch. jj 0.47's
  `jj workspace add --colocate` registers a Git worktree for the new workspace,
  so the provider makes the jj workspace, creates the branch as a bookmark on
  its parent, and attaches Git's HEAD to it. A repository without jj gets a
  plain `git worktree add`, as before.
- luvus gates and merges the task's Git branch by name; it never inspects HEAD
  after creation. jj detaches HEAD whenever the working copy moves, and moves no
  bookmark by itself, so `luvus-jj sync` sets the branch to `@-`, finishing a
  described working copy first and refusing undescribed or conflicted changes,
  then reattaches HEAD. Task gates run it first, so a task cannot pass with a
  stale branch.
- A new task starts on `luvus/integration` when it holds `trunk()`, otherwise on
  `trunk()`, as `luvus-task-start` already moved empty Git worktrees.
- Removal snapshots the workspace, forgets it (which also unregisters the Git
  worktree), and deletes the directory; the unfinished change stays in the
  repository. The module declares identity-bound removal, so deletions confirmed
  in the UI come through it too. luvus's own rollback after a failed start still
  removes with Git alone, so creation forgets task workspaces whose directories
  are gone.
- jj's `--when.repositories` scopes match the shared repository, so a workspace
  under `~/.luvus/worktrees/` keeps the repository's scoped settings (`trunk()`,
  `ci.enable`). ci's edit guard refuses only a Git worktree nested inside a jj
  workspace, not a colocated workspace.

Rejected: keeping dotfiles on plain Git worktrees (the author chose jj there
too); nesting a jj workspace inside each Git worktree, as `ci start` does in a
desktop session's worktree (two checkouts per task, and luvus would gate the
outer one); `jj bookmark advance` (it advances every bookmark at the parent,
`main` and `luvus/integration` included); patching luvus to accept a detached
HEAD or a jj change (an upstream change the provider boundary makes
unnecessary).
