---
type: plan
description: Use Home Manager mutable settings where declarative app defaults must coexist with app-owned runtime settings.
created: 2026-10-16
generated:
  by: codex/gpt-6-luna
  at: 2026-10-17T02:35:00Z
sources:
- id: hm-opencode
  resource: home-manager:modules/programs/opencode.nix
  title: Locked Home Manager OpenCode module
- id: hm-codex
  resource: home-manager:modules/programs/codex/options.nix
  title: Locked Home Manager Codex options
- id: hm-claude-code
  resource: home-manager:modules/programs/claude-code/default.nix
  title: Locked Home Manager Claude Code module
- id: hm-copilot-cli
  resource: home-manager:modules/programs/github-copilot-cli.nix
  title: Locked Home Manager Copilot CLI module
---

# Adopt Home Manager mutable settings for app-owned config

## Context

Home Manager now exposes `mutableSettings` for several configured clients. The
repository currently passes Codex defaults as CLI overrides and writes OpenCode
settings declaratively. Use the mutable options where they preserve app-owned
files, and document when to use them. This follows the user's request to audit
and update the configuration.

## Approach

Use `programs.codex.mutableSettings` and `programs.opencode.mutableSettings`
because both clients have declared defaults in this repository. Keep Claude Code
and Copilot CLI unchanged: their settings values are empty, so enabling their
options would have no effect. Keep all runtime files writable and let Home
Manager apply only the declared settings. Update the repository guidance to
prefer the option's merge or overlay behavior when the locked module provides
it; wrappers remain the fallback.

## Implementation Steps

### Task 1: Migrate declared client settings

**Files:** Modify: `modules/tooling/ai/codex.nix`,
`modules/tooling/ai/opencode.nix`

- [x] Move Codex defaults from CLI flags to Home Manager settings with mutable
  merging.
- [x] Preserve the wrapped package version for Home Manager's Codex
  compatibility check.
- [x] Enable mutable settings for OpenCode's declarative settings.

### Task 2: Record the configuration placement rule

**Files:** Modify: `AGENTS.md`, `docs/architecture.md`,
`docs/project/data/product.md`

- [x] Document that `mutableSettings` applies defaults without replacing
  app-owned files.
- [x] Keep the wrapper guidance as the fallback when the locked module has no
  merge option.

## Spec changes

None — the effective defaults stay the same; this changes how app-owned settings
persist across launches and activations.

## Verification

- Format the changed Nix modules with the repository's Nix formatter.
- Run `iwe normalize` and `iwe schema validate` for the project graph.
- Do not build or run the Nix checks unless explicitly requested.

## Out of scope

- Enabling no-op `mutableSettings` options for Claude Code or Copilot CLI while
  they declare no settings values.
- Activating Home Manager or changing other apps' configuration.

## Key references

Verified anchor points (line numbers as of 2026-10-16):

- `modules/tooling/ai/codex.nix:8` — Codex configuration wrapper and declared
  defaults.
- `modules/tooling/ai/opencode.nix:43` — OpenCode Home Manager module
  configuration.
- `modules/tooling/ai/claude-code.nix:315` — empty Claude Code settings.
- `modules/tooling/ai/copilot.nix:21` — Copilot runtime config and no declared
  settings.
- `AGENTS.md:45` — application-owned configuration rule.
- `docs/architecture.md:37` — configuration placement architecture.
