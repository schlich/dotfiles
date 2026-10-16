---
type: plan
description: Implement, review, and deploy a reactive dashboard for live CI tower and Nix host data.
created: 2026-10-16
generated:
  by: codex/gpt-6-luna
  at: 2026-10-16T18:24:00Z
sources:
- id: ci-flake-input
  resource: flake.nix
  title: CI tool input and package
---

# Build a reactive CI and Nix dashboard

## Context

The repository already exposes `ci tower --json`, but it requires a terminal and
presents its data as a snapshot. The operator chose a live local feed for v1.

## Approach

Use a dependency-free Node loopback server to expose the existing tower JSON
read-only. Build the dashboard as a self-contained HTML file that polls that
endpoint, shows current host and CI state, and supports a saved JSON snapshot
when the server is unavailable. Keep its opening view information-dense with a
compact host line, five KPIs, and charts for run activity, outcomes, and topic
stages instead of introductory hero copy. Package the same service for homelab,
where Tailscale Serve publishes it only to the tailnet on HTTPS port 8443.

## Implementation Steps

### Task

Build the local adapter and responsive dashboard, then review both wide and
narrow layouts and exercise the primary controls in the browser.

**Files:** `tools/ci-dashboard/index.html`, `tools/ci-dashboard/server.mjs`,
`modules/nixos/homelab.nix`, `docs/project/data/features/ci-nix-dashboard.md`,
`docs/project/data/architecture/ci-nix-dashboard.md`.

- [x] Implement the read-only local server and dashboard.
- [x] Review live data, controls, errors, and narrow layout in a browser.
- [x] Package the dashboard and add a homelab systemd service using the live JJ
  checkout.
- [ ] Deploy the service after delivery approval; verify the tailnet-only HTTPS
  endpoint.

## Spec changes

Accepted feature:
[Reactive CI and Nix dashboard](../features/ci-nix-dashboard.md).

## Verification

Use the local tower feed and a browser review. Repository instructions prohibit
build and test validation unless explicitly requested.

## Out of scope

- Fleet-wide remote host monitoring.
- CI dispatch, landing, host switching, or other write actions in the dashboard.

## Key references

- 2026-10-16 — [CI package input](../../../../flake.nix#L166) and tool binding
  (`flake.nix#L195`).
