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
nix run github:denful/checkmate#fmt --override-input target path:. -- --on-unmatched warn --excludes '.agents/**' --excludes '.codex/**'
```

## Safety boundaries

Hardware, storage, boot, encryption, and generated machine files remain under
`hosts/`. Reusable aspects do not infer or rewrite those facts. Inventory
validation rejects invalid combinations such as server plus Niri or XR without
a graphical workstation.

The typed aspect policy registry records risk and reviewer domains in Den
aspect metadata. CI evaluates every declared host, checks the Home Manager
activation graph, and runs the independent desktop configuration checks.

No activation is implied by evaluation or builds. A system or home activation
requires an explicit operator decision after the generated output has been
reviewed.

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
Colmena pushes the same systems over ssh instead of having the host pull
them. `colmenaHive` deploys each host whose inventory sets `deploy.enable`,
from the module list Den resolved for it, and the `colmena-hive` check fails
if a node's system differs from `nixosConfigurations`. Tags come from the
host's profile and policy (`workstation`, `server`, `critical`, `niri`), and
`allowApplyAll` is off, so a deploy names its hosts:
`colmena apply --config path:. --on homelab` from a workspace at landed
`main`, or `colmena apply-local --config path:. --sudo` on asus. Remote
activation logs in as `deploy.targetUser`; homelab uses root, which its
Tailscale SSH admits, because sudo there asks for a password over Tailscale
SSH. Any other user needs non-interactive sudo on the target. Deploying from an unlanded topic skips the landing gate, so
reserve it for `test` or `dry-activate` goals.
Home Manager-only changes use `home-activate` when
they leave the NixOS toplevel unchanged. In this repository,
`home-manager.useUserPackages = true`, so changes to `home.packages` are
system-owned and can change the NixOS toplevel; classify those by the same path
comparison rather than by where the option is declared.
