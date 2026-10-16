---
type: plan
description: Launch the configured MCP-NixOS server with Nix instead of uvx.
created: 2026-10-16
generated:
  by: codex/gpt-6-luna
  at: 2026-10-16T22:00:00Z
sources:
- id: mcp-nixos-install
  resource: https://github.com/utensils/mcp-nixos
  title: MCP-NixOS installation documentation
---

# Run MCP-NixOS with Nix

## Context

The configured `uvx` launcher starts a uv-managed process that can keep
`uv cache prune` waiting. MCP-NixOS documents a Nix launcher for Nix users.

## Approach

Use the upstream-supported `nix run github:utensils/mcp-nixos --` command in the
shared MCP configuration, so the server runs from the Nix store without
uv-managed Python processes.

## Implementation Steps

### Task: Switch the MCP launcher

**Files:** Modify `modules/tooling/ai/common.nix`.

- [ ] Replace the `uvx` command with the documented Nix launcher.

## Spec changes

None — this changes the launcher for an existing developer tool.

## Verification

- `nix fmt`.
- `iwe normalize` and `iwe schema validate` from `docs/project/`.

## Out of scope

- Adding `mcp-nixos` to system packages or pinning a separate flake input.

## Key references

Verified anchor points (line numbers as of 2026-10-16):

- `modules/tooling/ai/common.nix:70` — shared Nix MCP server configuration.
