# Configuration architecture

This repository is organized around Den's feature-first model. The top-level
`den/` tree owns the entity schema, host inventory, policies, and aspect graph.
The flake exposes the configurations produced by that graph directly.

## Repository shape

- `den/inventory.nix` contains typed host and user facts.
- `den/aspects/` contains reusable capabilities and user environments.
- `den/hosts.nix` composes each host from explicit aspects.
- `hosts/` contains host-local hardware and storage facts only.
- `modules/` contains ordinary NixOS and Home Manager implementation modules
  consumed by aspects. It is not the composition layer.

The host declarations are intentionally small. For example, `asus` selects
the workstation, Niri, laptop, development, remote, XR, AMD, and platform
aspects. `asus-headless` selects the server and headless aspects instead.

## Resolution flow

```text
typed inventory -> host aspect composition -> Den host/user pipeline
                 -> NixOS + Home Manager module graph -> outputs/checks
```

User configuration is supplied by Den user aspects. A host runs Home Manager
when a user there has the `homeManager` class (asus, asus-usb and homelab);
`den/aspects/home-manager-host.nix` holds its NixOS settings for exactly those
hosts. Every such user gets the shell home (`user-shell`: Nushell, its
prompt and history tools, git, jj, ssh and the command-line tools), and
workstations add the desktop home (`user-desktop`: terminals, editors, agent
clients, desktop apps and their user services, plus the rest of
`modules/programs`).

## Configuration ships with the package

Home Manager links generated files into `$HOME`, and those links cause most of
this repository's activation trouble. Programs rewrite them in place (Copilot's
`config.json`), Claude Desktop's sandbox rejects them (it shows the store target
of `~/.ssh/config` as owned by `nobody`), and orphaned generations override the
host's configuration (homelab). A program that reads its configuration from an
environment variable or a flag gets that configuration on its executable
instead. `lib/wrap-with-config.nix` sets the variables and leading flags, and
`dotfiles.retiredHomeFiles` makes evaluation fail if Home Manager links a
replaced path again.

Choose the path the wrapper names by how long the program runs:

- A command-line program starts fresh on every run, so it names the store file
  directly.
- A long-running graphical program that reloads its configuration names a
  stable path that a switch updates, so a reload picks up the new
  configuration: `/etc/niri/config.kdl` for niri, which never runs in the
  sandbox, and the per-user profile for Ghostty.

Do not move a program that agents run to `/etc`: the Claude Desktop sandbox
shows no host `/etc/ssh` or `/etc/gitconfig`, while `/nix/store` and
`/etc/profiles/per-user` stay visible. Where Home Manager still adds shell
integration, keep `programs.<name>.enable` with the wrapped `package` and no
`settings`, after checking at the locked revision that the module writes no
file without settings.

These stay in Home Manager:

- Agent clients (Claude Code, Codex, Copilot, OpenCode, Zed): their
  configuration directories are runtime state.
- GnuPG: `GNUPGHOME` also holds the keys.
- gh's `config.yml` and `hosts.yml`, which gh writes itself.
- XDG user directories, systemd user units, fontconfig, and the shared
  `.agents/skills` discovery paths.
- Helix's `languages.toml`: Helix reads it only from its configuration
  directory, and patching the built-in copy would rebuild Helix without the
  binary cache.
- Nushell's `config.nu`: no variable names it, an explicit `--config` also
  loads for scripts and `nu -c`, and the vendor autoload directories reach the
  agent MCP server as well as interactive sessions. Autoload files that only
  define commands ship in the per-user profile through
  `dotfiles.nushellAutoload` instead. Starship's `init nu` embeds the
  unwrapped binary's path, so `config.nu` sets `STARSHIP_CONFIG` rather than
  a wrapper.
- intelli-shell's `config.toml`: its only directory override also moves its
  database.

## Formatting and future unit tests

Repository-wide formatting and the future nix-unit test surface are provided
by [Checkmate](https://github.com/denful/checkmate). Format locally with:

```text
nix run github:denful/checkmate#fmt --override-input target path:. -- --on-unmatched warn --excludes '.agents/**' --excludes '.codex/**' --excludes 'workbench/knowledge/**' --excludes 'docs/project/**'
```

`docs/project/` is an IWE graph: `iwe normalize` formats it, and Checkmate's
Markdown formatter would flatten its YAML frontmatter.

## Safety boundaries

Hardware, storage, boot, encryption, and generated machine files remain under
`hosts/`. Reusable aspects do not infer or rewrite those facts. Inventory
validation rejects invalid combinations such as server plus Niri or XR without
a graphical workstation.

The typed aspect policy registry records risk and reviewer domains in Den
aspect metadata. CI evaluates every declared host, checks the Home Manager
activation graph, and runs the independent desktop configuration checks.
Hosts whose `policy.criticality` is `disposable` evaluate in the flake's
`remoteChecks` instead of `checks`, as do evaluations of homelab with modules
it has not adopted yet: GitHub Actions reports them after each push without
blocking, and `ci land` leaves them out.

No activation is implied by evaluation or builds. A system or home activation
requires an explicit operator decision after the generated output has been
reviewed. The one standing decision is the canary: a host whose
`policy.autoDeploy` is set stages each landing of `main` on its own (see
below).

## NixOS generation policy

A NixOS generation is warranted exactly when the candidate system toplevel's
store path differs from the active system at `/run/current-system`. Compare the
realized `nixosConfigurations.<host>.config.system.build.toplevel` path with
the active symlink target. If they match, do not run a NixOS switch just to
record the source change; evaluation and builds do not create generations.

When the paths differ and the system change is to be applied, use the deliberate
NixOS activation workflow: land the change, then run `system-switch`. It starts
the root `nixos-switch-main` unit, which polkit lets the primary user start
without a password. The unit builds the host from Tangled's `main` at a pinned
revision, never from a working copy, skips the switch when that toplevel is
already active, and records the result in `/var/lib/nixos-switch-main`.

## Which commit a generation came from

A store path does not name the commit that produced it, and this repository
keeps it that way: `system.configurationRevision` would stamp the revision
into the closure, so every landing would change every host's system, a
declared refactor could no longer prove it changes nothing, and the policy
above would call for a generation per commit. The pairing is recorded beside
the generation instead:

- `nixos-switch-main` appends a line to
  `/var/lib/nixos-switch-main/generations.jsonl` for each switch that becomes
  the boot default (`deployed`) and for each later revision whose system is
  already running (`unchanged`). One store path therefore maps to the revision
  that introduced it and the newest one still producing it.
- `home-activate` builds the working copy, which may hold edits `main` lacks,
  so it appends the JJ change, commit, and whether that commit has landed to
  `~/.local/state/home-activate/generations.jsonl`.

`generation` reads both: the running, booted, and boot-default system
generations, the revision behind the running one, whether Tangled's `main` has
moved past it, and whether Home Manager runs the generation the system embeds
or one `home-activate` built since. `generation --line` is a one-line form for
a status bar, and `--json` the full record. A host switched another way, such
as by Clan or `nixos-rebuild`, shows its source as unrecorded.

## Staged switches and reverts

The landing checks prove that a revision evaluates and builds, not that a host
runs it well, so `nixos-switch-main` (`deploy/switch.nu`) stages every switch
and undoes one that breaks the host:

1. It activates the candidate with `switch-to-configuration test`, which leaves
   the boot default alone, and arms a dead-man timer.
1. It watches the host for `dotfiles.deploy.watch.duration` seconds (180, or
   300 on a critical host). Every sample checks for units that failed since the
   switch, the journal's error rate against its rate before the switch, restart
   loops, and each probe that the host's `policy.healthChecks` names (`ssh`,
   `tailscale`, `niri-config`, `home-manager-nixos`). A probe also fails when it
   answers slower than its latency budget. A check that fails three samples in
   a row breaches the watch.
1. A healthy candidate becomes the boot default (`switch-to-configuration boot`).
   A breach, a failed activation, or a watch that never decides (the dead-man
   timer) reactivates the previous system and rejects the revision. A reboot at
   any point before the commit boots the previous system.

Every entry point takes one lock in the state directory: a switch, manual or
automatic, the dead-man timer, and `nixos-switch-main-settle`, which runs at
boot. A dead-man that fires while its run is alive waits for the lock instead
of racing it. A stage whose run died, by a kill or a reboot, is settled under
that lock before anything else is staged. A stage that reached the system
profile finishes its commit. Any other is rejected, so the canary does not stage
a candidate that crashed the host again at every boot, and the host returns to
the boot default if it is not running it. `deploy/StagedSwitch.tla` models these
processes, kills, and reboots. The `staged-switch-model` flake check runs TLC
over it, with activation both able and unable to outlast the dead-man's grace
period. It proves the following for every interleaving:

- Only a candidate that passed its watch becomes the boot default.
- No stage is both committed and reverted, and no stage is reverted twice.
- Every revert restores the boot default.
- Once nothing is in flight, the host runs its boot default with no
  `pending.nuon` left.
- The canary stages each revision at most once.

The running system's settings judge the candidate, so a candidate cannot
weaken its own watch. Each revert, and each revision that fails to evaluate or
build, appends a line to `/var/lib/nixos-switch-main/reverts.jsonl` with a
Markdown report beside it under `reports/`: the breached checks, newly failed
units, restart loops, and journal errors, plus who landed the revision. Reports
quote the journal, so only `wheel` reads them. A workstation's
`deploy-revert-notify` user timer announces each new revert once and offers to
open an agent on its report. `deploy-reverts` lists the log and tallies the
checks that caused reverts. That tally is the feedback loop: each revert marks
a regression the pre-deploy checks missed, and the next check to write is the
one that would have caught the most frequent cause (see
`docs/ci-failure-review.md`). `tests/deploy-revert.nix`, in `remoteChecks`, runs
a broken candidate, a healthy one, and a killed watch through the real script
in a VM.

homelab is the canary. Its inventory sets `policy.autoDeploy`, so the
`nixos-switch-main-auto` timer looks at `main` every five minutes and stages
each new landing through the same watch, so a landing usually reaches it
before a workstation switches. It takes each revision once: one it deployed or
rejected waits for `main` to move, and `system-switch` there retries a rejected
one on request. A manual switch and the timer share a lock, and the timer
skips its turn while the lock is held. asus's notifier fetches homelab's new
reverts over ssh (`deploy-reverts notify homelab`) and keeps them under
`~/.local/state/deploy-reverts`, where `deploy-reverts --all` includes them.
The den-policy check lets a host deploy itself only with health checks to
watch, and inventory validation also requires review and rollback for a
critical one. A Clan update to homelab activates without the watch and makes
the new system the boot default at once (`switch-to-configuration boot`, then
`switch`); Clan has no `test` or `dry-activate` goal, so keep it for recovery.
Clan pushes the same systems over ssh instead of having the host pull them.
The flake's `clan` output has a machine for each host whose inventory sets
`deploy.enable`, and `clan machines update` builds that host's
`nixosConfigurations` entry, the system CI checks. Clan's own machine imports
the module list Den resolved for the host with Clan's recommended defaults
off, and a `clan-machine-<host>` check fails if it differs from
`nixosConfigurations`, so Clan's vars and settings describe the deployed
system. Tags come from the host's profile and policy (`workstation`,
`server`, `critical`, `niri`; `clan machines list --tags server`), and every
machine requires an explicit update, so a deploy names its hosts:
`clan machines update homelab --flake path:.` from a workspace at landed
`main`. It builds on the deploying machine and copies the closure. Activation
logs in as `deploy.targetUser`; homelab uses root, which its Tailscale SSH
admits, because sudo there asks for a password over Tailscale SSH. Any other
user escalates with sudo on the target. asus has no `deploy.targetHost`, so
`clan machines update asus` reaches it over ssh to localhost. Deploying from
an unlanded topic skips the landing gate, and Clan offers no preview goal to
reserve it for, so do not.
Home Manager-only changes use `home-activate` when
they leave the NixOS toplevel unchanged. In this repository,
`home-manager.useUserPackages = true`, so changes to `home.packages` are
system-owned and can change the NixOS toplevel; classify those by the same path
comparison rather than by where the option is declared.
