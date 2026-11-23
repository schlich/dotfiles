---
type: architecture
description: Why a server's Home Manager home is built into its NixOS system while a workstation's stays standalone, and how the two stay one home.
generated:
  by: claude-code/opus-5.5
  at: 2026-11-23T21:00:00Z
sources:
- id: schema
  resource: den/model/schema.nix
  title: the user's homeActivation fact
- id: inventory
  resource: den/inventory.nix
  title: where each home is resolved and handed to its activation
- id: hm-host
  resource: den/aspects/users/home-manager-host.nix
  title: the NixOS side of an embedded home
- id: arch
  resource: docs/architecture.md
  title: Applying a home, and the canary
---

# Embedded server homes

## Decision

A server's home is part of its system; a workstation's stays standalone. Each
inventory user with `home = true` has a `homeActivation` fact: `standalone` (the
default) gives `homeConfigurations."USER@HOST"`, which `nh home switch` and
`home-activate` apply apart from the system; `embedded` builds the home into the
host's NixOS system through the Home Manager NixOS module (`useGlobalPkgs`,
`useUserPackages`), so every switch activates it. schlich on homelab is
embedded; asus and asus-usb are standalone. Owner's decision, 2026-11-23,
following the usual NixOS precedent.

Both kinds are the same home. `den/inventory.nix` resolves every home in Den's
`home` context from the same aspects; an embedded one's instantiate hands its
module list to Den's internal `flake.embeddedHomes."USER@HOST"`, which
`den/aspects/users/home-manager-host.nix` imports under the host's
`home-manager.users.USER`. Only the standalone `home-manager` CLI differs.

## Why

homelab is the canary: its timer stages each landing of `main`, but it, Clan and
a plain `system-switch` update systems only. With a standalone home, homelab's
system followed `main` while its home stayed wherever someone last ran
`home-activate`. On 2026-11-23 the home was still built from `a7d9f3ac`
(2026-11-20), so `luvus-deliver` there still asked Jev about delivery risk two
days after `main` removed that, Jev failed, and a delivery was forced to high
risk. Tools on a server run unattended (agent sessions, the T3 Code server), so
its home is system state and must deploy with the system.

## Rejected alternatives

- **Every host embedded** — ties every workstation home edit to a sudo-gated
  system switch and leaves no `nh home` target; asus keeps standalone homes for
  quick, sudo-free iteration (see [Configuration
  factory](configuration-factory.md)).
- **Teach the canary timer to activate the standalone home too** — a root unit
  activating a user's home outside Home Manager's NixOS module duplicates what
  that module does, and the staged watch would not cover the home.
- **Den's own `homeManager` user class** — Den would resolve the user in its
  host-user context instead of the `home` context the user's aspects read, so
  the embedded home could drift from the standalone one.
- **A hostname conditional** — host facts stay typed; `homeActivation` is a user
  fact any server can set.

## Consequences

- A home change on homelab changes its toplevel and warrants a NixOS generation;
  on asus it never does.
- homelab's packages live in `/etc/profiles/per-user/schlich`; units find them
  through `home.profileDirectory`, not `~/.nix-profile`.
- `home-activate` refuses on an embedded host, `system-switch --with-home` only
  notes the home came with the switch, and `generation` reports the home as part
  of the system generation.
- The `inventory` tests require every host with `policy.autoDeploy` to embed its
  homes.
- Moving a host from standalone to embedded leaves the old standalone home in
  `~/.nix-profile` as `home-manager-path`, ahead of the per-user profile on
  PATH, until `nix profile remove home-manager-path` once the first embedded
  switch is the boot default (`docs/architecture.md`, "Applying a home").
