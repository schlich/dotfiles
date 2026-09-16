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

`jj-ci publish` validates, pushes the stable `jj-<full-change-id>` bookmark,
and creates or updates the matching PR. It does not create a follow-up change.
Further edits to the series therefore update the same review topic.

`jj-ci finish` checks that GitHub merged the exact current head and that the
merge is on `main@origin`. It then advances local main, leaves an empty
workspace on main, and releases workspace ownership. Archive the task only
after it succeeds.

## Merge strategy

The permanent default is one PR per ordinary JJ topic. The publication
bookmark is a stable `jj-<change-id>` branch, and GitHub auto-merges it with
**squash** after all required checks pass. Squash keeps `main` linear and
turns a mutable review series into one atomic configuration change. Branches
from older sessions may retain their descriptive names, but new topics should
use the `jj-` prefix.

Use a stacked PR only when every layer is independently reviewable and the
layers must land in dependency order. Name those branches
`stack/<series>/<layer>`, link the stack with `gh stack link`, and inspect it
with `gh stack view --json`. Submit the complete stack with:

```nu
jj-ci stack-merge STACK_OR_PR
```

That wrapper uses `gh stack merge --yes --squash`, so each layer remains a
linear, atomic change without merge commits. Ordinary topics are queued for
auto-merge only when the publisher explicitly passes `--auto-merge`; stack
submission remains the explicit ordering decision. Use a rebase merge only
when preserving the individual patch-series commits on `main` is more valuable
than a single atomic commit.

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

## Git worktrees and the devshell

The repository's default devshell provides Nushell, JJ, GitHub CLI, Prek, and
the repository's `jj-ci` command. Enter it from any checkout with:

```nu
nix develop path:.
```

Codex may create ordinary Git worktrees rather than JJ workspaces. The devshell
does not silently convert or rewrite those checkouts. Inspect every checkout
against the latest fetched trunk with:

```nu
jj-ci worktree-status
```

`current` means `origin/main` is an ancestor of the worktree. `behind` means the
worktree can be fast-forwarded, and `diverged` means it needs an intentional
rebase. Active or dirty worktrees should be handled in their owning task; the
merge webhook updates only the dedicated trunk workspace.

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
