---
name: jj-flake-evolution
description: Repository workflow for evolving this flake with jj discipline and targeted Nix validation.
---

# JJ-first flake evolution workflow

This skill is the repeatable workflow for **flake and host evolution in schlich/dotfiles**.

## Project context

- Customization scope: project-specific
- Host repository: project repo at /home/nixos/.config/home-manager
- Language: Nix and Nushell
- Workspace root: `.`
- Hooks: .github/hooks/jj-flake-vigilance.json
- Build: `nix build .#homeConfigurations.schlich.activationPackage`
- Test: `nix-build system/system_test.nix`
- Lint: `nix fmt`

## When to use

Use this skill for routine repository tasks that should follow a repeatable pattern, such as:

- evolving flake inputs or outputs
- changing Home Manager or NixOS modules
- tightening Copilot/Nushell/jj configuration in this repo
- validating whether a proposed change needs host-specific builds or only home-level validation

## Workflow

1. Inspect `flake.nix`, the touched modules, and any affected host entrypoints before editing.
2. Use `jj status`, `jj diff`, and `jj log` to understand current work; do not switch to mutating `git`.
3. If the task may require `jj rebase`, `jj squash`, `jj abandon`, `jj split`, or `jj op restore`, run `copilot/skills/jj/scripts/jj-checkpoint` first.
4. Make the smallest coherent change that preserves existing flake output names and host wiring.
5. Run `nix fmt` after Nix edits.
6. Choose validation based on the touched surface:
   - home-level changes: `nix build .#homeConfigurations.schlich.activationPackage`
   - WSL host changes: `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
   - desktop host changes: `nix build .#nixosConfigurations.desktop.config.system.build.toplevel`
   - smoke coverage when needed: `nix-build system/system_test.nix`
7. Summarize behavioral impact and any jj/history operations explicitly.

## Project notes

Prefer jj over git for all write operations. Read-only git inspection is acceptable, but commits, rebases, resets, switches, pushes, and other history edits should go through jj. Before risky jj history surgery such as rebase, squash, abandon, split, or op restore, record a checkpoint with `copilot/skills/jj/scripts/jj-checkpoint`. Run `nix fmt` after Nix edits. Build `.#homeConfigurations.schlich.activationPackage` for home-level changes, `.#nixosConfigurations.nixos.config.system.build.toplevel` for the WSL host, and `.#nixosConfigurations.desktop.config.system.build.toplevel` for desktop system changes. Use `nix-build system/system_test.nix` when system-level behavior needs the smoke test.
