# Repository workflows

## Shell conventions

- The user's interactive and configured shell is Nushell. When producing
  user-facing shell commands, scripts, aliases, or templates, use valid
  Nushell syntax.
- Prefer Nushell operations and pipelines for text processing and structured
  data transformations instead of `sed`, `awk`, or similar stream-editing
  commands. Use `nu -c` to validate multi-command Nushell snippets when
  practical.
- Nushell does not use POSIX backslash (`\`) line continuations. For
  multi-line external commands, put the command and each argument on its own
  line without trailing backslashes.

## Configuration

- This repository is a Nix flake. Keep tooling, shell wrappers, agent assets,
  and workflow enablement declarative through `flake.nix`, `home.nix`, and
  `modules/`.
- Target only `x86_64-linux` for all flake outputs (`packages`, `devShells`,
  `checks`, `formatter`, `apps`, `nixosConfigurations`, `homeConfigurations`,
  etc.) unless explicitly asked to support additional architectures or platforms.
- Preserve the existing modular flake structure. Do not introduce the
  Dendritic Pattern as part of an unrelated change; adopting it requires a
  deliberate architecture migration.
- The active outputs are
  `homeConfigurations.schlich.activationPackage` and
  `nixosConfigurations.asus.config.system.build.toplevel`.
- Add user packages in `modules/home/packages.nix`, version-control wrappers in
  `modules/programs/vcs.nix`, and AI client configuration in
  `modules/programs/ai.nix`.
- Treat application-owned, self-mutating configuration as runtime state. Do
  not manage such files with `home.file`, `xdg.configFile`, or a Home Manager
  `programs.*.settings` option. When the application supports it, couple
  immutable defaults to the package with a wrapper or command-line override;
  otherwise use the application's system-level configuration layer. In
  particular, Codex Desktop rewrites `$CODEX_HOME/config.toml`, so static
  Codex defaults belong on its wrapped package, while Home Manager may still
  manage non-mutating skills and context files.
- Use `path:` flake references for local work so new files are included without
  Git staging. For example, `nix build path:.#OUTPUT`. This includes ignored
  files as well; keep generated output and plaintext secrets outside that root.
- Format Nix changes with `nix fmt`. Do not run Nix builds or other build/test
  validation during agent responses unless the user explicitly requests it.
  When explicitly requested, use the smallest relevant build:
  `nix build .#homeConfigurations.schlich.activationPackage` for Home Manager
  changes and `nix build .#nixosConfigurations.asus.config.system.build.toplevel`
  for system changes.

## Applying configuration

- When Nix configuration edits are ready to apply, identify whether they affect
  the NixOS system, Home Manager, or both, and ask the user for explicit
  approval before activating anything.
- For NixOS changes, offer `sudo nixos-rebuild switch --flake .#asus`; never
  run it automatically.
- Home Manager is embedded in the `asus` NixOS configuration. Do not use the
  standalone `home-manager switch` workflow for this repository. Use
  `home-activate` for a home-only activation without `sudo`. This does not
  apply system-owned changes, including `home.packages` because
  `home-manager.useUserPackages = true`.

## Version control

- Use Jujutsu for all repository mutations: changes, descriptions, bookmarks,
  rebases, conflict resolution, commits, and pushes. Git is allowed only for
  read-only inspection and JJ's Git backend interoperability.
- Start work with `jj status`, `jj diff`, and `jj log`. Preserve unrelated
  working-copy changes.
- Before risky history operations (`jj rebase`, `jj squash`, `jj abandon`,
  `jj split`, or `jj op restore`), create a checkpoint with
  `.agents/skills/jj/scripts/jj-checkpoint`.
- Use `jj-ci sync` only from an empty working copy without an active task owner.
  It fetches `origin`,
  advances the local `main` bookmark to `main@origin`, and rebases the working
  copy onto it.
- Use `jj-ci` for all trunk work, including lock-file-only updates.

## Local gates and pull requests

- `prek` is installed declaratively. Run `prek run --all-files` or
  `jj-ci validate` before publication; JJ changes do not invoke Git hooks.
- Use a concise JJ change description. Publish a validated ordinary change with
  `jj-ci publish --auto-merge`; it creates or updates a PR and requests
  GitHub auto-merge against the current head SHA. Ordinary publication keeps
  editing the same change ID; enable auto-merge only at topic closeout.
- Keep one topic and one stable JJ change per Codex task. Do not create a
  follow-up change after publication. Use separate JJ workspaces for concurrent
  tasks, and `jj-ci rebase` to update a topic in place.
- Before archiving a delivered topic, run `jj-ci finish` and confirm success.
  It verifies delivery of the current head and leaves an empty change on main.
  Pending checks, conflicts, or unpublished edits keep the task open. Native
  archive-button clicks are not a closeout hook.
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

## User-visible progress

- Run routine inspection and formatting without dedicated updates. Do not run
  build or test validation unless the user explicitly requests it.
- Do not name skills, tools, commands, or repository policies merely to show
  compliance.
- For routine multi-step work, provide one short outcome-oriented update before
  starting. Add another only for a material result, decision, blocker, or
  long-running status.
- Mention an exact command only when the user asks, it fails, produces an
  unexpected change, requires approval, or materially affects the result.
- Group routine formatting and checks under “Validating the change.”

## Agents

- Use the `trunk-triage` agent (GPT-5.6 Luna) only for read-only repository
  status, CI and PR summaries, stack inspection, and formatting-only fixes.
- Escalate configuration edits, conflicts, failed validation, JJ mutations,
  GitHub writes, and merge decisions to the primary agent.
- Do not inspect `/nix/store` routinely. Prefer workspace files and Nix MCP
  package, option, and documentation queries; inspect the store only for an
  explicit user request, a specific path reported by a failure, or necessary
  source from an exact pinned flake input.
- Keep provider-neutral agent skills under `.agents/skills/`. Keep Copilot
  plugins, hooks, and plugin-bundled agent definitions under `copilot/`, and
  wire client exposure through `modules/tooling/ai/`.
