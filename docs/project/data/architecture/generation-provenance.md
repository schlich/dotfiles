---
type: architecture
description: Each host records which commit produced its running system and Home Manager generation beside the generation, never inside the closure.
generated:
  by: claude-code/opus-5
  at: 2026-10-16T19:40:00Z
sources:
- id: switch-script
  resource: deploy/switch.nu
  title: Staged switch that writes the system log
- id: generation-command
  resource: deploy/generation.nu
  title: The generation command
- id: home-activate
  resource: modules/home/nix.nix
  title: home-activate, which writes the Home Manager log
---

# Generation provenance

## Decision

A store path does not name the commit that produced it, so each host records the
pairing next to its generations. `nixos-switch-main` appends a line to
`/var/lib/nixos-switch-main/generations.jsonl` when a switch becomes the boot
default (`deployed`) and when a later revision's system is already running
(`unchanged`). One store path therefore maps to the revision that introduced it
and the newest revision still producing it. `home-activate`, which builds the
working copy, appends the JJ change, commit, and landed state of each Home
Manager generation it activates to
`~/.local/state/home-activate/generations.jsonl`.

The `generation` command reads both logs. It reports the running, booted, and
boot-default system generations, the revision behind the running system, whether
Tangled's `main` has moved past it, and whether Home Manager runs the generation
the system embeds or a later `home-activate` build. `--line` gives one line for
a status bar, and `--json` gives the full record.

## Boundaries

- The closure never contains the revision, so a declared refactor still lands
  with every host's system unchanged, and the generation policy still creates a
  generation only when the system's store path changes.
- Only switches through `nixos-switch-main` are recorded. A host switched by
  Colmena or `nixos-rebuild` shows its source as unrecorded.
- `main` being `ahead` means this host has not been switched to or checked
  against it. Whether the newer revision changes this host's system is known
  only after a switch evaluates it.

## Alternatives considered

- **`system.configurationRevision = self.rev`:** this is what NixOS provides,
  and `nixos-version --json` and `nixos-rebuild list-generations` would show it.
  It is rejected because it embeds the revision in the closure. Every commit
  would then change every host's system, `ci land` could no longer prove a
  refactor leaves the system unchanged, and every landing would call for a new
  generation.
- **The revision in the boot label (`system.nixos.label`):** this has the same
  problem. The label is part of the toplevel's store path, which is why the
  switch labels a system with a hash of its own build instead.
- **Only `last.nuon`:** the switch already kept the last revision and store
  path, but it overwrote that record on every run. It could not answer the
  question for an older generation, nor say that a later refactor still produces
  the running system.
