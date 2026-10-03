---

## description: 'Inspect the current jj/Nix worktree, reconcile pending flake work, and finalize validated changes in schlich/dotfiles.' agent: project-specialist

# Reconcile the jj-first flake workflow

Work on: ${input:task:Describe the change, question, or repo state to reconcile}

## Required workflow

1. Use the `project-specialist` custom agent for orchestration.
1. Start with `jj status`, `jj diff`, and `jj log` so the current repo state drives the work: inspect pending changes, missing descriptions, and whether existing flake work should be continued, validated again, or finalized before making new edits.
1. Apply the repository guidance from `AGENTS.md`, reuse the generated `jj-flake-evolution` skill, and honor `.github/hooks/jj-flake-vigilance.json`.
1. Use `jj`, not mutating `git`, for repository write operations.
1. For implementation or repo-reconciliation requests, derive or tighten a concise jj change description so `@` matches the actual scope before finalizing.
1. Preserve unrelated user changes. Only edit, describe, validate, or commit the work that belongs to the request or the already-pending flake work you are explicitly reconciling.
1. Create a `.agents/skills/jj/scripts/jj-checkpoint` checkpoint before risky jj history edits.
1. Prefer existing project patterns over introducing new structure.
1. Use the repository's real validation commands before concluding, choosing the smallest one that fits the touched surface:
   - `nix fmt`
   - `nix build path:.#nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage`
   - `nix build path:.#nixosConfigurations.asus.config.system.build.toplevel`
1. If the relevant formatting and validation succeed and the current working change represents completed implementation work, give it a concise description ending with an `Impact:` trailer; otherwise leave it undescribed and explain what is still missing.
1. If the user wants the change shipped, deliver it with `ci dispatch` and `ci land` as described in `AGENTS.md`. Never merge a GitHub pull request and never push `main` directly.
