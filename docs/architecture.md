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

User configuration is supplied by Den user aspects. Home Manager runs
standalone, apart from the system: an inventory user with `home = true`
(schlich on asus, asus-usb and homelab) gets the flake output
`homeConfigurations."USER@HOST"`, the name `nh home switch` looks up for that
user on that host. `den/inventory.nix` builds each home from its host's
package set and passes the evaluated system as `osConfig`, so home modules
still read system facts; `den/aspects/home-manager-host.nix` adds the overlays
those homes need to exactly those hosts. No system embeds or activates a
home, so applying a change is two steps, the system and then the home, and
Clan and a plain `system-switch` change only the system (see "Applying a
home" below). Every such user gets the
shell home (`user-shell`: Nushell, its
prompt and history tools, git, jj, ssh and the command-line tools), and
workstations add the desktop home (`user-desktop`: terminals, editors, agent
clients, desktop apps and their user services, plus the rest of
`modules/programs`).

## Application configuration placement

Home Manager links generated files into `$HOME`, and those links cause most of
this repository's activation trouble. Programs rewrite them in place, Claude
Desktop's sandbox rejects them (it shows the store target of `~/.ssh/config` as
owned by `nobody`), and orphaned generations override the host's configuration
(homelab). Keep app-owned files writable. When the locked Home Manager module
supports `mutableSettings`, use its merge or overlay behavior to apply declared
defaults without replacing app-owned files. Otherwise, when a program reads
configuration from an environment variable or flag, pass that configuration on
its executable instead. `lib/wrap-with-config.nix`
sets the variables and leading flags, and `dotfiles.retiredHomeFiles` makes
evaluation fail if Home Manager links a replaced path again.

Choose the path the wrapper names by how long the program runs:

- A command-line program starts fresh on every run, so it names the store file
  directly.
- A long-running graphical program that reloads its configuration names a
  stable path that a switch updates, so a reload picks up the new
  configuration: `/etc/niri/config.kdl` for niri, which never runs in the
  sandbox, and the user's profile (`~/.nix-profile`) for Ghostty.

Do not move a program that agents run to `/etc`: the Claude Desktop sandbox
shows no host `/etc/ssh` or `/etc/gitconfig`, while `/nix/store` and `$HOME`,
which holds the standalone home's `~/.nix-profile`, stay visible. Where Home Manager adds shell
integration but cannot safely manage an app's settings, keep
`programs.<name>.enable` with the wrapped `package` and no `settings`, after
checking at the locked revision that the module writes no file without
settings. For modules with `mutableSettings`, declarative settings can coexist
with the app's writable runtime configuration.

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
  define commands ship in the user's profile through
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

## Applying a home

The system and the home are separate generations, so a change that touches
both is applied in two steps: `system-switch` for the system, then
`home-activate` (or `nh home switch`) for the home. A system switch never
removes a standalone home's packages, which live in `~/.nix-profile`.

The one exception was the move to a standalone home. A system that still
embeds Home Manager carries the user's packages in
`/etc/profiles/per-user/USER`, and the first switch to a system without it
removes them all. On 2026-10-19 that emptied asus's PATH of jj, ci, nh and
`home-activate` itself, because `~/.nix-profile` had never been activated.
`system-switch` therefore checks before it starts the unit: when the running
system still has the Home Manager NixOS module's `home-manager-USER` unit and
main builds `homeConfigurations."USER@HOST"`, that home's activation package
must already be the user's active Home Manager generation. Otherwise it
stops and names both ways forward:

- `system-switch --with-home` switches and, once the switch succeeds,
  builds that home from the commit the switch deployed, runs its `activate`
  as the user, and records it for `generation`. It is the switch an agent
  runs after a landing that changes a closure (AGENTS.md, "Applying
  configuration"); otherwise, asking for it is the approval for both
  activations.
- `home-activate` from `~/dotfiles` at main, then `system-switch`.

`--with-home` also works on any later switch, to apply both steps from
landed main at once. Without it, `system-switch` changes only the system.

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
- `home-activate` runs `nh home switch` on the working copy, which may hold
  edits `main` lacks, so it appends the JJ change, commit, and whether that
  commit has landed to `~/.local/state/home-activate/generations.jsonl`.
  `system-switch --with-home` appends the landed commit it activated to the
  same log.

`generation` reads both: the running, booted, and boot-default system
generations, the revision behind the running one, whether Tangled's `main` has
moved past it, and the running Home Manager generation with the change or
commit it was built from (unrecorded after a bare `nh home switch` or a
hand-run `activate`). The system and the home are applied separately, so
their commits may differ. `generation --line` is a one-line form for
a status bar, and `--json` the full record. A host switched another way, such
as by Clan or `nixos-rebuild`, shows its source as unrecorded.

## Staged switches and reverts

The landing checks prove that a revision evaluates and builds, not that a host
runs it well, so `nixos-switch-main` (`deploy/switch.nu`) stages every switch
and undoes one that breaks the host:

1. It activates the candidate with `switch-to-configuration test`, which leaves
   the boot default alone, and starts a dead-man that blocks on the switch's
   lock.
1. It waits for the candidate to settle, driven only by systemd's events, with
   no timers of its own. `dry-activate` names the units the switch starts,
   restarts, or reloads. The watch follows PID 1's journal from activation
   and, on each message, checks those units. It breaches at once when one
   failed, a oneshot did not succeed, or systemd restarted one on its own, or
   when a unit that was fine before the switch failed. The candidate has
   settled once none of the touched units has a job queued or sits between
   states; systemd's own start and stop timeouts bound how long that can
   take. Then each probe that the host's `policy.healthChecks` names (`ssh`,
   `tailscale`, `niri-config`) runs once, and a probe
   that fails, or answers slower than its latency budget, breaches the watch.
1. A settled candidate whose probes pass becomes the boot default
   (`switch-to-configuration boot`) right away. A breach, a failed activation,
   or a run that dies before it decides (the dead-man) reactivates the
   previous system and rejects the revision. A reboot at any point before the
   commit boots the previous system.

Every entry point takes one lock in the state directory: a switch, manual or
automatic, the dead-man, and `nixos-switch-main-settle`, which runs at boot.
The dead-man starts with the stage and waits for the lock, so it acts the
moment the run dies and never races a live one; a run that decides stops it. A stage whose run died, by a kill or a reboot, is settled under
that lock before anything else is staged. A stage that reached the system
profile finishes its commit. Any other is rejected, so the canary does not stage
a candidate that crashed the host again at every boot, and the host returns to
the boot default if it is not running it. `deploy/StagedSwitch.tla` models these
processes, kills, and reboots. The `staged-switch-model` flake check runs TLC
over it. It proves the following for every interleaving:

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
system. Comparing the two evaluates the host twice, which made homelab's the
largest check, close to `ci`'s 6 GiB evaluation budget, so that check is a remote check that
GitHub Actions reports without gating a landing; `den-host-<host>` gates the
host's own evaluation. Tags come from the host's profile and policy (`workstation`,
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
Home Manager changes, `home.packages` included, never change the NixOS
toplevel: the home is standalone, and `nh home switch` (or `home-activate`, or
`system-switch --with-home`) applies it on each host apart from the system. A
landing therefore reaches a host's home only when someone switches that home
there; the canary's timer and Clan update systems alone, and neither runs the
check `system-switch` makes before a system stops embedding a home.
