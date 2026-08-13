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
- Use `jj-ci sync` only from an empty working copy. It fetches `origin`,
  advances the local `main` bookmark to `main@origin`, and rebases the working
  copy onto it.
- Keep lock-file-only updates in `jj-flake`; use `jj-ci` for general trunk
  work.

## Local gates and pull requests

- `prek` is installed declaratively. Run `prek run --all-files` or
  `jj-ci validate` before publication; JJ changes do not invoke Git hooks.
- Use a concise JJ change description. Publish a validated ordinary change with
  `jj-ci publish --auto-merge`; it creates or updates a PR and requests
  GitHub auto-merge against the current head SHA, then starts an empty
  follow-up changeset so later edits do not rewrite the pushed revision.
- GitHub owns PR state, required checks, and delivery to `main`. Do not bypass
  protection with direct pushes or manual merge commands.
- The required `nix-ci` checks evaluate Home Manager and build NixOS, Niri,
  Zellij, and whitespace checks. `main` uses strict required checks and linear
  history.
- `jj-ci github reconcile` reports the declared GitHub policy. Use
  `jj-ci github reconcile --apply` only when intentionally reconciling
  auto-merge, branch deletion, and `main` protection.

## Stacked pull requests

- Use a stack only for a preplanned chain of dependent, independently reviewable
  JJ changes. Keep unrelated work in separate branches.
- JJ creates, describes, rebases, and pushes every layer. Link existing GitHub
  PRs with `gh stack link` and inspect them non-interactively with
  `gh stack view --json`.
- Once every layer is green at its current head, submit the stack with
  `jj-ci stack-merge <stack-or-pr>`. GitHub handles queue-compatible delivery
  to `main`.
- Do not run `gh stack init`, `add`, `submit`, `sync`, or `rebase`; they mutate
  Git-managed branches and violate the JJ boundary.

## Agents

- Use the `trunk-triage` agent (GPT-5.6 Luna) only for read-only repository
  status, CI and PR summaries, stack inspection, and formatting-only fixes.
- Escalate configuration edits, conflicts, failed validation, JJ mutations,
  GitHub writes, and merge decisions to the primary agent.
- Do not inspect `/nix/store` routinely. Prefer workspace files and Nix MCP
  package, option, and documentation queries; inspect the store only for an
  explicit user request, a specific path reported by a failure, or necessary
  source from an exact pinned flake input.
- Keep Copilot plugins, skills, hooks, and agent definitions under `copilot/`
  and wire client exposure through `modules/programs/ai.nix`.
