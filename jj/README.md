# JJ project workflow

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
jj-ci finish
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

`jj-ci finish` checks that GitHub merged the exact current head and that the
merge is on `main@origin`. It then advances local main, leaves an empty
workspace on main, and releases workspace ownership. Archive the task only
after it succeeds.

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

Rebase after `main` advances, before each review update, and before requesting
queue entry. Keep topics short-lived and changes small enough to rebase without
large manual resolutions. If a queued PR becomes stale or is removed from the
queue, update the topic from `main@origin`, validate the new head, and request
queue entry again; never try to merge a stale head manually.

### Herdr and Paseo coordination

Herdr or Paseo may supervise the terminals and agents used for this workflow,
but they do not replace JJ workspace ownership. Create the JJ workspace from
`main@origin` first, then attach one Herdr or Paseo coordination lane to that
directory. Keep the mapping one coordinator : one JJ workspace : one topic.

A supervisor may monitor `main@origin`, PR freshness, checks, and queue state,
and notify the owner when integration is needed. Rebase, conflict resolution,
publication, queue entry, and stack advancement remain explicit operations in
the owning workspace. Do not run an unattended auto-rebase: rebasing rewrites
the topic and can require revision-by-revision conflict decisions.

## Merge strategy

The permanent default is one PR per ordinary JJ topic. The publication
bookmark is a stable `jj-<change-id>` branch, and GitHub auto-merges it with
**squash** after all required checks pass. Squash keeps `main` linear and
turns a mutable review series into one atomic configuration change. Branches
from older sessions may retain their descriptive names, but new topics should
use the `jj-` prefix.

Use a stacked PR only when every layer is independently reviewable and the
layers must land in dependency order. Ordinary one-PR topics are preferred
because they minimize the number of moving bases and queue interactions. Name
stack branches
`stack/<series>/<layer>`, link the stack with `gh stack link`, and inspect it
with `gh stack view --json`. Submit the complete stack with:

```nu
jj-ci stack-merge STACK_OR_PR
```

That wrapper uses `gh stack merge --yes --squash`, so each layer remains a
linear, atomic change without merge commits. A stack must remain topological:
each layer is based on the immediately preceding layer, parent layers land
before children, and the remaining layers are rebased onto the new `main` after
each parent lands. Never submit a child based on an outdated parent or queue
independent sibling PRs as if they were a stack.

Ordinary topics are queued for auto-merge only after the final automatic rebase
and only when the publisher explicitly passes `--auto-merge`; stack submission
remains the explicit ordering decision. Use a rebase merge only when preserving
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
jj workspace add --revision main@origin --name topic-name ../project-topic-name
```

Use that directory as a local Codex project. The session hook starts an
independent topic at `main@origin`, records ownership in
`.jj/codex-session.json`, and guards prompts and tool calls against change-ID
drift. It never automatically switches another task's working copy.

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
