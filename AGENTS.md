# Repository workflows

## Shell conventions

- The user's interactive and configured shell is Nushell. When producing
  user-facing shell commands, scripts, aliases, or templates, use valid
  Nushell syntax.
- Prefer Nushell operations and pipelines for text processing and structured
  data transformations instead of `sed`, `awk`, or similar stream-editing
  commands. Prefer the Nushell evaluate tool to run Nushell commands and
  validate snippets when it is available. Use `nu -c` only when the tool is
  unavailable or validation specifically needs a fresh Nushell process.
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
- The active output is
  `nixosConfigurations.asus.config.system.build.toplevel`. Home Manager is
  embedded in it; there is no standalone `homeConfigurations` output. Its
  activation package is
  `nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage`.
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
  `nix build path:.#nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage`
  for Home Manager changes and
  `nix build path:.#nixosConfigurations.asus.config.system.build.toplevel`
  for system changes.

## Applying configuration

- When Nix configuration edits are ready to apply, identify whether they affect
  the NixOS system, Home Manager, or both, and ask the user for explicit
  approval before activating anything.
- For NixOS changes, offer `sudo nixos-rebuild switch --flake .#asus`; never
  run it automatically.
- Create a NixOS generation only when the candidate
  `system.build.toplevel` store path differs from the active
  `/run/current-system` target. If they match, do not switch merely to record a
  source change. Home-only activation is separate; `home.packages` is
  system-owned here and is covered by the toplevel comparison. See
  `docs/architecture.md` for the full policy.
- Home Manager is embedded in the `asus` NixOS configuration. Do not use the
  standalone `home-manager switch` workflow for this repository. Use
  `home-activate` for a home-only activation without `sudo`. This does not
  apply system-owned changes, including `home.packages` because
  `home-manager.useUserPackages = true`.

## Privileged command approval

- When a command needs elevated privileges, request tool-level escalation with
  a user-facing justification so the host presents an inline approval control
  in the current chat session. Do not require the user to leave the session
  to approve it.
- Never pass a sudo password through chat, command arguments, stdin, or
  environment variables. If inline escalation is unavailable, tell the user
  to run the command themselves or enable approval handling in the client.

## Version control

- Use Jujutsu for all repository mutations: changes, descriptions, bookmarks,
  rebases, conflict resolution, commits, and pushes. Git is allowed only for
  read-only inspection and JJ's Git backend interoperability.
- Start work with `jj status`, `jj diff`, and `jj log`. Preserve unrelated
  working-copy changes.
- Before risky history operations (`jj rebase`, `jj squash`, `jj abandon`,
  `jj split`, or `jj op restore`), create a checkpoint with
  `.agents/skills/jj/scripts/jj-checkpoint`.
- Tangled (`tangled` remote) hosts `main` and every topic branch. GitHub
  (`origin`) mirrors `main` and can clear a landing with
  `ci land --clearance github`. Never merge a GitHub pull request: squash and
  rebase merges rewrite the tested commit and lose change IDs and trailers.
- Use `ci sync` only from an empty working copy without an active task owner.
  It fetches `tangled`,
  advances the local `main` bookmark to `main@tangled`, and rebases the working
  copy onto it.
- Use `ci` for all trunk work, including lock-file-only updates.
- Before implementing or dispatching, inspect the working-copy diff for mixed
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

## Preflight and landing

- `prek` is installed declaratively. Run `prek run --all-files` or
  `ci preflight` before dispatch; JJ changes do not invoke Git hooks.
- End every JJ change description with an `Impact:` trailer. Use `refactor`
  when no NixOS closure changes (refactors, docs, CI, and tooling;
  `ci land` verifies it), `behavior` for a user-facing change, and
  `breaking` for a user-facing change that needs manual steps, which the
  description body must list. Keep refactors and user-facing changes in
  separate topics or stack layers. Each behavior or breaking revision that
  lands becomes a `YYYY.MM.DD.N` release; refactors cut none. See
  `jj/README.md`.
- Use a concise JJ change description. `ci dispatch` validates and pushes
  the topic's stable `jj-*` branch to Tangled; open a Tangled pull request from that branch when the topic needs review.
  Ordinary dispatch keeps editing the same change ID. Deliver it with
  `ci land` only at topic closeout.
- For a small change that affects a single host, a user request to dispatch (or to publish)
  also authorizes delivery: run `ci dispatch`, then `ci land` right away
  (its local clearance builds the checks), and `ci park` afterwards. Still stop after dispatching
  and ask before landing when the change affects several hosts, is part of a
  stack, is `Impact: breaking`, or touches boot, storage, encryption, or
  security configuration. A failed validation, pipeline, or rebase conflict
  stops delivery and is reported, never resolved automatically.
- Keep one coherent topic per Codex task. Use one stable JJ change for a single
  deliverable, but allow a small stack of changes when the task contains
  multiple deliverables that should be split. Do not create unrelated
  follow-up changes after dispatch. A topic is a revision; a workspace is
  a working copy for one actor. Start a topic with `ci new -m MESSAGE` in the
  current workspace, which leaves earlier topics as siblings (`jj edit`
  returns to one). Create a workspace with `ci start NAME` only for an actor
  that runs concurrently with the current working copy: another active agent
  task, or a build, dev server, or editor whose files must not change under
  it. Reuse such workspaces with `ci park --keep` rather than creating one
  per topic. Use `ci rebase` to update a topic in place. A conflict-free
  topic does not need to catch up with `main` before landing; `ci land` rebases it. `ci sequence --apply` restacks only stacked or
  conflicting topics, pushes only conflict-free rebases, and leaves conflicted
  topics local for resolution. Run `ci sequence --apply --all` only when the user
  asks to rebase every dispatched topic.
- Before archiving a delivered topic, run `ci park` and confirm success.
  It verifies that the current head landed and removes a workspace that
  `ci start` created (`--keep` leaves it on an empty change on main, ready
  for the pool's next task).
  Use `ci cancel` for a topic that will not land.
  A failed pipeline, conflicts, or undispatched edits keep the task open. Native
  archive-button clicks are not a closeout hook.
- `ci land` owns delivery to `main`. It rebases the topic onto
  `main@tangled`, proves a declared refactor leaves every closure unchanged,
  builds every flake check at that exact commit on the local machine, and only
  then fast-forwards `main` and tags releases. Never push `main` any other way.
  `--clearance spindle` or `--clearance github` waits for that CI on the exact head
  instead.
- The spindle runs `.tangled/workflows` only when started by hand; pushes do
  not trigger it, so never wait for a spindle run before landing. The
  flake-checks workflow and the local clearance run the same command: it builds
  every attribute of `checks.x86_64-linux`, including the headless and primary
  desktop system builds, and skips checks whose outputs are already cached.
  Add a check by adding a flake check; neither needs a change.

## Stacked topics

- Use a stack only for a preplanned chain of dependent, independently
  reviewable JJ changes, or when `ci sequence` reports that a topic conflicts
  with a dispatched one. Put a refactor below the user-facing change it
  enables, never above it. In that case, stack the later topic on the earlier
  one and resolve its conflicts locally before pushing. Keep unrelated,
  conflict-free work in separate branches.
- JJ creates, describes, rebases, and pushes every layer. The stack lives in
  the commit graph: `ci dispatch` stacks a topic on the dispatched topic it is
  built on or conflicts with, and `ci sequence --apply` restacks children after a
  parent changes.
- Land parents first. `ci land` refuses a topic whose parent has not
  landed; once it has, the child is already on `main` and lands next.
- For stacked review on Tangled, `ci dispatch --stack` pushes each
  revision as its own branch for `Submit as stacked PRs`. Pull requests are
  for review only; `ci land` still delivers.

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
  status, pipeline and pull request summaries, stack inspection, and
  formatting-only fixes.
- Escalate configuration edits, conflicts, failed validation, JJ mutations,
  Tangled writes, and landing decisions to the primary agent.
- Do not inspect `/nix/store` routinely. Prefer workspace files and Nix MCP
  package, option, and documentation queries; inspect the store only for an
  explicit user request, a specific path reported by a failure, or necessary
  source from an exact pinned flake input. Read those through the Nix MCP
  server's `flake-inputs` and `store` actions rather than shell or file
  tools.
- Foreground Bash is denied in Claude Code, so shell work arrives as Nushell
  MCP evaluations. A hook that guards or records shell commands must match
  `Bash|mcp__.*nushell__evaluate` and read `tool_input.input` as well as
  `tool_input.command`; one that tracks background work must also match
  `Monitor`, whose result carries `taskId`.
- Keep provider-neutral agent skills under `.agents/skills/`. Keep Copilot
  plugins, hooks, and plugin-bundled agent definitions under `copilot/`, and
  wire client exposure through `modules/tooling/ai/`.

## Configuration factory architecture

- Host files and `den/inventory.nix` describe facts; reusable behavior belongs in focused Den aspects.
- Avoid hostname conditionals. Add a typed profile field and a reusable aspect when a capability is genuinely shared.
- The `master` aspect resolves host facts into behavior. Prefer extending a focused aspect over expanding a catch-all module.
- Inspect the pinned Den API before using schema, aspect, policy, or output features: read it with the Nix MCP server's `flake-inputs` action (`type: ls` or `read`, `query: "den:PATH"`), which resolves the revision in `flake.lock`.
- Every declared host must evaluate. Keep policy and aspect metadata machine-readable so affected hosts, risk, checks, and reviewer domains can be identified.
- Do not silently alter boot, storage, filesystem, encryption, swap, or security configuration. These are high-risk changes and generated hardware files remain host-local.
- Never put plaintext secrets in the repository or Nix store. Preserve encrypted inputs and recovery paths.
- Do not automatically switch the current system. Build and evaluate first; any `nixos-rebuild test` or activation remains a deliberate manual operation.
- The architecture and safe recovery flow are documented in `docs/architecture.md`.

Repository checks are `nix fmt` and `nix flake check --no-build path:.`. The
flake checks include the workstation and headless system builds, so build them
only when explicitly requested because they are expensive; `nix-fast-build --skip-cached --flake path:.#checks.x86_64-linux` runs the same set as CI.
`nixos-rebuild switch` is never an agent validation step.

## Continuous integration and merge-conflict policy

Keep active work continuously integrated: start each topic at
`main@tangled`, rebase before review updates and when a topic conflicts with
trunk, and never let two concurrent actors share one working copy. `ci dispatch` performs the
final rebase and validation before pushing; `ci land` does the same and
lands only the commit the landing clearance passed.

Use `ci conflicts` after a rebase to list conflicted revisions and files.
A conflicted rebase has already rewritten the topic, so resolve revisions from
oldest to newest and validate only after the conflict report is clear. The only
unattended rebase is `ci sequence --apply`, and only when it is conflict-free: it
rebases a checked-out topic from that topic's own workspace, and only after a
trial merge predicts no conflict. Never resolve conflicts automatically.

Herdr or Paseo may monitor an existing JJ workspace and notify its
owner about stale trunk, topic, or pipeline state. They must not take
ownership of the workspace or silently rebase, resolve conflicts, dispatch,
land, or advance a stack.

Prefer one ordinary branch for a coherent topic. Use a stack only for independently
reviewable changes with real dependency order, including conflict order
reported by `ci sequence`; keep children based on their
immediate parent and rebase the remaining stack after each parent lands.
