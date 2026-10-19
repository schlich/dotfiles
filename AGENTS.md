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
- The active outputs are the system
  `nixosConfigurations.asus.config.system.build.toplevel` and, apart from it,
  the standalone Home Manager configuration
  `homeConfigurations."schlich@asus"`, whose activation package is
  `homeConfigurations."schlich@asus".activationPackage`. Den derives one home
  for each inventory user with `home = true`, named `USER@HOST` as
  `nh home switch` expects (`den/inventory.nix`); each takes its host's
  package set and sees the system as `osConfig`.
- Add user packages in `modules/home/packages.nix`, version-control wrappers in
  `modules/programs/vcs.nix`, and AI client configuration in
  `modules/tooling/ai/`.
- Ship a program's configuration with the program, not as a file in `$HOME`.
  When it reads its configuration from an environment variable or flag, wrap
  the package with `lib/wrap-with-config.nix` and point it at a store file
  rather than using `home.file`, `xdg.configFile`, or `programs.*.settings`.
  Add each path the wrapper replaces to `dotfiles.retiredHomeFiles` so
  evaluation fails if Home Manager links it again. Do not move such
  configuration to `/etc` for a program that agents run: the Claude Desktop
  sandbox hides host `/etc`, and it shows store symlinks in `$HOME` as owned by
  `nobody`. `docs/architecture.md` has the placement rules and the remaining
  inventory.
- Treat application-owned, self-mutating configuration as runtime state. Do
  not link those files directly from the Nix store. When the locked Home
  Manager module supports `mutableSettings`, use it to apply declared defaults
  through that module's supported merge or overlay while keeping app-owned
  files writable. Otherwise couple immutable defaults to the package with a
  wrapper or command-line override, or use the application's system-level
  configuration layer. Codex 0.2.0 and later supports this merge; keep
  `programs.codex.mutableSettings` enabled for its declared defaults. Home
  Manager may still manage non-mutating skills and context files.
- Use `path:` flake references for local work so new files are included without
  Git staging. For example, `nix build path:.#OUTPUT`. This includes ignored
  files as well; keep generated output and plaintext secrets outside that root.
- Format Nix changes with `nix fmt`. Do not run Nix builds or other build/test
  validation during agent responses unless the user explicitly requests it.
  When explicitly requested, use the smallest relevant build:
  `nix build path:.#homeConfigurations.schlich@asus.activationPackage`
  for Home Manager changes and
  `nix build path:.#nixosConfigurations.asus.config.system.build.toplevel`
  for system changes.

## Applying configuration

- When Nix configuration edits are ready to apply, identify whether they affect
  the NixOS system, Home Manager, or both, and ask the user for explicit
  approval before activating anything.
- For NixOS changes, land them, then offer `system-switch`. It applies
  GitHub's `main` without sudo through the `nixos-switch-main` unit, which
  polkit lets the user start, and prints the switch's output and any failed
  units. Run it only when the user asks to switch; never start it on your
  own. Unlanded changes cannot be switched to this way.
- The switch is staged: the new system runs without becoming the boot default
  while the host's health checks are watched, and a breach reverts it and
  writes a report under `/var/lib/nixos-switch-main/reports/`. When a switch
  reverts, read that report and `deploy-reverts`, and propose the pre-deploy
  check that would have caught the regression (`docs/ci-failure-review.md`).
  `deploy-reverts causes` has Jev judge every report's root cause and ranks
  causes by how many reverts a pre-deploy check could have caught; read the
  reports behind the top cause before proposing a check.
  Do not retry a reverted revision without the user's approval.
- homelab is the canary: its inventory policy sets `autoDeploy`, so its own
  `nixos-switch-main-auto` timer stages each landing of `main` through the
  same watch. That timer is configuration, not an agent action; it does not
  authorize an agent to switch any host. A revert there reaches asus as a
  desktop notification; `deploy-reverts --all` on asus lists it.
- Clan can push a landed `main` to a host instead
  (`clan machines update homelab --flake path:.`); it is the same system, and
  the same rules apply: deploy only when the user asks, and only landed
  changes. Clan has no `test` or `dry-activate` goal: every update becomes
  the boot default without the staged watch, so keep it for recovery. Hosts
  opt in with `deploy.enable` in `den/inventory.nix`.
- Create a NixOS generation only when the candidate
  `system.build.toplevel` store path differs from the active
  `/run/current-system` target. If they match, do not switch merely to record a
  source change. The toplevel no longer contains the home: a Home Manager
  change, `home.packages` included, never needs a NixOS generation. See
  `docs/architecture.md` for the full policy.
- `generation` says which system and Home Manager generation a host runs,
  which commit each came from, and whether `main` has moved past it. Use it
  to answer what a host is running before proposing a switch or activation.
- Home Manager runs standalone, apart from the system: `system-switch` and
  Clan never apply it. Apply a home with `nh home switch`, which builds
  `homeConfigurations."$USER@$HOSTNAME"` from this checkout (`NH_FLAKE`) and
  needs no `sudo`; prefer `home-activate`, which runs it and records the
  change each generation came from for `generation`. The same approval rule
  applies: activate a home only when the user asks. `home.packages` install
  into `~/.nix-profile`, not `/etc/profiles/per-user`.
- Every activation prints dix's package and version changes from the running
  system (`modules/nixos/closure-diff.nix`), so `system-switch` and Clan
  output include them. When offering `system-switch`, mention the notable
  changes if a build already exists; `nix-suite diff` builds this checkout's
  system and shows them, but it is a build, so run it only when the user asks.
  `nix-suite last [N]` shows what recent switches changed.

## Workarounds for nixpkgs

- When this repository takes a package from another flake input, builds it
  itself, or overrides it because nixpkgs lags or lacks it, declare
  `dotfiles.nixpkgsWatch.<attribute>` in the same module, with `version` set
  to the version the workaround provides and `reason` naming what to remove.
  Remove the entry with the workaround. `modules/home/nixpkgs-watch.nix`
  documents the option.
- A build warning starting "nixpkgs now ships" means the locked nixpkgs has
  caught up: propose removing that workaround as its own topic.
- `nixpkgs-watch` prints the last daily npr report (open pull requests, ones
  that reached unstable, failures, and `related` ones that only mention the
  package but that Jev judged, from the title, to bear on the workaround);
  `nixpkgs-watch check` refreshes it. Read
  it when the user asks about a watched package or before updating the
  nixpkgs input.

## Privileged command approval

- When a command needs elevated privileges, request tool-level escalation with
  a user-facing justification so the host presents an inline approval control
  in the current chat session. Do not require the user to leave the session
  to approve it.
- In a shell without a terminal, such as Claude Code's Bash tool, use
  `sudo -A`: `SUDO_ASKPASS` points at sudoplz, which shows the command in a
  dialog and supplies the stored password only on approval.
- Inside the Claude desktop app's sandbox, no-new-privileges defeats
  `sudo`; use `run0 --background= /absolute/path/COMMAND` instead, which
  polkit approves in a dialog. Absolute paths are required: the transient
  unit's `PATH` lacks the NixOS system profile.
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
  or `jj split`), create a checkpoint with
  `.agents/skills/jj/scripts/jj-checkpoint`.
- Undo only your own operations. For a `ci` recovery point, run
  `ci recover ID`: it reverts just the operations that `ci` command tagged.
  Otherwise revert each of your operations since the checkpoint, newest
  first, with `jj op revert OP`. The operation log is shared by every
  workspace, so `jj op restore` rewinds other sessions' dispatches and
  landings too; on 2026-10-16 it undid a concurrent dispatch. Use it only as
  a last resort, and only with the user's approval while other workspaces
  are active.
- GitHub (`origin` remote) hosts `main` and every topic branch. Tangled
  (`tangled`) only mirrors `main` and its release tags, which `ci land`
  pushes there after each landing. Never merge a GitHub pull request: squash
  and rebase merges rewrite the tested commit and lose change IDs and the
  impact declarations keyed by them. The `main-checks` ruleset requires the
  `ci land` commit status, so only `ci land` can move `main`.
- Use `ci sync` only from an empty working copy without an active task owner.
  It fetches `origin`,
  advances the local `main` bookmark to `main@origin`, and rebases the working
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
  When both changes touch one file, split by hunk with
  `jj-hunk split -r <rev> --query HUNKSET`, never with an interactive `-i`;
  the `jj` skill covers its query language. Use explicit descriptions for both resulting changes, verify the resulting
  graph with `jj log`, and checkpoint before the split as with other history
  surgery. If more than two coherent changes are present, repeat the split
  and re-evaluate the dependency graph after each operation.

## Preflight and landing

- `prek` is installed declaratively. Run `prek run --all-files` or
  `ci preflight` before dispatch; JJ changes do not invoke Git hooks.
- Declare every JJ change's impact with `ci impact set CLASS`, not in its
  description, which stays prose. Use `refactor` when no NixOS closure
  changes (refactors, docs, CI, and tooling; `ci land` verifies it),
  `behavior` for a user-facing change, and `breaking STEP...` for a
  user-facing change that needs manual steps, one argument per step. Pass
  `-r REV` to declare another revision of a stack; declaring again replaces
  the declaration. It is recorded in this machine's ci log, keyed by change
  ID, so dispatch and land the topic from the machine that declared it. Keep
  refactors and user-facing changes in separate topics or stack layers. Each
  behavior or breaking revision that lands becomes a `YYYY.MM.DD.N` release;
  refactors cut none. See the ci repository's README
  (tangled.org/schlich.tngl.sh/ci).
- `ci` comes from the `ci` flake input. Change the workflow in its own
  repository, then move this one to it with `nix flake update ci`; try an
  unreleased copy here with `CI_SCRIPT=/path/to/ci.nu ci ...`. On the
  workstation, the hourly `ci-input-watch` timer does that update for each
  new ci release: it dispatches the bump from `.jj-workspaces/ci-input-update`
  and notifies, and landing it stays a deliberate `ci land` there.
  `ci-input-watch` shows what `main` pins and whether a bump is open.
- Use a concise JJ change description. `ci dispatch` validates and pushes
  the topic's stable `jj-*` branch to GitHub; open a GitHub pull request from that branch when the topic needs review, and never merge it.
  Ordinary dispatch keeps editing the same change ID. Deliver it with
  `ci land` only at topic closeout.
- For a small change that affects a single host, a user request to dispatch (or to publish)
  also authorizes delivery: run `ci dispatch`, then `ci land` right away
  (its local clearance builds the checks), and `ci park` afterwards. Still stop after dispatching
  and ask before landing when the change affects several hosts, is part of a
  stack, is declared `breaking`, or touches boot, storage, encryption, or
  security configuration. A failed validation, pipeline, or rebase conflict
  stops delivery and is reported, never resolved automatically.
- Keep one coherent topic per Codex task. Use one stable JJ change for a single
  deliverable, but allow a small stack of changes when the task contains
  multiple deliverables that should be split. Do not create unrelated
  follow-up changes after dispatch. A topic is a revision; a workspace is
  a working copy for one actor. Start a topic with `ci new -m MESSAGE` in the
  current workspace, which leaves earlier topics as siblings (`jj edit`
  returns to one). An agent session works only in a workspace whose change
  it owns. `~/dotfiles` is free when it sits idle on trunk (nothing above
  `main@origin` but an empty change, no live session owning it): the
  session's first edit claims it, and `ci new -m MESSAGE` names the claimed
  change in place. A named workspace under `.jj-workspaces/` belongs to the
  topic it was named for; never start another task there, even when it sits
  idle on trunk and the hooks list it as free. When `~/dotfiles` is busy,
  create a workspace named for the new task with `ci start NAME`. The hooks
  refuse edits to a workspace another live session owns, or to one holding a
  topic no session owns, such as the user's own work in progress. Never take
  over a topic the user started unless they hand it over with `ci adopt`.
  From a Claude Code worktree under `.claude/worktrees/`, which is not a JJ
  workspace, `ci start` creates the workspace inside the worktree; edit only
  there. Use
  `ci rebase` to update a topic in place. A conflict-free
  topic does not need to catch up with `main` before landing; `ci land` rebases it. `ci sequence --apply` restacks only stacked or
  conflicting topics, pushes only conflict-free rebases, and leaves conflicted
  topics local for resolution. Run `ci sequence --apply --all` only when the user
  asks to rebase every dispatched topic.
- Before archiving a delivered topic, run `ci park` and confirm success.
  It verifies that the current head landed and removes a workspace that
  `ci start` created. Do not pass `--keep`: a kept workspace keeps its old
  name and gets reused for unrelated work. `~/dotfiles` stays on main
  and is free again.
  Use `ci cancel` for a topic that will not land.
  A failed pipeline, conflicts, or undispatched edits keep the task open. Native
  archive-button clicks are not a closeout hook.
- `ci land` owns delivery to `main`. It rebases the topic onto
  `main@origin`, proves a declared refactor leaves every closure unchanged,
  builds every flake check at that exact commit on the local machine, and only
  then sets the `ci land` status on it, fast-forwards `main`, mirrors it to
  Tangled, and tags releases. Never push `main` any other way. It needs `gh`
  signed in to set the status. `--clearance github` waits for GitHub Actions
  on the exact head instead.
- GitHub Actions (`.github/workflows/nix-ci.yml`) is the remote CI: every
  push of `main` or a `jj-*` topic branch to GitHub starts it, and every
  `ci dispatch` pushes one. There is no Tangled spindle. The nix-ci workflow
  and the local clearance run the same check set: each builds
  every attribute of `checks.x86_64-linux` and skips checks whose outputs are
  already cached. Those checks evaluate every host but build no system
  closure: the headless system, the desktop system, and the desktop's
  primary home are `remoteChecks`,
  which GitHub Actions builds after each push without blocking a landing. A closure that fails to build can land, but no host
  activates it, since a switch builds before it stages anything. Add a check
  by adding a flake check; neither needs a change.

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
- For stacked review, `ci dispatch --stack` pushes each revision as its own
  branch; open a GitHub pull request for each against the branch below it.
  Pull requests are for review only; `ci land` still delivers.

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
  forge writes, and landing decisions to the primary agent.
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
- Run sessions for this repository locally, through Remote Control, or over
  SSH on a host with the same agent configuration. Do not start or hand off
  a cloud session for it: cloud sessions cannot run `ci`, use this
  machine's impact declarations, or activate a host. See `docs/claude-session-environments.md`, which
  also covers SSH failures inside a sandboxed local session.

## Project memory

`docs/project/` is this repository's project graph, vendored from
[iwe-org/dev-workspace](https://github.com/iwe-org/dev-workspace): product,
plans, features, bugs, specs, architecture, and releases as an IWE graph under
`docs/project/data/`. Its operating manual is `docs/project/AGENTS.md`; run
`iwe` commands from `docs/project/`, where keys start at `data/`.

- At the start of a session that plans, builds, or ships repository work, read
  `docs/project/data/product.md` and the active plans in
  `docs/project/data/plans.md`, then follow `docs/project/AGENTS.md` to record
  the state change before the session ends.
- Its workflow skills (setup, explore, plan, implement, verify, ship, weekly)
  stay in `docs/project/.claude/skills/`: they are specific to this graph, so
  they are deliberately not provider-neutral skills under `.agents/skills/`.
- The IWE root is `docs/project/`, not `docs/`, so `iwe normalize` never
  rewrites the loose notes beside it in `docs/`.
- `iwe schema validate` and a no-op `iwe normalize` in `docs/project/` gate any
  change to the graph.

## Configuration factory architecture

- Host files and `den/inventory.nix` describe facts; reusable behavior belongs in focused Den aspects.
- Avoid hostname conditionals. Add a typed profile field and a reusable aspect when a capability is genuinely shared.
- The `master` aspect resolves host facts into behavior. Prefer extending a focused aspect over expanding a catch-all module.
- Inspect the pinned Den API before using schema, aspect, policy, or output features: read it with the Nix MCP server's `flake-inputs` action (`type: ls` or `read`, `query: "den:PATH"`), which resolves the revision in `flake.lock`.
- Every declared host must evaluate. A host whose `policy.criticality` is `disposable` evaluates in `remoteChecks`, which GitHub Actions reports without blocking a landing, as do previews of a host with modules it has not adopted yet; every other host gates it through `checks`. Keep policy and aspect metadata machine-readable so affected hosts, risk, checks, and reviewer domains can be identified.
- Do not silently alter boot, storage, filesystem, encryption, swap, or security configuration. These are high-risk changes and generated hardware files remain host-local.
- Never put plaintext secrets in the repository or Nix store. Preserve encrypted inputs and recovery paths.
- Do not automatically switch the current system. Build and evaluate first; any `nixos-rebuild test` or activation remains a deliberate manual operation. The canary's own deployment timer (`policy.autoDeploy`) is the only exception, and enabling it for another host is a policy change for the user to request.
- The architecture and safe recovery flow are documented in `docs/architecture.md`.

Repository checks are `nix fmt` and `nix flake check --no-build path:.`. The
flake checks evaluate the workstation and headless systems, and `remoteChecks`
build them, so build either only when explicitly requested because they are
expensive; `nix-fast-build --skip-cached --flake path:.#checks.x86_64-linux` runs the same set as `ci land`.
`nixos-rebuild switch` is never an agent validation step.

## Continuous integration and merge-conflict policy

Keep active work continuously integrated: start each topic at
`main@origin`, rebase before review updates and when a topic conflicts with
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
