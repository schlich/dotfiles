---
name: jj-ci
description: Use the repository's jj-ci workflow to inspect, synchronize, validate, publish, and land JJ changes. Apply when jj-ci is available; do not use it as a generic Jujutsu tutorial.
---

# jj-ci workflow

Use this skill when the repository provides the `jj-ci` command. It is the
repository's policy layer around Jujutsu, Prek, Tangled, and the trunk
workflow. Tangled hosts `main` and every topic branch; `jj-ci land` is the only
path to `main`.

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
- End every description with an `Impact:` trailer: `refactor` when no NixOS
  closure changes (refactors, docs, CI, tooling), `behavior` for a user-facing
  change, or `breaking` for a user-facing change whose description body lists
  the manual activation steps. Never combine a refactor with a user-facing
  change in one topic; split the refactor into its own topic, or its own parent
  layer when the change depends on it.

## JJ MCP integration

When the `jj` MCP server is available, use its read-only status, log, diff,
show, file, bookmark, and operation-log tools for repository inspection. Read
the server's workflow guidance before a non-trivial JJ operation.

Use `jj-ci` for repository policy workflows even when the MCP server exposes
equivalent low-level commands:

- `jj-ci validate` for formatting and Prek gates;
- `jj-ci publish` for the stable topic bookmark and its push to Tangled while
  retaining the same working-copy change;
- `jj-ci land` for delivery to `main`;
- `jj-ci rebase` for updating that topic in place;
- `jj-ci start` to create a topic's workspace, and `jj-ci finish` or
  `jj-ci abandon` to release it.

Do not use low-level MCP mutation tools such as restore, abandon, direct push,
or rebase unless the user explicitly requests that specific operation and the
repository workflow does not provide the appropriate policy command. Never
push `main` directly.

## Command routing

Use the narrowest workflow that matches the request:

| User intent | Command | Notes |
| --- | --- | --- |
| Inspect local and published state | `jj-ci status` | Read-only. Lists each published topic with its stack parent, spindle pipeline state, and open Tangled pull request. |
| Align an empty working copy with trunk | `jj-ci sync` | Fetches `tangled`, advances `main`, and rebases onto `main@tangled`. |
| Check readiness and run repository gates | `jj-ci validate` | Describes an undescribed change, runs `jj fix -s @`, then Prek on the JJ file list. |
| Publish the current change | `jj-ci publish` | Refuses unclassified or mixed-impact topics, then rebases, validates, and pushes a stable `jj-*` bookmark to Tangled, which starts its pipeline. Keeps editing the same change. A topic built on another published topic, or reported by `jj-ci plan` as conflicting with one, is restacked onto that topic's branch; conflicts must be resolved locally first. Open a Tangled pull request from the branch for review. |
| Land a topic on `main` | `jj-ci land` | Requires an explicit user request. Publishes, proves a refactor is closure-neutral, builds every flake check at the exact head on this machine (skipping cached outputs), fast-forwards `main` to it on Tangled and the GitHub mirror, and tags releases. `--gate spindle` or `--gate github` waits for that CI on the exact head instead (`--timeout`, default 2hr). If `main` moves while the gate runs, it rebases, republishes, and gates the new head again (`--attempts`, default 5) instead of landing. Refuses a stacked topic until its parent lands. `jj-ci publish --land` does the same. Never merge a GitHub pull request; squash and rebase merges rewrite the tested commit. |
| Decide whether a topic ships alone or stacked | `jj-ci plan` | Read-only apart from a fetch. Trial-merges in-flight topics (published `jj-*` bookmarks and workspace changes) against `main@tangled` and each other, then proposes independent topics or stacks. `--json` for structured output. |
| Update a topic from trunk | `jj-ci rebase` | Checkpoints, fetches, and rebases the same change. |
| Restack published topics after trunk moves | `jj-ci refresh` | Run it by hand only on request. Restacks stacked topics onto their parent's bookmark and conflicting topics onto `main@tangled`, parents first. Checked-out topics are rebased from their own workspace only when a trial merge is clean. Pushes only conflict-free stacks. `--all` also rebases topics that are merely behind; `--no-push` stops before any remote change. |
| Start a topic | `jj-ci start <name>` | Creates `.jj-workspaces/<name>` at `main@tangled` for exactly one topic; refuses a name already in use. |
| Finish a landed topic | `jj-ci finish` | Verifies the current revision is on `main@tangled`, deletes the topic bookmark locally and on Tangled, and removes a workspace that `jj-ci start` created (`--keep`, or any other workspace, stays on an empty change on main) before archiving. An empty working copy passes when its published branch, if any, landed. |
| Drop a topic that will not land | `jj-ci abandon` | Refuses while a Tangled pull request from its branch is open. Checkpoints, deletes the topic bookmark, abandons the revisions above `main@tangled`, and releases the workspace like `finish`. Requires an explicit user request. |
| Reclaim leaked workspaces | `jj-ci prune` | Dry run by default. Lists missing workspaces and unowned ones whose work is delivered (only an empty undescribed working copy remains above `main@tangled`), plus checkpoints older than `--keep-days`. Reports stale workspaces untouched. `--apply` updates stale ones, decides again, then forgets and deletes the listed ones, which requires an explicit user request. |
| Capture a review version | `jj-ci review snapshot <label>` | Records the exact base and series tip for a later interdiff. |
| Compare review versions | `jj-ci interdiff <old> <new>` | Runs a commit-by-commit `git range-diff` between named snapshots. |
| Review a series as stacked Tangled pull requests | `jj-ci tangled stack-publish` | Pushes each revision as `stack/<series>/<change-id>`; then choose `Submit as stacked PRs` in Tangled. Review only; `jj-ci land` still delivers. |
| Check a commit range's impact | `jj-ci impact check <base> <head>` | Git and Nix only; for a refactor it proves every host closure matches the merge base. `jj-ci land` runs the same proof. |
| Show the release in the current revision | `jj-ci version` | Read-only. Releases are CalVer tags (`YYYY.MM.DD.N`) that `jj-ci land` cuts for behavior and breaking revisions; `jj-ci release` only catches up after a failed tag push. |

## Safety rules

- `jj-ci sync` rejects nonempty changes and active Codex task ownership.
  Use `jj-ci rebase` to update an active topic without creating another change.
- Do not publish an empty or conflicted change. `jj-ci publish` enforces this,
  but inspect the state first so the user understands the blocker.
- Do not run `jj-ci land` or `jj-ci publish --land` unless the user explicitly
  asks to deliver the topic.
- Do not activate NixOS or Home Manager configuration as part of validation.
  If configuration changes are ready, report the appropriate activation command
  and request approval separately.
- Prefer `jj-ci` over manually reproducing its fetch, bookmark, push, landing,
  and validation sequence. Use raw JJ commands only for focused inspection or
  when the user explicitly asks for a different history operation.

## Publication expectations

Keep one coherent topic in a dedicated workspace. Use one stable JJ change ID
for a single deliverable, or a small stack of stable change IDs when mixed
deliverables were intentionally split. `jj-ci publish` uses a persisted
`jj-<title-slug>-<short-change-id>` bookmark for new topics, preserving the
selected branch through title changes and repeated edits. Only `jj-*`
bookmarks count as published topics and trigger the spindle. It does not start
an unrelated follow-up change. Report the branch and existing change IDs.

Land only at requested topic closeout. Once `jj-ci land` has fast-forwarded
`main`, `jj-ci finish` verifies the landing and prepares a clean workspace.
Then archive through the app tool. Leave the task open if the pipeline failed,
landing is pending, or there are later local edits. SessionEnd also fires on
exit and idle timeout, so it must never trigger publication or landing. A
direct archive button click does not run this workflow.

For stacked work, inspect the stack before acting. Land parents first; do not
bypass the workflow with direct branch pushes or merges.

## Continuous integration and conflict handling

The canonical checkout tracks `main`; active work belongs in a dedicated JJ
workspace created from `main@tangled`. Rebase before each review update and
when the topic conflicts with `main`; a topic that merely fell behind needs
nothing until it lands. `jj-ci publish` and `jj-ci land` perform a final rebase
and validation before pushing, and `jj-ci land` lands only the exact commit the
spindle passed, so a stale head cannot reach `main`.

Use `jj-ci conflicts` after a rebase to list conflicted revisions and files.
A conflicted rebase has already rewritten the topic: resolve revisions from
oldest to newest, then verify with `jj-ci conflicts` before validating.
Never run an automatic conflict resolver. `jj-ci refresh` is the only
unattended rebase.

`jj-ci refresh` rewrites only topics that need it: a stacked topic whose parent
moved, and a topic that conflicts with `main`. `--all` also rebases topics that
are merely behind. A topic checked out in a workspace is snapshotted and then
rebased from that workspace, so its files move with it. If a trial merge
predicts a conflict, the topic is left untouched for its owner. A topic that is
not checked out uses JJ's recorded conflicts as the push gate: it stays rebased
locally, its branch is untouched, and the command lists each conflicted
revision and file. Resolve oldest first with `jj new CHANGE_ID`, edit the files
or run `jj resolve`, `jj squash`, and then run `jj-ci refresh` again to push.
Never resolve those conflicts automatically.

Run `jj-ci plan` before publishing when other topics are in flight. It builds
headless trial merges (`jj new --no-edit`) and abandons them, so no working
copy moves. Topics that conflict with nothing publish as independent topics.
Topics that conflict with each other are ordered with published topics first,
then refactors before user-facing changes, then by age: the later topic is
rebased onto the earlier one, its conflicts are resolved locally, and it is
published stacked on the earlier topic's branch. Age is the topic's oldest
author time, then its change ID, so rewrites never reorder topics. If the
earlier topic is not published yet, the later one publishes independently
instead of waiting, and whichever lands second resolves the conflict. Chains
longer than three hold the remainder locally until a layer lands. Topics that
conflict with `main` must be resolved with `jj-ci rebase` first. Never rebase a
published topic onto unpublished work, and never rewrite another session's
topic to build a stack; stack new work on top of it. Landing fast-forwards
`main` to the parent's exact commits, so a stacked child is already on `main`
once its parent lands. The plan detects textual conflicts only; the spindle run
on each rebased head is the backstop for semantic breakage between topics.

Herdr and Paseo may supervise one existing JJ workspace per topic, monitor
trunk, topic freshness, and pipelines, and notify the owner when integration
is needed. They must not take ownership of the workspace or silently rebase,
resolve conflicts, publish, land, or advance a stack.

Prefer one ordinary branch per coherent topic. Use stacks only for
independently reviewable changes with real dependency order; keep each child
based on its immediate parent. Keep unrelated work in separate sibling
changes.
