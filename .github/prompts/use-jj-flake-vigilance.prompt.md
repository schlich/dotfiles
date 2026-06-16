---
description: 'Inspect the current jj/Nix worktree, reconcile pending flake work, and finalize validated changes in schlich/dotfiles.'
agent: project-specialist
---

# Reconcile the jj-first flake workflow

Work on: ${input:task:Describe the change, question, or repo state to reconcile}

## Required workflow

1. Use the `project-specialist` custom agent for orchestration.
2. Start with `jj status`, `jj diff`, and `jj log` so the current repo state drives the work: inspect pending changes, missing descriptions, and whether existing flake work should be continued, validated again, or finalized before making new edits.
3. Apply the repository guidance from `.github/instructions/jj-flake-vigilance.instructions.md`, reuse the generated `jj-flake-evolution` skill, and honor `.github/hooks/jj-flake-vigilance.json`.
4. Use `jj`, not mutating `git`, for repository write operations.
5. For implementation or repo-reconciliation requests, derive or tighten a concise jj change description so `@` matches the actual scope before finalizing.
6. Preserve unrelated user changes. Only edit, describe, validate, or commit the work that belongs to the request or the already-pending flake work you are explicitly reconciling.
7. Create a `copilot/skills/jj/scripts/jj-checkpoint` checkpoint before risky jj history edits.
8. Prefer existing project patterns over introducing new structure.
9. Use the repository's real validation commands before concluding, choosing the smallest one that fits the touched surface:
   - `nix fmt`
   - `nix build .#homeConfigurations.schlich.activationPackage`
   - `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
   - `nix build .#nixosConfigurations.desktop.config.system.build.toplevel`
10. If the relevant formatting and validation succeed and the current working change represents completed implementation work, finalize it with `jj commit`; otherwise leave it uncommitted and explain what is still missing.
11. If the user wants the change shipped remotely, make sure the committed revision has a bookmark, push it to `origin`, and open or update a pull request against `main`.
12. If you create or reuse a non-`main` bookmark for that publication flow, treat it as implicit PR intent and open or update the PR immediately after pushing without waiting for a separate prompt.
13. Treat GitHub Actions as the comprehensive remote gate: `.github/workflows/nix-ci.yml` should cover the broader formatting/build/test matrix, and the `automerge` label should be the only path to requesting auto-merge for a non-draft same-repository PR.
