---
type: feature
description: Configured AI clients can connect to Stately's hosted MCP server for state-machine design tools.
stage: implemented
generated:
  by: codex/gpt-6-luna
  at: 2026-10-16T21:48:00Z
sources:
- id: shared-mcp
  resource: ../../../../modules/tooling/ai/common.nix
  title: Shared remote MCP server configuration
- id: stately-mcp-docs
  resource: https://stately.ai/docs/packages/mcp
  title: Stately MCP server
---

# Stately MCP tools

## Purpose

Make Stately's state-machine design tools available to the AI clients configured
by this flake.

## Behaviour

- Shared MCP configuration points clients at Stately's hosted endpoint,
  `https://mcp.stately.ai/mcp`.
- Stately handles MCP authentication in the client. The dotfiles configuration
  does not persist credentials or add a local server package.
