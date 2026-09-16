---
name: jj-flake-evolution
description: Repository workflow for evolving this flake with jj discipline, GitHub publication, and targeted local Nix validation.
---

# JJ-first flake evolution workflow

This skill is the repeatable workflow for **flake and host evolution in schlich/dotfiles**.

## Project context

- Customization scope: project-specific
- Host repository: schlich/dotfiles
- Language: Nix and Nushell
- Workspace root: `.`
- Hooks: .github/hooks/jj-flake-vigilance.json
- GitHub remote: `origin https://github.com/schlich/dotfiles.git`
- Default PR base: `main`
- Build: `nix build .#homeConfigurations.schlich.activationPackage`
- Lint: `nix fmt`

## When to use

Use this skill for routine repository tasks that should follow a repeatable pattern, such as:

- evolving flake inputs or outputs
- changing Home Manager or NixOS modules
- tightening Copilot/Nushell/jj configuration in this repo
- validating whether a proposed change needs host-specific builds or only home-level validation
- turning a concrete flake request into a described, validated jj change with minimal back-and-forth
- publishing a validated jj change to GitHub with a PR and explicitly requested auto-merge

## Workflow

1. Inspect `flake.nix`, the touched modules, and any affected host entrypoints before editing.
2. Use `jj status`, `jj diff`, and `jj log` to understand current work, decide whether you are extending or reconciling an existing change, and avoid switching to mutating `git`.
3. Before implementation or publication, inspect the diff for mixed deliverables. Split unrelated deliverables into separate changes; use parent/child only when the later change depends on the earlier one to build, test, or make sense, and use siblings when both can land independently. `jj split` creates parent/child changes by default; `jj split --parallel` creates siblings. Set explicit descriptions and confirm the graph with `jj log`.
4. For implementation or repo-reconciliation requests, draft concise jj change descriptions from the user request, set them with `jj describe` once the intended scope is clear, and revise them if the scope shifts.
5. If the task may require `jj rebase`, `jj squash`, `jj abandon`, `jj split`, or `jj op restore`, run `.agents/skills/jj/scripts/jj-checkpoint` first.
6. Make the smallest coherent change that preserves existing flake output names and host wiring. Target only `x86_64-linux` for all flake outputs unless explicitly asked for more.
7. Run `nix fmt` after Nix edits.
8. Choose validation based on the touched surface:
   - home-level changes: `nix build .#homeConfigurations.schlich.activationPackage`
   - system changes: `nix build .#nixosConfigurations.asus.config.system.build.toplevel`
9. Treat local validation as the fast gate and Tangled Spindle as the comprehensive gate. The `.tangled/workflows/` pipelines evaluate Home Manager and build the NixOS, Niri, Zellij, and whitespace checks on the PR.
10. Preserve unrelated user changes, and only after formatting and the relevant validation command succeed, finalize the in-scope work with `jj commit` using the up-to-date description. If validation fails or the request is analysis-only, stop without committing.
11. If the user wants the change published, ensure the committed revision has a bookmark, push it to `origin`, and open or update a PR against `main`. When subsequent work depends on CI, run `gh pr checks --required --watch --fail-fast` rather than sleeping and checking again. Queue auto-merge only when the user explicitly requests delivery, using `jj-ci publish --auto-merge`; otherwise leave the PR for review after the required checks pass.
12. If that publication flow creates or reuses a non-`main` bookmark, treat that bookmark push as implicit PR intent and open or update the PR immediately after pushing instead of waiting for a follow-up request.
13. Summarize behavioral impact and any jj/history operations explicitly.

## Project notes

Prefer jj over git for all write operations. Read-only git inspection is acceptable, but commits, rebases, resets, switches, pushes, and other history edits should go through jj. Start by checking `jj status`, `jj diff`, and `jj log` so existing work is reconciled instead of skipped. Before risky jj history surgery such as rebase, squash, abandon, split, or op restore, record a checkpoint with `.agents/skills/jj/scripts/jj-checkpoint`. For implementation or repo-reconciliation requests, derive a jj change description from the user's requested outcome, apply it with `jj describe`, and keep it current if the scope shifts. Preserve unrelated user changes and only commit the in-scope work. Target only `x86_64-linux` for all flake outputs unless explicitly asked for more. Run `nix fmt` after Nix edits. Build `.#homeConfigurations.nixos.activationPackage` for home-level changes, `.#nixosConfigurations.nixos.config.system.build.toplevel` for the WSL host, and `.#nixosConfigurations.desktop.config.system.build.toplevel` for desktop system changes. Once the change is locally validated and committed, publish it through `origin`, and if that publication uses a non-`main` bookmark, automatically open or update the matching PR against `main` before relying on GitHub Actions for the comprehensive checks. When the task needs the CI result, use `gh pr checks --required --watch --fail-fast`, which returns the result to the Copilot session; do not sleep and recheck. Explicit auto-merge then waits on the repo's required checks. Only finalize with `jj commit` after the relevant formatting and validation succeed.
