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
jj-ci start topic-name        # Create the topic's workspace from main@tangled.
jj-ci status
jj-ci rebase                  # Fetch trunk and rebase the whole topic stack.
jj-ci conflicts               # Show conflicted revisions and files after a rebase.
jj-ci validate                # Run the repository gates when requested.
jj-ci review snapshot v1      # Capture the current series for interdiff review.
jj-ci publish                 # Push the same topic branch to Tangled.
# After editing or absorbing review fixes:
jj-ci review snapshot v2
jj-ci interdiff v1 v2
# At topic closeout:
jj-ci land                    # Build the flake checks locally, then fast-forward main.
jj-ci land --gate spindle     # Gate on the spindle instead (or --gate github).
jj-ci finish                  # Verify the landing and remove the workspace.
# To drop an unpublished or closed topic instead:
jj-ci abandon
# Occasionally, from any workspace:
jj-ci prune                   # List leaked workspaces; --apply removes them.
jj-ci preview --shell         # Try trunk plus published user-facing topics, unactivated.
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

The topic bookmark identifies the topic, not an individual patch. Publishing
moves the same bookmark to the current series tip, and a Tangled pull request
opened from that branch records each push as a new review round. The local
range-diff command supplies the true interdiff between review rounds.

## Topic lifecycle

`jj-ci sync` is for an empty workspace with no active topic. It refuses to move
an owned workspace. Use `jj-ci rebase` during an active topic; it fetches trunk
and rebases the whole series in place.

Tangled is the trunk remote: `main@tangled` is the base of every topic.
GitHub (`origin`) is a mirror of `main` that `jj-ci land` fast-forwards after
each landing, and an optional landing gate; `jj-ci publish` never pushes there.
`jj-ci publish` rebases,
validates, and pushes the stable `jj-<slug>-<change-id>` bookmark to Tangled.
It does not create a follow-up change, so further edits to the series update
the same branch. Open a Tangled pull request from that branch when the topic
needs review; `jj-ci` finds it by branch through Tangled's public index and
needs no credentials beyond the SSH key used to push.

`jj-ci land` is the only way a change reaches `main`. It publishes the topic,
which rebases it onto `main@tangled`; for a declared refactor, it proves that
every NixOS closure matches that base. It then passes that exact commit
through the landing gate, fast-forwards `main` to it, and tags any release.
`main` therefore holds only commits that were tested as they are, and history
stays linear without squashing. The push of `main` carries JJ's lease on the
fetched `main@tangled`, so if another topic landed while the gate ran, the
push fails and `jj-ci land` starts again from the new trunk. A stacked
topic lands after its parent. `jj-ci publish --land` publishes and lands in one
step.

A process keeps the `jj-ci` on its PATH from launch, so a long-lived agent
session can outlive the script it started with. The wrapper records the hash of
the `jj/ci.nu` it was built from, and `publish` and `land` refuse to run unless
that matches this workspace's copy or `main@tangled`'s. Rerun a refused command
as `direnv exec . jj-ci ...`, or activate the configuration and start a new
session.

To publish a multi-change topic to Tangled as stacked PRs, run:

```nu
jj-ci tangled stack-publish
```

This rebases the complete topic onto `main@tangled`, runs the repository
validation gate, and pushes each revision as a stable
`stack/<series>/<change-id>` branch to Tangled, oldest layer first. In Tangled,
choose `Submit as stacked PRs` for the pushed branches. Later edits retain
their JJ change IDs, so Tangled can associate rewritten commits with the
corresponding stack layer and review round.

The default gate, `--gate local`, exports the exact commit's tree with
`git archive` and builds its `checks.x86_64-linux` on this machine with the
same `nix-fast-build --skip-cached` command the spindle workflow runs,
streaming the build log. Anything already in the local store or a binary
cache is skipped, so once `main`'s systems have been built, a topic that
leaves them unchanged (every refactor, for instance) builds only the cheap
checks. The first landing after a large input update pays for the full
system builds. Nix's configured remote builders apply as usual.

`jj-ci land --gate spindle` gates on the repository's spindle instead. It
polls every 30 seconds (default timeout `--timeout 2hr`) and stops at the
first failed, timed-out, or cancelled workflow without landing anything.

`jj-ci land --gate github` gates on GitHub Actions. It pushes the topic branch to `origin`, where
`nix-ci.yml` runs on every `jj-*` push, waits for the `impact classification`
and `nix flake checks` runs on the exact head, and then fast-forwards `main`
on Tangled and GitHub exactly as a spindle-gated landing does. Never merge a
GitHub pull request instead: GitHub's squash and rebase merges rewrite
commits, so `main` would hold a commit no check ran on, change IDs and
per-revision trailers would be lost, and `finish` and `prune` could no longer
tell that the topic landed. The GitHub repository therefore allows only
merge commits, which its linear-history rule rejects, so its merge button
cannot land anything; its `main` rule accepts only fast-forward pushes.

`jj-ci finish` checks that the current revision is on `main@tangled`. It then
deletes the topic bookmark locally and on Tangled, advances local main, and
releases the workspace. A workspace that `jj-ci start` created is forgotten
and its directory deleted; continue from the default checkout. `--keep`, or
any other workspace, is left on an empty change on main with its Codex
ownership finished. Archive the task only after it succeeds.

`jj-ci abandon` drops a topic that will not land. It refuses while a Tangled
pull request from the topic's branch is open, records a checkpoint, deletes
the topic bookmark, abandons the revisions above `main@tangled`, and releases
the workspace like `finish`. `jj op restore` with the printed operation
recovers it.

Workspace lifetime follows ownership rather than garbage collection:
`jj-ci start` creates a workspace for exactly one topic, and `finish` or
`abandon` frees it. `jj-ci prune` is the backstop for owners that never
released theirs, such as a crashed task or a workspace created by hand. It
lists workspaces that are missing, or that no active task owns and whose
revisions above `main@tangled` are all delivered: nothing but an empty,
undescribed working copy remains. Landed work is on `main` itself, so it never
counts as pending. It also lists JJ checkpoints older than
`--keep-days` (14). A stale working copy is reported without being touched;
`--apply` first runs `jj workspace update-stale` there and decides again. `--apply` then forgets the listed
workspaces, deletes their directories, and deletes the old checkpoints. Prune
always keeps the default and current workspaces, Git and Codex worktrees, and
anything with undelivered changes.

### Rebasing with conflicts

`jj-ci rebase` creates a JJ operation checkpoint, fetches `tangled`, and rebases
the complete topic stack onto `main@tangled`. If the rebase conflicts, it does
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

- `jj-ci rebase` fetches `tangled` and rebases the complete topic stack onto
  `main@tangled`.
- `jj-ci publish` rebases before validation and pushing.
- `jj-ci land` performs the same final rebase, so the commit the spindle tests
  is the commit `main` receives.

The spindle runs `.tangled/workflows` on every push of a `jj-*` branch.
Landing requires a fresh, passing run on the rebased head, so two topics that
break only in combination cannot both land: the second is rebased onto the
first and tested again. A topic that merely fell behind `main` needs no
attention until it lands.

What still needs rewriting after `main` moves is handled by `jj-ci refresh`:

- a stacked topic whose parent branch moved is restacked onto it;
- a topic that conflicts with `main` is rebased so the conflict is recorded
  locally for resolution.

A stacked topic whose parent landed is already on `main`, because landing
fast-forwards `main` to the parent's exact commits; it needs no restack.

A topic checked out in a workspace is snapshotted and rebased from that
workspace, so its files move with it; a trial merge must predict no conflict
first, or the topic is left untouched for its owner. Only conflict-free results
are pushed. `jj-ci refresh --all` also rebases topics that are merely behind.
Keep topics short-lived and changes small enough to rebase without large
manual resolutions.

### Previewing in-flight work

`jj-ci preview` answers what the machine would look like once the published
user-facing topics land. It merges `main@tangled` with the head of every
published topic whose revisions are `Impact: behavior` or `Impact: breaking`
(or the topic branches given; `--all` adds refactors) in a temporary
workspace, then builds that merge's Home
Manager generation to `$XDG_STATE_HOME/jj-ci/preview-home`. The merge is
abandoned afterwards and nothing is pushed, rewritten, or activated.

It reports package changes and changed configuration files against trunk's
generation, so only what the topics change is listed; `--active` compares against
the active generation instead. `--shell` opens Nushell with the preview's programs first
on `PATH`; `--config` also points `XDG_CONFIG_HOME` at the preview's
read-only configuration, so applications that write their own configuration
may refuse to start. System-level (NixOS) changes are not previewed. If the
selected topics conflict with each other, the preview stops and lists the files;
preview a subset or use `jj-ci plan` to decide how to stack them.

### Herdr and Paseo coordination

Herdr or Paseo may supervise the terminals and agents used for this workflow,
but they do not replace JJ workspace ownership. Create the JJ workspace from
`main@tangled` first, then attach one Herdr or Paseo coordination lane to that
directory. Keep the mapping one coordinator : one JJ workspace : one topic.

A supervisor may monitor `main@tangled`, topic freshness, and pipelines, and
notify the owner when integration is needed. Conflict resolution, publication,
landing, and stack advancement remain explicit operations in the owning
workspace. The conflict-free restack by `jj-ci refresh` is the only
unattended rebase; a supervisor does not rebase on its own.

## Impact classes and releases

Every JJ change ends its description with an `Impact:` trailer that states
what it does to the built machines:

- `refactor`: every NixOS closure is unchanged, as for refactors, docs, CI,
  and repository tooling. `jj-ci land` proves that each host's toplevel
  derivation matches the base. No release.
- `behavior`: a user-facing change to a host. Landing it cuts a CalVer release.
- `breaking`: a user-facing change that needs manual steps when activating.
  The description body must list the steps, and the release commit carries
  them.

```text
Launch terminals through their configured Home Manager packages

Impact: refactor
```

`jj-ci publish` refuses a topic with a missing trailer, or one that mixes a
refactor with a user-facing change: the topic lands as a unit, so it would
ship the refactor inside a release and lose its closure-neutral guarantee.
Split the refactor into its own topic, or make it the parent layer of a stack
when the change depends on it. Breaking and behavior revisions may share a
topic; the topic takes the stronger class.

Landing keeps every revision, so each commit on `main` carries its own
trailer. After fast-forwarding `main`, `jj-ci land` tags every behavior or
breaking revision it landed as `YYYY.MM.DD.N` (UTC commit date, numbered
within the day) with `jj tag set` and pushes the tag to Tangled. The tagged
commit's description is the release note. `jj-ci release` catches up on
anything since the newest release if a tag push failed. Refactors never cut a
version, so the list of releases is the list of changes that alter a machine.
`jj-ci version` prints the newest release in the current revision.

A NixOS generation cannot carry the tag: the tag is created after merge, and
local `path:` builds have no Git revision. Compare a generation with a release
by the checkout it was built from.

## Merge strategy

The permanent default is one branch per ordinary JJ topic. The publication
bookmark is a stable `jj-<slug>-<change-id>` branch, and `jj-ci land`
fast-forwards `main` to it after the spindle passes it. `main` stays linear
without squashing, and every revision keeps its change ID and trailer. Branches
from older sessions may retain their descriptive names, but new topics must use
the `jj-` prefix: the spindle runs only on `jj-*` pushes, and `jj-ci` treats
only `jj-*` bookmarks as published topics.

Use a stack only when every layer is independently reviewable and the layers
must land in dependency order. Ordinary one-branch topics are preferred because
they minimize the number of moving bases. A topic built on another published
topic is stacked on it; the stack lives in the commit graph, with no labels or
base branches to keep in step. Land the parent first; the child is then
already on `main` and lands next. Never land a child based on an outdated
parent.

To review a multi-change topic on Tangled as stacked pull requests, run:

```nu
jj-ci tangled stack-publish
```

It publishes the topological series as `stack/<series>/<change-id>` branches,
after which Tangled's `Submit as stacked PRs` action creates the linked pull
request stack. Pull requests are for review only; `jj-ci land` still delivers
the topic.

Impact shapes ordering. When topics conflict, `jj-ci plan` still places
published topics before unpublished work, but within each group it bases the
stack on the refactor, so the user-facing layer above it stays a small behavior
diff and its release notes describe only that behavior. A refactor that must
stack on an already-published user-facing topic is reported with a note. The
order uses only keys that rewrites leave alone (publication, impact, the
topic's oldest author time, and change ID), so concurrent tasks agree on the
base. `jj-ci publish` stacks only on a topic that is already published; when
the planned parent is unpublished it publishes independently instead of
waiting, and whichever topic lands second resolves the conflict when it
rebases. Refactors can land at any time without activation; land each
user-facing topic on its own so every release maps to exactly one reviewed
change.

Merge commits are not part of the repository policy: `jj-ci land` only ever
fast-forwards `main`. Squash only while authoring, with `jj squash` or
`jj absorb` before publishing, so each published change is already one logical
unit; never squash at delivery.

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

It creates `.jj-workspaces/topic-name` at `main@tangled` and refuses a name
that is already in use. `jj-ci finish` or `jj-ci abandon` removes it.

Use that directory as a local Codex project. The session hook starts an
independent topic at `main@tangled`, records ownership in
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
as its backend, and starts the task's topic from `main@tangled`. Active or dirty
worktrees remain owned by their tasks; ordinary Git worktrees created outside
Codex remain visible as ordinary Git worktrees.

## Nix and Tangled

Git-backed flakes can omit untracked files. The activation wrappers use
`path:/home/schlich/dotfiles`, so new files are included without Git staging.
Use explicit path references for other local commands too:

```nu
nix develop path:.
nix run path:.#jj -- git fetch --remote tangled
nix run path:.#jjui
```

Use JJ for change, bookmark, rebase, and push operations, and `jj-ci land` for
delivery to `main`; nothing else pushes `main`. The spindle owns required
checks. Keep plaintext secrets and bulky generated output outside the selected
flake source root.
