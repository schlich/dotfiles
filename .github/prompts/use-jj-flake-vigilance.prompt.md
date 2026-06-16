---
description: 'Use the jj-first flake workflow with automatic git guardrails for schlich/dotfiles.'
agent: project-specialist
---

# Use the jj-first flake workflow

Work on: ${input:task:Describe the change or question}

## Required workflow

1. Use the `project-specialist` custom agent for orchestration.
2. Apply the repository guidance from `.github/instructions/jj-flake-vigilance.instructions.md`.
3. Reuse the generated `jj-flake-evolution` skill for repeatable repository work.
4. Honor the configured hook policy: .github/hooks/jj-flake-vigilance.json.
5. Use `jj`, not mutating `git`, for repository write operations.
6. Create a `copilot/skills/jj/scripts/jj-checkpoint` checkpoint before risky jj history edits.
7. Prefer existing project patterns over introducing new structure.
8. Use the repository's real validation commands before concluding, choosing the smallest one that fits the touched surface:
   - `nix fmt`
   - `nix-build system/system_test.nix`
   - `nix build .#homeConfigurations.schlich.activationPackage`
