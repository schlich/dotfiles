---
type: feature
description: An interactive local and homelab-tailnet view of CI topics, runs, Nix generation, and trunk activity.
stage: accepted
generated:
  by: codex/gpt-6-luna
  at: 2026-10-16T18:24:00Z
sources:
- id: ci-flake-input
  resource: flake.nix
  title: CI tool input and package
---

# Reactive CI and Nix dashboard

## Purpose

Give the operator one live, read-only view of the CI tower and the Nix
generation running on the host that provides the dashboard.

## Behaviour

- A local Node server polls `ci tower . --json` on request and serves the
  dashboard plus a cached JSON snapshot; the browser refreshes automatically and
  also offers a manual refresh.
- On homelab, NixOS runs the packaged server as `schlich`, reading the
  `/home/schlich/dotfiles` JJ checkout. The service stays bound to loopback and
  Tailscale Serve exposes HTTPS on port 8443 to tailnet devices.
- The dashboard summarizes host generation and release verification, topic state
  and locks, recent CI runs and phases, and trunk history.
- The first screen is information-dense: five live KPIs, a 24-hour run
  histogram, an outcome donut for the snapshot, and a stacked view of topic
  stages. Emoji labels and color-coded shapes make each measure easy to scan.
- Search, status filters, expandable run detail, a theme toggle, and direct JSON
  import make the snapshot useful without adding CI write operations.
- The page reports connection errors and snapshot age while retaining the last
  successful data.

## Edge cases

- `ci tower` may fail or take time; show the last good snapshot as stale and
  explain the local feed error.
- JSON collections can be arrays or keyed objects. Normalize both forms.
- The HTML can be opened without the server; provide a local JSON import path
  and explain how to start the live feed.
- Keep wide run and trunk data contained on small screens while preserving the
  main summary and run list.

## Open questions

- The view covers the host serving it. Fleet-wide host polling and CI write
  actions remain out of scope.
