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
  the NixOS system, Home Manager, or both. Apply only changes delivered to
  `main`; others cannot be switched to.
- `system-switch` applies GitHub's `main` without sudo through the
  `nixos-switch-main` unit, which polkit lets the user start, and prints the
  switch's output and any failed units. After `luvus-deliver` moves `main`,
  the agent that delivered runs `system-switch --with-home` on asus at once,
  without asking, and reports the outcome; a delivery that changed no closure
  creates no generation. Ask first instead when the change needs manual steps
  before activation, or touches boot, storage, encryption, or security
  configuration. Switch another host only when the user asks.
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
- Home Manager runs standalone, apart from the system, so applying a change
  is two steps: `system-switch` for the system, then the home. Clan and a
  plain `system-switch` never apply a home. Apply a home with
  `nh home switch`, which builds `homeConfigurations."$USER@$HOSTNAME"` from
  this checkout (`NH_FLAKE`) and needs no `sudo`; prefer `home-activate`,
  which runs it and records the change each generation came from for
  `generation`. `system-switch --with-home` does both from landed main: after
  a successful switch it activates the home from the same commit, so the
  switch after a closure-changing landing always passes it. Outside that,
  activate a home only when the user asks.
  `home.packages` install into `~/.nix-profile`, not `/etc/profiles/per-user`.
- `system-switch` refuses to start when the running system still embeds the
  user's Home Manager and main's standalone home is not active yet, because
  that switch would remove every user package (as on asus on 2026-10-19).
  `--with-home` avoids it; if a plain `system-switch` refuses, rerun it with
  `--with-home`.
- Every activation prints dix's package and version changes from the running
  system (`modules/nixos/closure-diff.nix`), so `system-switch` and Clan
  output include them. When reporting or offering a switch, mention the
  notable changes; `nix-suite diff` builds this checkout's
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

- This repository takes writes through Git, driven by luvus. jj and `ci` are
  set aside here; they stay installed for other repositories, so their
  global rules do not apply in this one. It stays colocated, so read-only jj
  commands such as `jj log` still work, but make every change with Git.
  `dotfiles.tooling.gitWorkflowRepos` lists it, so the jj write guard and
  ci's context-status hooks leave sessions here, and in its worktrees, alone.
- One task, one branch, one worktree. Start a task from the luvus
  orchestration board (`Ctrl+Space o`, or `luvus task add` and then
  `luvus task start ID --agent AGENT`), which creates a Git worktree on its
  own branch (`luvus/tID`) under `~/.luvus/worktrees/`, or with
  `luvus worktree create BRANCH` for work outside the board. Work only in the
  worktree your task owns; never make a task's edits in the `~/dotfiles`
  main checkout, which other sessions share.
- Give each task the file globs it will touch (`--paths`), so luvus's path
  leases keep two tasks off the same files, and its dependencies (`--deps`)
  when it needs another task's work first.
- Commit with ordinary Git, in small commits with concise, descriptive
  messages. Do not rewrite commits that `luvus/integration` or another
  branch already contains, and never push `main` directly.
- Before finishing, check the branch's diff for mixed deliverables, and split
  unrelated work into separate tasks rather than carrying it in one branch.
- The jj workspaces under `.jj-workspaces/` and their topics predate this
  switch. Leave them alone unless the user asks: they hold earlier work,
  some of it the user's.

## Delivery

- A task's quality gate is the repository's flake checks: create tasks with
  `--gate "nix-fast-build --skip-cached --no-nom --flake path:.#checks.x86_64-linux"`,
  or `--gate "prek run --all-files"` for documentation-only work.
  `luvus task done ID` runs it; a failure holds the task at `review` with the
  output saved on the task. Run `prek run --all-files` before marking a task
  done either way.
- `luvus task merge ID` merges a done task's branch into `luvus/integration`
  in luvus's own integration worktree, one task at a time. A conflict aborts
  the merge and marks the task `blocked`: merge `luvus/integration` into the
  task's branch in its worktree, resolve, rerun the gate, and merge again.
  Resolve conflicts automatically when the intended result is clear; preserve
  the changes from both sides and rerun the relevant checks. Ask only when
  resolving the conflict requires a product decision or unclear intent.
- `luvus-deliver` delivers `luvus/integration` to `main`. It first judges
  the delivery's risk, which `luvus-deliver risk` previews: code works out
  from Den which hosts each changed file reaches, and Jev judges whether the
  change touches boot or storage, secrets or keys, or access, and how badly
  a mistake could break a host (`delivery_risk` in `jev/questions.nuon`).
  Then it pushes the branch, waits for nixbot's `nixbot/nix-eval` and
  `nixbot/nix-build` on that exact commit, and fast-forwards `main` to it.
  The `main-checks` ruleset admits only a commit with both passed, reported
  by nixbot's own App, and GitHub refuses a push that is not a fast-forward.
  It waits for homelab to build, so run it as a `job-log` job. When
  `luvus/integration` no longer contains `origin/main`, merge `origin/main`
  into it first.
- A user request to publish or deliver authorizes the whole path: gate,
  merge, `luvus-deliver`, and the switch "Applying configuration" describes.
  A high-risk delivery stops before it pushes and names why: it touches
  boot, storage, secrets, keys, or access, or `secrets/`, `hosts/`, the
  rulesets, or the classifier itself; it reaches several hosts through
  configuration `den/policy.nix` rates high or critical, or could break more
  than a desktop app there; or Jev cannot judge it. Show the owner those reasons and ask. Once
  they approve, rerun `luvus-deliver --approve REV` with the commit it names;
  never pass `--approve` without that approval. Each verdict is kept in
  `~/.local/state/luvus-deliver/risk.jsonl` for review after landing. A
  failed gate, CI run, or unresolved merge conflict stops delivery and is reported.
- Once a task is delivered, remove its worktree with
  `luvus worktree remove PATH`, which refuses while a task, lease, or live
  agent still uses it; the branch stays. Then offer to archive the session
  in the same turn: in the Claude desktop app, end the turn with the
  wrap-up's `archive` action as the first button; elsewhere, say in one line
  that the session can be archived. Archive only on the user's click or yes.
- GitHub (`origin`) hosts `main`, `luvus/integration`, and any branch pushed
  for review. Open a pull request from a task branch when the user wants
  review, but deliver through `luvus-deliver`, never GitHub's merge button.
  Tangled (`tangled`) mirrored `main` through `ci land`; that mirror is
  paused while this repository runs on luvus.
- nixbot on homelab is the gating CI (`docs/nixbot.md`): it builds
  `checks.x86_64-linux` for `main`, every `luvus/*` branch (`nixbot.toml`),
  and pull requests, in homelab's warm store.
- GitHub Actions (`.github/workflows/nix-ci.yml`) also runs on a push of
  `main` or a `luvus/**` branch, or a pull request, but gates nothing. It
  builds every attribute of `checks.x86_64-linux`, skipping cached outputs; a
  push to `main` skips them, since that commit passed on `luvus/integration`.
  The headless system, the desktop system, and the desktop's primary home
  are `remoteChecks`, which build after each push without blocking delivery.
  A closure that fails to build can reach `main`, but no host activates it,
  since a switch builds before it stages anything. Add a check by adding a
  flake check.

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
  status, pipeline and pull request summaries, and formatting-only fixes.
- Escalate configuration edits, conflicts, failed validation, Git mutations,
  forge writes, and delivery decisions to the primary agent.
- Hand work between agents with luvus (`luvus agent prompt`, `read`, `keys`,
  and `fork`), and coordinate parallel tasks on its orchestration board.
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
  a cloud session for it: cloud sessions cannot reach this machine's luvus
  server or activate a host. See `docs/claude-session-environments.md`, which
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
- Switch the current system only through `system-switch` from delivered `main`: after a delivery as "Applying configuration" describes, or when the user asks. Never use `nixos-rebuild test` or another activation outside it. The canary's own deployment timer (`policy.autoDeploy`) switches homelab on its own, and enabling it for another host is a policy change for the user to request.
- The architecture and safe recovery flow are documented in `docs/architecture.md`.

Repository checks are `nix fmt` and `nix flake check --no-build path:.`. The
flake checks evaluate the workstation and headless systems, and `remoteChecks`
build them, so build either only when explicitly requested because they are
expensive; `nix-fast-build --skip-cached --flake path:.#checks.x86_64-linux` runs the same set as nix-ci and the luvus quality gate.
`nixos-rebuild switch` is never an agent validation step.

## Continuous integration and merge-conflict policy

Keep active work continuously integrated: branch each task from
`origin/main`, merge `origin/main` into a long-running task branch when it
falls behind or conflicts, and never let two concurrent actors share one
worktree. luvus's merge gate integrates finished tasks one at a time in its
own worktree, and `luvus-deliver` moves `main` only to a commit nixbot
passed.

Resolve merge conflicts automatically when the intended result is clear,
preserving the changes from both sides. When `luvus task merge` reports a
conflict, resolve it in the task's worktree, rerun the relevant checks and
gate, and merge again. Ask the user only when the resolution requires a
product decision or the intended behavior is unclear; keep the task
`blocked` until that decision arrives.

Order dependent work with task dependencies (`--deps`): a dependent task
waits until its dependency is merged into `luvus/integration`. Keep
unrelated, conflict-free work in separate tasks.
