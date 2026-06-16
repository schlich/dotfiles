---
description: 'Routing and repository guidance for using the generated Copilot plugin in schlich/dotfiles flake workflow'
applyTo: 'flake.nix,flake.lock,home.nix,configuration.nix,system/**/*.nix,modules/**/*.nix,**/*.nu,copilot/**/*.md,.github/**/*.{json,md}'
---

# JJ-first flake evolution guide

This repository uses a generated Copilot customization stack with distinct responsibilities for agents, skills, prompts, and instructions.

## Placement

- Customization scope: project-specific
- Host repository: project repo at /home/nixos/.config/home-manager
- Hooks: .github/hooks/jj-flake-vigilance.json

## Routing guidance

- Use the `project-specialist` custom agent for multi-step flake work and repository-aware decisions.
- Use the `jj-flake-evolution` skill for the normal inspect/edit/validate loop.
- Use prompt files in `.github/prompts/` as human-invoked entrypoints.
- Reuse the repo-local `copilot/skills/jj` references when you need exact jj syntax or recovery guidance.

## Version-control policy

1. Use `jj` for repository write operations. Read-only `git` inspection is acceptable; mutating `git` commands are not.
2. The repo hook in `.github/hooks/jj-flake-vigilance.json` blocks common mutating `git` shell commands so agents stay on the jj path.
3. Before risky jj history surgery such as `jj rebase`, `jj squash`, `jj abandon`, `jj split`, or `jj op restore`, create a checkpoint with `copilot/skills/jj/scripts/jj-checkpoint`.
4. When describing results, call out any history-shaping jj operation explicitly.

## Validation commands

- Always run `nix fmt` after Nix edits.
- Home Manager changes: `nix build .#homeConfigurations.schlich.activationPackage`
- WSL host changes: `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
- Desktop host changes: `nix build .#nixosConfigurations.desktop.config.system.build.toplevel`
- System smoke coverage when relevant: `nix-build system/system_test.nix`

## Flake-editing guidance

1. Preserve flake output names and option paths that other tooling depends on.
2. Treat `home.nix` as the active Home Manager entrypoint unless you intentionally rewire the flake.
3. Keep module structure shallow when editing under `modules/`.
4. Prefer Nushell-oriented command examples and jj-oriented version-control guidance.

## Repository notes

Prefer jj over git for all write operations. Read-only git inspection is acceptable, but commits, rebases, resets, switches, pushes, and other history edits should go through jj. Before risky jj history surgery such as rebase, squash, abandon, split, or op restore, record a checkpoint with `copilot/skills/jj/scripts/jj-checkpoint`. Run `nix fmt` after Nix edits. Build `.#homeConfigurations.schlich.activationPackage` for home-level changes, `.#nixosConfigurations.nixos.config.system.build.toplevel` for the WSL host, and `.#nixosConfigurations.desktop.config.system.build.toplevel` for desktop system changes. Use `nix-build system/system_test.nix` when system-level behavior needs the smoke test.
