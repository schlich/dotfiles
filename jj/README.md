# JJ project workflow

The `ci` trunk workflow (`ci.nu` and its launcher, the TLA+ model and the
lifecycle machine, `context-status`, the MCP server, `ci tower`, and the `ci`
skill) lives in its own repository,
[tangled.org/schlich.tngl.sh/ci](https://tangled.org/schlich.tngl.sh/ci),
mirrored to `github:schlich/ci`. Its README documents the workflow. This
repository takes it as the `ci` flake input: every workspace runs the version
`flake.lock` pins, and `nix flake update ci` moves to a newer one, which
reaches the installed `ci` once the system or Home Manager activates. To try
an unreleased workflow here, run `CI_SCRIPT=/path/to/ci.nu ci ...`.

The workflow is opt-in per repository. A repository opts in when JJ's config
sets `ci.enable = true` there: `jj config set --repo ci.enable true` for one
clone, or its path in `dotfiles.ci.repositories` (`modules/programs/ci.nix`),
which scopes the key to every clone and workspace there through
`--when.repositories` in the wrapped jj's config. `ci-enabled` reads the key.
The Claude Code context-status hooks
(`modules/tooling/ai/scripts/only-in-ci-repos.nu`), the prompt's ci segment,
and the shell's readout on entering a workspace run only where it is set, and
the agent instructions apply `ci` only there; everywhere else agents use plain
jj. `jj config unset --repo ci.enable`, or dropping the path, opts out again.

Earlier history of the workflow is here: `jj log -- jj/ci.nu`.

What stays in this directory is this machine's glue around it:

- `dashboard.nu` is `jj-dashboard`, below.
- `tangled-init.nu` is `tangled-init`, which gives a new repository the
  `tangled` remote for `schlich.tngl.sh/NAME` and makes it the repository's
  push remote and trunk in its own JJ config. It does not opt the repository
  into `ci`. `tangled-init-hook.nu` runs it
  after a Nushell `jj git init` whose repository has no remotes, so clones and
  repositories that already publish elsewhere are left alone. Create the
  repository at https://tangled.org/repo/new; `tangled-init` reports whether
  it exists yet.
- `webhook-setup.nu` and `WEBHOOK.md` set up the agent follow-up after
  successful checks.
- `receive-verification.nu` is homelab's forced command for the
  `config-verifications` account that `ci verify` appends to.

## Desktop

Codex has no JJ-specific hooks and does not load JJ context status. Its
configured launcher can start a task workspace from the shared default
checkout; otherwise, open the JJ workspace you want it to edit. Keep one actor
per working copy and keep editing the same topic until delivery. Existing
claims from the old hooks can be released with `ci unclaim` from the affected
workspace once its previous actor has stopped; this leaves the topic intact.

Press **Mod+G** to open or focus the focused Niri workspace's VCS stack: jjui
and gh-dash as tabs of one column, where pressing it again switches tabs. From a
terminal, `jj-dashboard /path/to/workspace` opens a dashboard for that
workspace. The Codex **Open in -> JJ dashboard** handler accepts a project
directory or file.

Git and lazygit are disabled as Home Manager programs. JJ retains an explicit
Git executable dependency, and gh gets its own internal Git PATH for repository
discovery. GitHub credential-helper configuration remains available to JJ.
Keep this repository colocated for existing Git-based tools such as Prek and
GitHub discovery.
