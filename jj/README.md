# JJ project workflow

The `ci` trunk workflow (`ci.nu` and its launcher, the TLA+ model and the
lifecycle machine, `context-status`, the Codex ownership hooks, the MCP
server, `ci tower`, and the `ci` skill) lives in its own repository,
[tangled.org/schlich.tngl.sh/ci](https://tangled.org/schlich.tngl.sh/ci),
mirrored to `github:schlich/ci`. Its README documents the workflow. This
repository takes it as the `ci` flake input: every workspace runs the version
`flake.lock` pins, and `nix flake update ci` moves to a newer one, which
reaches the installed `ci` once the system or Home Manager activates. To try
an unreleased workflow here, run `CI_SCRIPT=/path/to/ci.nu ci ...`.

Earlier history of the workflow is here: `jj log -- jj/ci.nu`.

What stays in this directory is this machine's glue around it:

- `dashboard.nu` is `jj-dashboard`, below.
- `webhook-setup.nu` and `WEBHOOK.md` set up the agent follow-up after
  successful checks.
- `receive-verification.nu` is homelab's forced command for the
  `config-verifications` account that `ci verify` appends to.

## Desktop

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
