---
description: 'Routing and repository guidance for using the generated Copilot plugin in schlich/dotfiles flake workflow'
applyTo: 'flake.nix,flake.lock,home.nix,configuration.nix,system/**/*.nix,modules/**/*.nix,**/*.nu,copilot/**/*.md,.github/**/*.{json,md,yml}'
---

# JJ-first flake evolution guide

This repository uses a generated Copilot customization stack with distinct responsibilities for agents, skills, prompts, and instructions.

## Placement

- Customization scope: project-specific
- Host repository: project repo at /home/nixos/.config/home-manager
- Hooks: .github/hooks/jj-flake-vigilance.json
- GitHub remote: `origin https://github.com/schlich/dotfiles.git`
- Default PR base: `main`

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

## Change-description policy

1. Start by checking `jj status`, `jj diff`, and `jj log` so the current repo state informs whether you are extending existing work, validating it again, or starting a fresh edit.
2. For implementation or repo-reconciliation requests, derive a concise jj change description from the user's requested outcome instead of asking for a separate summary.
3. Apply that draft description to the current working change with `jj describe` as soon as the intended change is clear.
4. If the actual implementation scope shifts, tighten the description before finalizing the change so it reflects what landed rather than the original guess.
5. Preserve unrelated user changes; only commit work that matches the active request or the in-scope pending change you are reconciling.
6. Only finalize the change with `jj commit` after `nix fmt` and the smallest relevant build or test command succeed. If validation fails, keep the change uncommitted and surface the failure clearly.

## Validation commands

- Always run `nix fmt` after Nix edits.
- Home Manager changes: `nix build .#homeConfigurations.schlich.activationPackage`
- WSL host changes: `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
- Desktop host changes: `nix build .#nixosConfigurations.desktop.config.system.build.toplevel`
- System smoke coverage when relevant: `nix build -f system/system_test.nix`

## Remote GitHub policy

1. Treat local validation as the fast gate and GitHub Actions as the comprehensive gate. Once the relevant local checks succeed, rely on `.github/workflows/nix-ci.yml` for the broader formatting, Home Manager, both-host NixOS, and smoke-test coverage.
2. When the user wants a change published, ensure the committed revision has a bookmark, push it to `origin`, and open or update a pull request against `main`.
3. If you create or reuse a non-`main` bookmark to publish work, treat that publication bookmark as PR intent: after `jj git push`, open or update the corresponding pull request against `main` in the same flow without waiting for a separate prompt to do so.
4. The remote publication flow is: `jj status`/`jj diff`/`jj log` -> edit -> local validation -> `jj commit` -> bookmark the committed revision if needed -> `jj git push` -> open or update the PR.
5. Auto-merge is opt-in and label-driven. Only request it for non-draft PRs from the same repository that carry the `automerge` label, and let `.github/workflows/automerge.yml` enable squash-based auto-merge after the required checks are satisfied.
6. Repository settings still need to allow auto-merge and require the `nix-ci` checks on `main`; the repo-local workflow only encodes the policy, not the server-side protection toggle.

## Flake-editing guidance

1. Preserve flake output names and option paths that other tooling depends on.
2. Treat `home.nix` as the active Home Manager entrypoint unless you intentionally rewire the flake.
3. Keep module structure shallow when editing under `modules/`.
4. Prefer Nushell-oriented command examples and jj-oriented version-control guidance.

## Repository notes

Prefer jj over git for all write operations. Read-only git inspection is acceptable, but commits, rebases, resets, switches, pushes, and other history edits should go through jj. Start by checking `jj status`, `jj diff`, and `jj log` so existing work is reconciled instead of accidentally bypassed. Before risky jj history surgery such as rebase, squash, abandon, split, or op restore, record a checkpoint with `copilot/skills/jj/scripts/jj-checkpoint`. For implementation or repo-reconciliation requests, derive a jj change description from the user's requested outcome, apply it with `jj describe`, and keep it current if the scope shifts. Preserve unrelated user changes and only commit the in-scope work. Run `nix fmt` after Nix edits. Build `.#homeConfigurations.schlich.activationPackage` for home-level changes, `.#nixosConfigurations.nixos.config.system.build.toplevel` for the WSL host, and `.#nixosConfigurations.desktop.config.system.build.toplevel` for desktop system changes. Use `nix build -f system/system_test.nix` when system-level behavior needs the smoke test. Once local validation succeeds and the work is committed, publish through `origin`, and if that publication uses a non-`main` bookmark, automatically open or update the matching PR against `main` in the same flow before relying on the repo's CI plus the opt-in `automerge` label. Only finalize with `jj commit` after the relevant formatting and validation succeed.
