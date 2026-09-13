# JJ project workflow

One task owns one topic, one JJ workspace, and one stable change ID. Edits and
repeated publication rewrite that change. Start a new task for a new topic.

```nu
jj-ci status
jj-ci rebase                  # Fetch trunk and rebase this topic in place.
jj-ci validate                # Run the repository gates when requested.
jj-ci publish                 # Create/update the same PR; keep editing here.
# At topic closeout, when delivery has been requested:
jj-ci publish --auto-merge
# After GitHub merges the current revision:
jj-ci finish
```

`finish` checks that GitHub merged the exact current head and that its merge
commit is on `main@origin`. It then advances local main, leaves an empty working
copy on main, and releases this workspace's Codex ownership. It also permits
an unpublished empty topic to finish after confirming it has no PR. Checks,
conflicts, or newer local edits leave the task open. After success, ask Codex
to archive the task. Auto-merge should only be enabled when edits are finished.

Bookmarks use `jj-<full-change-id>`, so title changes cannot send another topic
to the same PR. Existing PRs using the older title-based bookmarks need an
explicit migration before using this publication flow; do not duplicate them.
`publish` runs `jj fix -s @` and Prek, then pushes using JJ and creates the PR
using GitHub CLI. GitHub owns protection, checks, and merging.

`jj-ci sync` is for an empty workspace with no active Codex topic. It refuses
to move an owned workspace, including webhook-triggered sync. Use `rebase`
during a topic. Recovery operation IDs are saved under `.jj/jj-ci-checkpoints`.

## Desktop

Press **Mod+2** to open or focus jjui on Niri's `vcs` workspace. From a terminal,
`jj-dashboard /path/to/workspace` opens a dashboard for that workspace. The
Codex **Open in → JJ dashboard** handler accepts a project directory or file.
Inside jjui, use its help view for current bindings and its Git menu for JJ
push/fetch operations. These are JJ operations using GitHub transport.

Git and lazygit are disabled as Home Manager programs. JJ retains an explicit
Git executable dependency, and gh gets its own internal Git PATH for repository
discovery. GitHub credential-helper configuration remains available to JJ.
This does not remove Git from transitive dependencies or prevent other apps
from invoking their bundled Git.

The observed desktop PR auto-merge watcher is disabled declaratively. A global
switch to disable all native Git controls has not been established. Avoid its
Git commit/worktree/handoff/push actions for JJ tasks. Keep this repository
colocated for existing Git-based tools such as Prek and GitHub discovery.

Codex's documented SessionEnd event also fires on app exit and idle timeout,
and is advisory. It cannot distinguish an archive click or prevent one. There
is therefore **no merge-on-archive-button hook**. Use the explicit
finish-then-archive workflow; closing the app never publishes code.

## Concurrent tasks

Create a separate JJ workspace before opening a new local project task:

```nu
jj workspace add --revision main@origin --name topic-name ../project-topic-name
```

Use that directory as a **local** Codex project, avoiding Git worktrees. The
session hook starts an independent topic at `main@origin`, records ownership in
`.jj/codex-session.json`, and guards subsequent prompts and tool calls against
change-ID drift. It never automatically switches another task's working copy.
Hook guards are not a security boundary; native UI and external terminal
operations can bypass them.

Session markers also live in `$XDG_STATE_HOME/codex-jj-sessions` (default
`~/.local/state/codex-jj-sessions`). Older session markers are adopted only when
the recorded change is still checked out. An interrupted startup can leave
`.jj/codex-session-claim`; inspect the owner marker, task state, and `jj op log`
before recovering it. Do not delete another live task's claim.

## Nix and GitHub

Git-backed flakes include unstaged edits to tracked files, but omit untracked
files. The activation wrappers now use `path:/home/schlich/dotfiles`, so new
files are included without Git staging. Use explicit path references for other
local commands too:

```nu
nix develop path:.
nix run path:.#jj -- git fetch --remote origin
nix run path:.#jj -- git push --remote origin --bookmark BOOKMARK
nix run path:.#jjui
```

These apps use the flake's pinned Jujutsu and jjui packages. A push transfers a
bookmark; use `jj-ci publish` when a PR is also needed. Existing GitHub auth
continues through `gh auth git-credential`; `gh auth login` sets up a new login.

Path sources include ignored files and repository metadata as well. Keep
plaintext secrets and bulky generated output outside the selected source root.
Activation still requires approval; these changes affect system packages,
Home Manager, and system-owned Codex hooks, so use a NixOS activation for the
complete migration.

For a deliberately planned dependency stack, use JJ to create and push layers,
`gh stack link` to link their PRs, and `jj-ci stack-merge` to submit the green
stack. Do not use Git-managed stack mutations or direct pushes to main.

References: [Codex hooks](https://learn.chatgpt.com/docs/hooks),
[custom file handlers](https://learn.chatgpt.com/docs/config-file/config-reference),
[JJ transport](https://docs.jj-vcs.dev/latest/config/#git-subprocessing-behavior),
[Nix flake inputs](https://nix.dev/manual/nix/2.26/command-ref/new-cli/nix3-flake.html).
