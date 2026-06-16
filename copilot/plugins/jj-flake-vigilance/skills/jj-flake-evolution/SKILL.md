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
- turning a concrete flake request into a described, validated jj change with minimal back-and-forth

## Workflow

1. Inspect `flake.nix`, the touched modules, and any affected host entrypoints before editing.
2. Use `jj status`, `jj diff`, and `jj log` to understand current work, decide whether you are extending or reconciling an existing change, and avoid switching to mutating `git`.
3. For implementation or repo-reconciliation requests, draft a concise jj change description from the user request, set it on `@` with `jj describe` once the intended change is clear, and revise it if the actual scope shifts.
4. If the task may require `jj rebase`, `jj squash`, `jj abandon`, `jj split`, or `jj op restore`, run `copilot/skills/jj/scripts/jj-checkpoint` first.
5. Make the smallest coherent change that preserves existing flake output names and host wiring.
6. Run `nix fmt` after Nix edits.
7. Choose validation based on the touched surface:
   - home-level changes: `nix build .#homeConfigurations.schlich.activationPackage`
   - WSL host changes: `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
   - desktop host changes: `nix build .#nixosConfigurations.desktop.config.system.build.toplevel`
   - smoke coverage when needed: `nix-build system/system_test.nix`
8. Preserve unrelated user changes, and only after formatting and the relevant validation command succeed, finalize the in-scope work with `jj commit` using the up-to-date description. If validation fails or the request is analysis-only, stop without committing.
9. Summarize behavioral impact and any jj/history operations explicitly.

## Project notes

Prefer jj over git for all write operations. Read-only git inspection is acceptable, but commits, rebases, resets, switches, pushes, and other history edits should go through jj. Start by checking `jj status`, `jj diff`, and `jj log` so existing work is reconciled instead of skipped. Before risky jj history surgery such as rebase, squash, abandon, split, or op restore, record a checkpoint with `copilot/skills/jj/scripts/jj-checkpoint`. For implementation or repo-reconciliation requests, derive a jj change description from the user's requested outcome, apply it with `jj describe`, and keep it current if the scope shifts. Preserve unrelated user changes and only commit the in-scope work. Run `nix fmt` after Nix edits. Build `.#homeConfigurations.schlich.activationPackage` for home-level changes, `.#nixosConfigurations.nixos.config.system.build.toplevel` for the WSL host, and `.#nixosConfigurations.desktop.config.system.build.toplevel` for desktop system changes. Use `nix-build system/system_test.nix` when system-level behavior needs the smoke test. Only finalize with `jj commit` after the relevant formatting and validation succeed.
