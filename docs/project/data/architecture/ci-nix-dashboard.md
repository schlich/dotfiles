---
type: architecture
description: A read-only loopback server adapts ci tower JSON for a reactive dashboard served locally and to the homelab tailnet.
generated:
  by: codex/gpt-6-luna
  at: 2026-10-16T18:24:00Z
sources:
- id: ci-flake-input
  resource: flake.nix
  title: CI tool input and package
---

# CI tower dashboard feed

## Decision

Use a small Node HTTP server bound to `127.0.0.1`. It serves one self-contained
HTML page and a same-origin JSON endpoint backed by `ci tower . --json`. The
browser polls the endpoint; the server caches the latest successful snapshot and
keeps it available if a later collection fails.

The homelab packages the page and server into the NixOS closure and runs the
server as `schlich` against `/home/schlich/dotfiles`. Tailscale Serve publishes
that loopback service over HTTPS on port 8443 for tailnet devices. It does not
use Funnel, open a NixOS firewall port, or replace the existing Funnel on port
443\.

## Boundaries

- The server runs `ci tower` from the configured repository root so it sees the
  current workspace and its sibling workspaces.
- The endpoint is read-only: no dispatch, land, switch, or other mutation is
  exposed.
- On homelab, the view describes that host's local tower data; it is not a
  fleet-wide feed.
- The page has no external runtime dependencies and can load a saved tower JSON
  file when opened directly.
- The local view describes this host and the tower snapshot; it does not imply
  fleet-wide live health.

## Alternatives considered

- **Seeded sample data:** useful for a visual mockup, but it cannot show current
  topics, locks, or runs for this repository.
- **Browser invoking `ci` directly:** browsers cannot safely run local
  executables, so a loopback adapter is required for live data.
