---
type: architecture
description: How Den composes hosts from typed inventory and aspects, and why program configuration ships with the package instead of Home Manager links.
generated:
  by: claude-code/opus-5.5
  at: 2026-10-16T16:45:00Z
sources:
- id: arch
  resource: docs/architecture.md
  title: configuration architecture, the full design note this summarizes
- id: inventory
  resource: den/inventory.nix
  title: typed host inventory
- id: wrap
  resource: lib/wrap-with-config.nix
  title: wrapper that puts configuration on the executable
---

# Configuration factory

The flake is a factory: typed facts go in, NixOS and Home Manager configurations
come out. `den/inventory.nix` builds each host by merging layers (fleet
defaults, hardware, a workstation profile, host overrides) into one record of
`profile`, `policy`, `deploy`, and `users` facts, and validates it before
evaluation. `den/hosts.nix` then selects explicit aspects from `den/aspects/`,
and Den's host and user pipeline resolves them into the module graph that
`nixosConfigurations`, `checks`, and Clan's machines share.

``` text
typed inventory -> host aspect composition -> Den host/user pipeline
                 -> NixOS + Home Manager module graph -> outputs/checks
```

`modules/` is implementation, not composition: aspects consume its modules, and
`hosts/` holds only hardware and storage facts. The full design, including
deployment, staged switches, and reverts, lives in `docs/architecture.md`; this
note records the decisions a plan must not undo.

## Decision: configuration ships with the package

A program that reads its configuration from an environment variable or a flag
gets it on its executable through `lib/wrap-with-config.nix`, and
`dotfiles.retiredHomeFiles` fails evaluation if Home Manager links a replaced
path again. A command-line program names the store file directly; a long-running
graphical program that reloads names a stable path a switch updates
(`/etc/niri/config.kdl`, Ghostty's per-user profile).

Rejected alternatives:

- **Home Manager links in `$HOME`** — programs rewrite them in place (Copilot's
  `config.json`), the Claude Desktop sandbox rejects them, and orphaned
  generations override a host's configuration (homelab).
- **`/etc` for programs agents run** — the Claude Desktop sandbox shows no host
  `/etc/ssh` or `/etc/gitconfig`, while `/nix/store` and
  `/etc/profiles/per-user` stay visible.

Runtime state stays in Home Manager or with the program: agent client
configuration directories, `GNUPGHOME`, gh's own files, Helix's
`languages.toml`, Nushell's `config.nu`, and intelli-shell's `config.toml`.

## Unknown

- Why Den was chosen over a plain flake-parts or NixOS-module layout is not
  recorded in the code or `docs/`.
