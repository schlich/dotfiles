---
type: plan
description: Expose Stately's hosted MCP server to the AI clients configured by the dotfiles flake.
created: 2026-10-16
generated:
  by: codex/gpt-6-luna
  at: 2026-10-16T21:20:00Z
sources:
- id: stately-mcp
  resource: https://stately.ai/docs/packages/mcp
  title: Stately MCP server configuration
- id: mcp-module
  resource: ../../../../modules/tooling/ai/common.nix
  title: Shared MCP server configuration
---

# Add Stately MCP server

## Context

The Stately agent workflow is being added to the CI tooling. Make Stately's MCP
tools available through this flake's shared MCP configuration.

## Approach

Use Stately's hosted HTTP endpoint in the existing shared MCP server set. The
MCP client handles account authentication; this adds no local package or token
to the Nix store.

## Implementation Steps

### Task: Configure the shared remote server

**Files:** Modify `modules/tooling/ai/common.nix`.

- [x] Add the hosted Stately MCP endpoint alongside the shared servers.

## Spec changes

None — this exposes a developer tool to configured clients without changing the
dotfiles product's runtime behavior.

## Verification

Format the flake and validate this project graph. Do not run flake builds or
tests unless the user requests them.

## Out of scope

- Installing the local `@statelyai/mcp` stdio server.
- Supplying or persisting Stately credentials.

## Key references

Verified anchor points (line numbers as of 2026-10-16):

- `modules/tooling/ai/common.nix:48` — shared MCP server definitions.
- `modules/tooling/ai/common.nix:95` — Stately endpoint.
