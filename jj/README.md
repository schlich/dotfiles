# JJ project workflow

`JjCi.tla` is a bounded TLA+ state-machine model of topic rebase, conflict
resolution, validation, publication, auto-merge, delivery, and workspace
finish. `JjCi.cfg` supplies a small TLC state space for checking its safety
invariants. Validation records the exact topic head it checked, and publication
must capture that same head. The model intentionally abstracts command failures
and detailed multi-revision stack topology; the operational rules below remain
authoritative.

Codex shell commands and OpenCode server shell execution receive a no-op
`JJ_EDITOR` and an unpaginated `PAGER`. This keeps agent-run JJ commands from
blocking on an editor or pager while leaving the normal interactive shell
unchanged. Explicitly supply messages, filesets, revsets, and any available
non-interactive flags for commands that prompt for other input.

One task owns one topic, one JJ workspace, and one stable change ID. A topic
may contain a series of logically separate JJ changes. Review fixes should be
absorbed into the appropriate change instead of appended as "address review"
commits.

```nu
jj-ci start topic-name        # Create the topic's workspace from main@origin.
jj-ci status
jj-ci rebase                  # Fetch trunk and rebase the whole topic stack.
jj-ci conflicts               # Show conflicted revisions and files after a rebase.
jj-ci validate                # Run the repository gates when requested.
jj-ci review snapshot v1      # Capture the current series for interdiff review.
jj-ci publish                 # Create/update the same PR and bookmark.
# After editing or absorbing review fixes:
jj-ci review snapshot v2
jj-ci interdiff v1 v2
# At topic closeout:
jj-ci publish --auto-merge
jj-ci finish --wait           # Wait for the merge, then finish and remove the workspace.
# To drop an unpublished or closed topic instead:
jj-ci abandon
# Occasionally, from any workspace:
jj-ci prune                   # List leaked workspaces; --apply removes them.
jj-ci preview --shell         # Try trunk plus open user-facing PRs, unactivated.
```

## Patch-series review

The intended review model is an evolving patch series:

```
v1: A1 -> B1 -> C1
v2: A2 -> B2 -> C2
```

Each commit should have one logical purpose and should be readable as part of
the series. Use `jj edit` to select an earlier change, or use `jj absorb` to
move an unambiguous fix into the change that introduced the affected lines.
Descendants are rewritten as needed while retaining their change identities.

Before each review update, run `jj-ci review snapshot <label>`. Snapshots are
stored in the workspace's `.jj/jj-ci-review-versions.json`; this is local
review metadata and is not committed. `jj-ci interdiff old new` runs
`git range-diff` over the exact base and tip recorded for both snapshots.
That preserves the pairwise, commit-by-commit review signal described by the
interdiff model.

The PR bookmark identifies the topic, not an individual patch. Publishing moves
the same bookmark to the current series tip. GitHub sees the updated PR branch;
the local range-diff command supplies the true interdiff between review rounds.

## Topic lifecycle

`jj-ci sync` is for an empty workspace with no active topic. It refuses to move
an owned workspace. Use `jj-ci rebase` during an active topic; it fetches trunk
and rebases the whole series in place.

`jj-ci publish` validates, pushes the stable `jj-<full-change-id>` bookmark to
both the `origin` (GitHub) and `tangled` remotes, and creates or updates the
matching PR. It does not create a follow-up change. After GitHub delivery,
`jj-ci finish` also mirrors `main` to Tangled.
Further edits to the series therefore update the same review topic.

A process keeps the `jj-ci` on its PATH from launch, so a long-lived agent
session can outlive the script it started with. The wrapper records the hash of
the `jj/ci.nu` it was built from, and `publish` and `stack-merge` refuse to run
unless that matches this workspace's copy or `main@origin`'s. Rerun a refused
command as `direnv exec . jj-ci ...`, or activate the configuration and start a
new session.

To publish a multi-change topic to Tangled as stacked PRs, run:

```nu
jj-ci tangled stack-publish
```

This rebases the complete topic onto `main@origin`, runs the repository
validation gate, and pushes each revision as a stable
`stack/<series>/<change-id>` branch to Tangled, oldest layer first. In Tangled,
choose `Submit as stacked PRs` for the pushed branches. Later edits retain
their JJ change IDs, so Tangled can associate rewritten commits with the
corresponding stack layer and review round.

`jj-ci finish` checks that GitHub merged the exact current head and that the
merge is on `main@origin`. It then deletes the topic bookmark locally and on
both remotes, advances local main, and releases the workspace. A workspace
that `jj-ci start` created is forgotten and its directory deleted; continue
from the default checkout. `--keep`, or any other workspace, is left on an
empty change on main with its Codex ownership finished. Archive the task only
after it succeeds.

`jj-ci finish --wait` first polls the PR every 30 seconds until GitHub merges
the current head (default timeout `--timeout 2hr`). It never rebases or
pushes, so it gives up with an explanation whenever the PR cannot merge
unattended: it was closed, its head differs from the local revision, it is
still stacked on another PR, auto-merge is off, strict checks need a newer
base, or a check failed.

`jj-ci abandon` drops a topic that will not land. It refuses while the
topic's PR is open, records a checkpoint, deletes the topic bookmark, abandons
the revisions above `main@origin`, and releases the workspace like `finish`.
`jj op restore` with the printed operation recovers it.

Workspace lifetime follows ownership rather than garbage collection:
`jj-ci start` creates a workspace for exactly one topic, and `finish` or
`abandon` frees it. `jj-ci prune` is the backstop for owners that never
released theirs, such as a crashed task or a workspace created by hand. It
lists workspaces that are missing, or that no active task owns and whose
revisions above `main@origin` are all delivered: nothing but an empty,
undescribed working copy remains, or GitHub merged the topic's exact head,
which catches squash merges. It also lists JJ checkpoints older than
`--keep-days` (14). A stale working copy is reported without being touched;
`--apply` first runs `jj workspace update-stale` there and decides again. `--apply` then forgets the listed
workspaces, deletes their directories, and deletes the old checkpoints. Prune
always keeps the default and current workspaces, Git and Codex worktrees, and
anything with undelivered changes.

### Rebasing with conflicts

`jj-ci rebase` creates a JJ operation checkpoint, fetches `origin`, and rebases
the complete topic stack onto `main@origin`. If the rebase conflicts, it does
not attempt another rebase: it prints every conflicted revision and its files,
then exits non-zero so publication cannot accidentally proceed.

Resolve the revisions from oldest to newest. For a conflicted revision that is
not the working copy, select it with `jj edit CHANGE_ID`; resolve its files by
editing the conflict markers or using `jj resolve`; then return to the original
topic tip with `jj edit TOPIC_TIP` (record the tip before selecting a revision).
Run `jj-ci conflicts` between revisions. Once it reports no conflicts, run
`jj-ci validate` before publishing.

The rebase itself has already completed when the conflict report appears. Do
not run `jj-ci rebase` again while conflicts remain; doing so would attempt to
move an already-rebased topic a second time. If a resolution goes wrong, use
the printed checkpoint with `jj op restore` and retry from the pre-rebase state.

## Continuous integration and conflict avoidance

The canonical checkout tracks `main`; active work happens in dedicated JJ
workspaces. The local webhook may advance the canonical checkout after a
successful `main` workflow, but it never rewrites an owned topic workspace.
Each topic therefore has an isolated working copy and must integrate trunk
changes into itself.

The integration points are deliberately automatic:

- `jj-ci rebase` fetches `origin` and rebases the complete topic stack onto
  `main@origin`.
- `jj-ci publish` rebases before validation, pushing, or requesting auto-merge.
- `jj-ci stack-merge` performs the same final rebase and validation before
  submitting a stack.

`main` requires its checks but not an up-to-date branch. A conflict-free PR
therefore merges as soon as it is green, however far `main` has moved since.
The PR build already tests the merge with `main` as of the run, and every push
to `main` runs the full suite as the backstop for two PRs that break only in
combination. Strict freshness would instead force a rebase and a full rebuild
of every open PR after each merge.

What still needs rewriting after `main` moves is handled by `jj-ci refresh`,
which the local webhook runs after every successful `main` build:

- a stacked PR whose parent branch moved is restacked onto it;
- a PR GitHub retargeted to `main` after its parent merged (it carries the
  `jj-ci:stacked` label) is restacked onto `main`, dropping the parent's
  squash-merged commits;
- a PR GitHub reports as conflicting is rebased so the conflict is recorded
  locally for resolution.

A topic checked out in a workspace is snapshotted and rebased from that
workspace, so its files move with it; a trial merge must predict no conflict
first, or the topic is left untouched for its owner. Only conflict-free results
are pushed. `jj-ci refresh --all` also rebases PRs that are merely behind.
Keep topics short-lived and changes small enough to rebase without large
manual resolutions.

### Previewing in-flight work

`jj-ci preview` answers what the machine would look like once the open
user-facing PRs land. It merges `main@origin` with the head of every open
`impact:behavior` or `impact:breaking` PR (or the PR numbers given; `--all`
adds refactors) in a temporary workspace, then builds that merge's Home
Manager generation to `$XDG_STATE_HOME/jj-ci/preview-home`. The merge is
abandoned afterwards and nothing is pushed, rewritten, or activated.

It reports package changes and changed configuration files against trunk's
generation, so only what the PRs change is listed; `--active` compares against
the active generation instead. `--shell` opens Nushell with the preview's programs first
on `PATH`; `--config` also points `XDG_CONFIG_HOME` at the preview's
read-only configuration, so applications that write their own configuration
may refuse to start. System-level (NixOS) changes are not previewed. If the
selected PRs conflict with each other, the preview stops and lists the files;
preview a subset or use `jj-ci plan` to decide how to stack them.

### Herdr and Paseo coordination

Herdr or Paseo may supervise the terminals and agents used for this workflow,
but they do not replace JJ workspace ownership. Create the JJ workspace from
`main@origin` first, then attach one Herdr or Paseo coordination lane to that
directory. Keep the mapping one coordinator : one JJ workspace : one topic.

A supervisor may monitor `main@origin`, PR freshness, checks, and queue state,
and notify the owner when integration is needed. Conflict resolution,
publication, queue entry, and stack advancement remain explicit operations in
the owning workspace. The conflict-free restack by `jj-ci refresh` is the only
unattended rebase; a supervisor does not rebase on its own.

## Impact classes and releases

Every JJ change ends its description with an `Impact:` trailer that states
what it does to the built machines:

- `refactor`: every NixOS closure is unchanged, as for refactors, docs, CI,
  and repository tooling. CI proves that each host's toplevel derivation
  matches the merge base. No release.
- `behavior`: a user-facing change to a host. Landing it cuts a CalVer release.
- `breaking`: a user-facing change that needs manual steps when activating.
  The description body must list the steps, and the release notes carry them.

```text
Launch terminals through their configured Home Manager packages

Impact: refactor
```

`jj-ci publish` refuses a topic with a missing trailer, or one that mixes a
refactor with a user-facing change: squash merging would ship the refactor
inside a release and lose its closure-neutral guarantee. Split the refactor
into its own topic, or make it the parent layer of a stack when the change
depends on it. Breaking and behavior revisions may share a topic; the PR takes
the stronger class. Publication generates the PR body from the descriptions,
applies the `impact:<class>` label, and ends the body with the trailer.

GitHub squash commits use the PR title and body, so the trailer reaches `main`.
On each push to `main`, the `release` workflow runs `jj-ci release`, which tags
every behavior or breaking commit since the newest release as `YYYY.MM.DD.N`
(UTC commit date, numbered within the day) and publishes a GitHub release with
its notes. Refactors never cut a version, so the list of releases is the list
of changes that alter a machine. `jj-ci version` prints the newest release in
the current revision.

A NixOS generation cannot carry the tag: the tag is created after merge, and
local `path:` builds have no Git revision. Compare a generation with a release
by the checkout it was built from.

## Merge strategy

The permanent default is one PR per ordinary JJ topic. The publication
bookmark is a stable `jj-<change-id>` branch, and GitHub auto-merges it with
**squash** after all required checks pass. Squash keeps `main` linear and
turns a mutable review series into one atomic configuration change. Branches
from older sessions may retain their descriptive names, but new topics should
use the `jj-` prefix.

Use a stacked PR only when every layer is independently reviewable and the
layers must land in dependency order. Ordinary one-PR topics are preferred
because they minimize the number of moving bases and queue interactions. For
GitHub, name stack branches `stack/<series>/<layer>`, link the stack with
`gh stack link`, and inspect it with `gh stack view --json`. Submit the
complete GitHub stack with:

```nu
jj-ci stack-merge STACK_OR_PR
```

That wrapper uses `gh stack merge --yes --squash`, so each layer remains a
linear, atomic change without merge commits. A stack must remain topological:
each layer is based on the immediately preceding layer, parent layers land
before children, and the remaining layers are rebased onto the new `main` after
each parent lands. Never submit a child based on an outdated parent or queue
independent sibling PRs as if they were a stack.

For Tangled, use `jj-ci tangled stack-publish`; it publishes the same
topological series as `stack/<series>/<change-id>` branches, after which
Tangled's `Submit as stacked PRs` action creates the linked PR stack.

Ordinary topics are queued for auto-merge only after the final automatic rebase
and only when the publisher explicitly passes `--auto-merge`; stack submission
remains the explicit ordering decision.

Impact shapes ordering. When topics conflict, `jj-ci plan` still places open
PRs before unpublished work, but within each group it bases the stack on the
refactor, so the user-facing layer above it stays a small behavior diff and its
release notes describe only that behavior. A refactor that must stack on an
already-published user-facing PR is reported with a note. The order uses only
keys that rewrites leave alone (publication, impact, PR number, the topic's
oldest author time, and change ID), so concurrent tasks agree on the base.
`jj-ci publish` stacks only on a topic that already has a PR; when the planned
parent is unpublished it opens an independent PR instead of waiting, and
whichever topic lands second resolves the conflict when it rebases. Refactors can land
at any time without activation; land each user-facing PR on its own so every
release maps to exactly one reviewed change. Use a rebase merge only when preserving
the individual patch-series commits on `main` is more valuable than a single
atomic commit.

Merge commits are not part of the repository policy: `main` has required
linear history and GitHub allows only squash or rebase merges.

## Desktop

Press **Mod+2** to open or focus jjui on Niri's `vcs` workspace. From a
terminal, `jj-dashboard /path/to/workspace` opens a dashboard for that
workspace. The Codex **Open in -> JJ dashboard** handler accepts a project
directory or file.

Git and lazygit are disabled as Home Manager programs. JJ retains an explicit
Git executable dependency, and gh gets its own internal Git PATH for repository
discovery. GitHub credential-helper configuration remains available to JJ.
Keep this repository colocated for existing Git-based tools such as Prek and
GitHub discovery.

## Concurrent tasks

Create a separate JJ workspace before opening a new local project task:

```nu
jj-ci start topic-name
```

It creates `.jj-workspaces/topic-name` at `main@origin` and refuses a name
that is already in use. `jj-ci finish` or `jj-ci abandon` removes it.

Use that directory as a local Codex project. The session hook starts an
independent topic at `main@origin`, records ownership in
`.jj/codex-session.json`, and guards prompts and tool calls against change-ID
drift. It never automatically switches another task's working copy.

## Git worktrees and the devshell

This repository's default devshell provides the Nushell, JJ, GitHub CLI,
Prek, and `jj-ci` for the workflow. From any checkout, enter it with:

```nu
nix develop path:.
```

Codex may create ordinary Git worktrees rather than JJ workspaces. Inspect
every checkout against the latest fetched trunk with:

```nu
jj-ci worktree-status
```

`worktree-status` reports every Git worktree as `current`, `ahead`, `behind`,
or `diverged`, along with its branch, cleanliness, and whether it is a JJ or
ordinary Git worktree. The merge webhook updates only the dedicated JJ trunk
workspace. When Codex creates an ordinary linked Git worktree, the session hook
initializes a non-colocated JJ workspace there, using the shared Git repository
as its backend, and starts the task's topic from `main@origin`. Active or dirty
worktrees remain owned by their tasks; ordinary Git worktrees created outside
Codex remain visible as ordinary Git worktrees.

## Nix and GitHub

Git-backed flakes can omit untracked files. The activation wrappers use
`path:/home/schlich/dotfiles`, so new files are included without Git staging.
Use explicit path references for other local commands too:

```nu
nix develop path:.
nix run path:.#jj -- git fetch --remote origin
nix run path:.#jj -- git push --remote origin --bookmark BOOKMARK
nix run path:.#jjui
```

Use JJ for change, bookmark, rebase, and push operations. GitHub owns required
checks, merge queues, and delivery to `main`. Keep plaintext secrets and
bulky generated output outside the selected flake source root.
