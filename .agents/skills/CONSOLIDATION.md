# Agent Skill Consolidation

This repository currently contains the largest concentration of reusable user-level skills, so it is the staging canonical home until a dedicated private `schlich/skills` repository can be created.

## Policy

- Keep portable, user-level skills canonical here.
- Keep repository-specific workflow skills in the repository they govern.
- Do not copy a skill out of a project when it depends on project-local scripts, docs, fixtures, or conventions unless those dependencies move with it.
- Track provenance before migration so project-local copies can later become thin wrappers or references.
- Prefer one canonical implementation over divergent copies.

## Current inventory

### Canonical / user-level skills already in this repo

- `.agents/skills/jj/SKILL.md`
- `.agents/skills/rlm/SKILL.md`
- `.agents/skills/jj-ci/SKILL.md`
- `.agents/skills/nushell/SKILL.md`
- `.agents/skills/async-command-runner/SKILL.md`
- `.agents/skills/nushell/plugin-builder/SKILL.md`
- `.agents/skills/nushell/text-processing/SKILL.md`
- `.agents/skills/token-budget-controller/SKILL.md`

### Repo-specific; keep local

- `schlich/motif:.opencode/skills/http-nu/SKILL.md`
- `schlich/starfish-projects:.agents/skills/ui-playwright/SKILL.md`
- `schlich/dotfiles:copilot/plugins/jj-flake-vigilance/skills/jj-flake-evolution/SKILL.md`
- `schlich/dotfiles:copilot/plugins/project-plugin-factory/skills/project-plugin-factory/SKILL.md`

### Portable candidates needing dependency inspection before migration

- `schlich/nix-observatory:.agents/skills/metavr-cli/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-vr-debug/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-iwsdk-webxr/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-quest-verify-first/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-immersive-designer/SKILL.md`
- `schlich/starfish-projects:.codex/skills/storylite-create-story/SKILL.md`

## Next canonicalization step

When a dedicated private `schlich/skills` repository exists, move the portable set as complete skill directories, preserving scripts, references, docs, fixtures, and metadata. Then leave repo-local wrappers only where project context is genuinely required.
