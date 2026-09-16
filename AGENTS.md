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
- Before implementing or publishing, inspect the working-copy diff for mixed
  deliverables. Split unrelated work into separate JJ changes instead of
  carrying it in one change. Choose the graph shape by semantic dependency:
  use a parent/child chain only when the child needs the parent's code, schema,
  configuration, or other behavior to build, test, or make sense; use sibling
  changes when each part is independently reviewable and can land without the
  other. Do not make changes parent/child merely because they touch related
  files or were discovered in the same task.
- JJ has this split built in: `jj split` (or `jj split -r <rev>`) creates a
  parent/child pair, while `jj split --parallel -r <rev>` creates siblings.
  Use explicit descriptions for both resulting changes, verify the resulting
  graph with `jj log`, and checkpoint before the split as with other history
  surgery. If more than two coherent changes are present, repeat the split
  and re-evaluate the dependency graph after each operation.

## Local gates and pull requests

- `prek` is installed declaratively. Run `prek run --all-files` or
  `jj-ci validate` before publication; JJ changes do not invoke Git hooks.
- Use a concise JJ change description. Publish a validated ordinary change with
  `jj-ci publish --auto-merge`; it creates or updates a PR and requests
  GitHub auto-merge against the current head SHA. Ordinary publication keeps
  editing the same change ID; enable auto-merge only at topic closeout.
- Keep one coherent topic per Codex task. Use one stable JJ change for a single
  deliverable, but allow a small stack of changes when the task contains
  multiple deliverables that should be split. Do not create unrelated
  follow-up changes after publication. Use separate JJ workspaces for
  concurrent tasks, and `jj-ci rebase` to update a topic in place.
- Before archiving a delivered topic, run `jj-ci finish` and confirm success.
  It verifies delivery of the current head and leaves an empty change on main.
  Pending checks, conflicts, or unpublished edits keep the task open. Native
  archive-button clicks are not a closeout hook.
- GitHub owns PR state, required checks, and delivery to `main`. Do not bypass
  protection with direct pushes or manual merge commands.
- The required `nix-ci` checks build the headless NixOS bootstrap first, then
  the desktop NixOS system and Home Manager, alongside Niri, Zellij, and
  whitespace checks. `main` uses strict required checks and linear history.
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
  plugins, hooks, and plugin-bundled agent definitions under
  `modules/tooling/ai/assets/copilot/`, and
  wire client exposure through `modules/tooling/ai/`.

## Configuration factory architecture

- Host files and `den/inventory.nix` describe facts; reusable behavior belongs in focused Den aspects.
- Avoid hostname conditionals. Add a typed profile field and a reusable aspect when a capability is genuinely shared.
- The `master` aspect resolves host facts into behavior. Prefer extending a focused aspect over expanding a catch-all module.
- Inspect the pinned Den API in `flake.lock` and the fetched source before using schema, aspect, policy, or output features.
- Every declared host must evaluate. Keep policy and aspect metadata machine-readable so affected hosts, risk, checks, and reviewer domains can be identified.
- Do not silently alter boot, storage, filesystem, encryption, swap, or security configuration. These are high-risk changes and generated hardware files remain host-local.
- Never put plaintext secrets in the repository or Nix store. Preserve encrypted inputs and recovery paths.
- Do not automatically switch the current system. Build and evaluate first; any `nixos-rebuild test` or activation remains a deliberate manual operation.
- The architecture and safe recovery flow are documented in `docs/architecture.md`.

Repository checks are `nix fmt`, `nix flake check path:.`, and (when explicitly
requested because they are expensive) the workstation and headless system
builds. `nixos-rebuild switch` is never an agent validation step.

## Continuous integration and merge-conflict policy

Keep active work continuously integrated: start each dedicated JJ workspace at
`main@origin`, rebase after trunk advances and before review or queue updates,
and never share a mutable topic worktree. `jj-ci publish` performs the final
rebase and validation before updating GitHub; `jj-ci stack-merge` does the same
before submitting a stack.

Use `jj-ci conflicts` after a rebase to list conflicted revisions and files.
A conflicted rebase has already rewritten the topic, so resolve revisions from
oldest to newest and validate only after the conflict report is clear. Do not
run unattended auto-rebase or automatic conflict resolution.

Herdr or Paseo may monitor one existing JJ workspace per topic and notify its
owner about stale trunk, PR, check, or queue state. They must not take
ownership of the workspace or silently rebase, resolve conflicts, publish, enter
a queue, or advance a stack.

Prefer one ordinary PR for a coherent topic. Use a stack only for independently
reviewable changes with real dependency order; keep children based on their
immediate parent and rebase the remaining stack after each parent lands.
