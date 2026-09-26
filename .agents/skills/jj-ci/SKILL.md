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
- Before validation or publication, inspect the diff for mixed deliverables.
  Split independent deliverables into separate changes. Choose parent/child
  only when the later change depends on the earlier one to build, test, or
  make sense; choose siblings when both can be reviewed and landed
  independently. `jj split` creates parent/child changes by default, while
  `jj split --parallel` creates siblings. Checkpoint before splitting, assign
  explicit descriptions, and verify the resulting graph with `jj log`.

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
| Decide whether a topic ships alone or stacked | `jj-ci plan` | Read-only apart from a fetch. Trial-merges in-flight topics (open-PR bookmarks and workspace changes) against `main@origin` and each other, then proposes independent PRs or stacks. `--json` for structured output. |
| Update a topic from trunk | `jj-ci rebase` | Checkpoints, fetches, and rebases the same change. |
| Update every published topic that fell behind trunk | `jj-ci refresh` | Requires an explicit user request. Rebases each local bookmark with an open PR onto `main@origin`, pushes only conflict-free stacks, and re-pins armed auto-merge. `--no-push` stops before any remote change. |
| Finish a merged topic | `jj-ci finish` | Verifies the current head was merged and leaves an empty workspace on main before archiving. |
| Capture a review version | `jj-ci review snapshot <label>` | Records the exact base and series tip for a later interdiff. |
| Compare review versions | `jj-ci interdiff <old> <new>` | Runs a commit-by-commit `git range-diff` between named snapshots. |
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
- Do not activate NixOS or Home Manager configuration as part of validation.
  If configuration changes are ready, report the appropriate activation command
  and request approval separately.
- Prefer `jj-ci` over manually reproducing its fetch, bookmark, push, PR, and
  validation sequence. Use raw JJ commands only for focused inspection or when
  the user explicitly asks for a different history operation.

## Publication expectations

Keep one coherent topic in a dedicated workspace. Use one stable JJ change ID
for a single deliverable, or a small stack of stable change IDs when mixed
deliverables were intentionally split. `jj-ci publish` uses a persisted
`jj-<title-slug>-<short-change-id>` bookmark for new topics, preserving the
selected branch through title changes and repeated edits. Existing
full-change-ID bookmarks are adopted unchanged for backward compatibility. It
does not start an unrelated follow-up change.
Report the PR URL and existing change IDs. Existing PRs published under old
slug bookmarks need deliberate migration; do not create duplicate PRs for them.

Enable auto-merge only at requested topic closeout. Once GitHub has merged the
current head, `jj-ci finish` verifies that merge is on main and prepares a clean
workspace. Then archive through the app tool. Leave the task open if delivery
is pending or there are later local edits. SessionEnd also fires on exit and
idle timeout, so it must never trigger publication or merging. A direct archive
button click does not run this workflow.

For stacked work, inspect the stack before acting. Use the repository's JJ and
GitHub stack workflow; do not bypass it with direct branch or merge commands.


## Continuous integration and conflict handling

The canonical checkout tracks `main`; active work belongs in a dedicated JJ
workspace created from `main@origin`. Rebase after `main` advances, before
each review update, and before queue entry. `jj-ci publish` and
`jj-ci stack-merge` perform a final rebase and validation before updating
GitHub, so stale heads cannot enter the queue.

Use `jj-ci conflicts` after a rebase to list conflicted revisions and files.
A conflicted rebase has already rewritten the topic: resolve revisions from
oldest to newest, then verify with `jj-ci conflicts` before validating.
Never run an unattended auto-rebase or automatic conflict resolver.

`jj-ci refresh` is the attended catch-up path for published topics that are
not checked out anywhere, typically after strict required checks leave an
auto-merge PR behind `main`. It skips any topic whose stack or descendants hold
a workspace's working copy; run `jj-ci rebase` in that workspace instead. It
uses JJ's recorded conflicts as the push gate: a conflicted topic stays
rebased locally, its PR is untouched, and the command lists each conflicted
revision and file. Resolve oldest first with `jj new CHANGE_ID`, edit the files
or run `jj resolve`, `jj squash`, and then run `jj-ci refresh` again to push.
Never resolve those conflicts automatically.

Run `jj-ci plan` before publishing when other topics are in flight. It builds
headless trial merges (`jj new --no-edit`) and abandons them, so no working
copy moves. Topics that conflict with nothing publish as independent PRs.
Topics that conflict with each other are ordered with open PRs first, then by
age: the later topic is rebased onto the earlier one, its conflicts are
resolved locally, and it is published as a stacked PR whose base is the
earlier topic's branch. Chains longer than three hold the remainder locally
until a layer lands. Topics that conflict with `main` must be resolved with
`jj-ci rebase` first. Never rebase an open PR onto unpublished work, and never
rewrite another session's topic to build a stack; stack new work on top of it.
Enable auto-merge on a stacked PR only after its base is `main`.
The plan detects textual conflicts only; strict required checks remain the
gate for semantic breakage.

Herdr and Paseo may supervise one existing JJ workspace per topic, monitor
trunk, PR freshness, checks, and queue state, and notify the owner when
integration is needed. They must not take ownership of the workspace or
silently rebase, resolve conflicts, publish, enter a queue, or advance a
stack.

Prefer one ordinary PR per coherent topic. Use stacked PRs only for
independently reviewable changes with real dependency order; keep each child
based on its immediate parent and rebase the remaining stack after every parent
lands. Keep unrelated work in separate sibling changes.
