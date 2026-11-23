# dotfiles

A Nix flake that builds a personal fleet of NixOS systems and standalone Home Manager
homes. Hosts are composed from typed facts and reusable
[Den](https://github.com/denful/den) aspects; changes are integrated with luvus,
gated by nixbot, and applied through staged switches that revert themselves
when a host breaks.

## Hosts

| Host            | Role                                     | Notes                                                           |
| --------------- | ---------------------------------------- | --------------------------------------------------------------- |
| `asus`          | Workstation (AMD laptop, niri, XR, dev)  | The daily machine; switched by hand after each delivery.        |
| `asus-headless` | Server                                   | The same hardware without a desktop.                            |
| `asus-usb`      | Workstation                              | A disposable copy of `asus`; evaluated without gating delivery. |
| `homelab`       | Server (Intel, niri for local debugging) | The canary: it stages every landing of `main` on its own.       |

Each host is a stack of layers in `den/inventory.nix`. Every user with
`home = true` also gets `homeConfigurations."USER@HOST"`, the name
`nh home switch` looks up.

## Layout

```text
flake.nix          inputs (grouped under lib/inputs) and flake outputs
den/               composition: inventory, model, policies, aspects, hosts
hosts/             host-local hardware, storage, and boot facts only
modules/           NixOS and Home Manager modules that aspects import
  nixos/             system: base, workstation, builds, homelab, fleet, services
  home/              shared home state: packages, files, nix, session
  programs/          shell, vcs, desktop, multiplexers, ssh
  tooling/           terminal, editor, and AI client integrations
lib/               wrap-with-config, closure-diff, census, input groups
deploy/            staged switch, revert log, generation tracking, TLA+ model
tools/             luvus-deliver, nixpkgs-watch, den-reach, ci-trace, ...
niri/ noctalia/    compositor config and desktop shell plugins
nushell/ mcp/      Nushell commands and the helpers the Nushell MCP server loads
tests/             flake checks and Nushell test suites
docs/              architecture, delivery, desktop, agents, project graph
```

`modules/README.md` and [honeycomb](https://github.com/schlich/honeycomb#readme) explain the grouping rule:
no directory or flake-input group holds more than six entries.

## How a host is built

```text
typed inventory -> host aspect composition -> Den host/user pipeline
                 -> NixOS + Home Manager module graph -> outputs/checks
```

Host files and the inventory describe facts; behavior lives in focused Den
aspects (`den/aspects/`: roles, desktop, services, fleet, users). Inventory
validation rejects impossible combinations, and policy metadata records each
host's criticality, health checks, and deployment rules. See
[docs/architecture.md](docs/architecture.md).

Programs get their configuration on their executable where they can
(`lib/wrap-with-config.nix`) rather than as Home Manager links in `$HOME`;
application-owned files that rewrite themselves stay writable runtime state.

## Working on it

Use `path:` flake references so new files are included without staging:

```nu
nix fmt
nix flake check --no-build path:.
nix build path:.#homeConfigurations."schlich@asus".activationPackage
nix build path:.#nixosConfigurations.asus.config.system.build.toplevel
```

Update inputs with `nix-suite update [INPUT...]` rather than
`nix flake update`.

Every change goes through a task branch in its own worktree:

1. `luvus task add` and `luvus task start ID --agent AGENT` (or
   `luvus worktree create BRANCH`) create the worktree.
1. `luvus task done ID` runs the quality gate, `gateChecks.x86_64-linux`.
1. `luvus task merge ID` merges the branch into `luvus/integration`.
1. `luvus-deliver` pushes it, waits for nixbot's evaluation and build on that
   commit, and fast-forwards `main`. High-risk changes (secrets, hosts, boot,
   storage, security) stop for approval first.

GitHub Actions and Dagger also run the flake checks but gate nothing.
[docs/delivery/](docs/delivery/) covers nixbot, Dagger, CI tracing, and
failure review.

## Applying a change

The system and the home are separate generations:

- `system-switch` builds the host from GitHub's `main` and stages it: the new
  system runs without becoming the boot default until its units settle and its
  health checks pass, and a breach reverts it and writes a report under
  `/var/lib/nixos-switch-main/reports/`.
- `home-activate` (or `nh home switch`) applies the home;
  `system-switch --with-home` does both from the same landed commit.
- `generation` shows which commit each running generation came from, and
  `deploy-reverts` lists reverts and ranks their causes.

homelab's `nixos-switch-main-auto` timer stages each new landing on its own,
so a regression usually reverts there before a workstation sees it.

## Agents

[AGENTS.md](AGENTS.md) is the operating manual for coding agents in this
repository. Agent skills live in `.agents/skills/`, Copilot plugins in
`copilot/`, and client wiring in `modules/tooling/ai/`. `docs/project/` is the
project's IWE graph of plans, features, and releases.
