# Repository workflows

## Configuration

- This repository is a Nix flake. Keep tooling, shell wrappers, agent assets,
  and workflow enablement declarative through `flake.nix`, `home.nix`, and
  `modules/`.
- The active outputs are
  `homeConfigurations.schlich.activationPackage` and
  `nixosConfigurations.asus.config.system.build.toplevel`.
- Add user packages in `modules/home/packages.nix`, version-control wrappers in
  `modules/programs/vcs.nix`, and AI client configuration in
  `modules/programs/ai.nix`.
- Format Nix changes with `nix fmt`. Run the smallest relevant build:
  `nix build .#homeConfigurations.schlich.activationPackage` for Home Manager
  changes and `nix build .#nixosConfigurations.asus.config.system.build.toplevel`
  for system changes.

## Version control

- Use Jujutsu for all repository mutations: changes, descriptions, bookmarks,
  rebases, conflict resolution, commits, and pushes. Git is allowed only for
  read-only inspection and JJ's Git backend interoperability.
- Start work with `jj status`, `jj diff`, and `jj log`. Preserve unrelated
  working-copy changes.
- Before risky history operations (`jj rebase`, `jj squash`, `jj abandon`,
  `jj split`, or `jj op restore`), create a checkpoint with
  `copilot/skills/jj/scripts/jj-checkpoint`.
- Use `jj-trunk sync` only from an empty working copy. It fetches `origin` and
  aligns the local `main` bookmark with `main@origin`.
- Keep lock-file-only updates in `jj-flake`; use `jj-trunk` for general trunk
  work.

## Local gates and pull requests

- `prek` is installed declaratively and its hook is installed by Home Manager.
  Run `jj-trunk validate` before publication; it runs `prek run --all-files`
  against every revision in `trunk()..@` through isolated JJ workspaces and
  discards hook changes.
- Use a concise JJ change description. Publish a validated ordinary change with
  `jj-trunk publish --auto-merge`; it creates or updates a PR and requests
  GitHub auto-merge against the current head SHA.
- GitHub owns PR state, required checks, and delivery to `main`. Do not bypass
  protection with direct pushes or manual merge commands.
- The required `nix-ci` checks evaluate Home Manager and build NixOS, Niri,
  Zellij, and whitespace checks. `main` uses strict required checks and linear
  history.
- `jj-trunk github reconcile` reports the declared GitHub policy. Use
  `jj-trunk github reconcile --apply` only when intentionally reconciling
  auto-merge, branch deletion, and `main` protection.

## Stacked pull requests

- Use a stack only for a preplanned chain of dependent, independently reviewable
  JJ changes. Keep unrelated work in separate branches.
- JJ creates, describes, rebases, and pushes every layer. Link existing GitHub
  PRs with `gh stack link` and inspect them non-interactively with
  `gh stack view --json`.
- Once every layer is green at its current head, submit the stack with
  `jj-trunk stack-merge <stack-or-pr>`. GitHub handles queue-compatible delivery
  to `main`.
- Do not run `gh stack init`, `add`, `submit`, `sync`, or `rebase`; they mutate
  Git-managed branches and violate the JJ boundary.

## Agents

- Use the `trunk-triage` agent (GPT-5.6 Luna) only for read-only repository
  status, CI and PR summaries, stack inspection, and formatting-only fixes.
- Escalate configuration edits, conflicts, failed validation, JJ mutations,
  GitHub writes, and merge decisions to the primary agent.
- Keep Copilot plugins, skills, hooks, and agent definitions under `copilot/`
  and wire client exposure through `modules/programs/ai.nix`.
