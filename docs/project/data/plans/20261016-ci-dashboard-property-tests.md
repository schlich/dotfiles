---
type: plan
description: Test the CI dashboard with Hegel properties and a Bombadil exploration, and fix what they find.
created: 2026-10-16
generated:
  by: claude/opus-5.5
  at: 2026-10-17T00:35:00Z
stage: done
completed: 2026-10-16
---

# Test the CI dashboard with Hegel and Bombadil

## Context

The [reactive CI and Nix dashboard](20261016-ci-nix-dashboard.md) shipped with
no tests. Its server reduces GitHub Actions runs and job logs, and reads local
run logs in line-aligned windows; its page polls both and re-renders.

## Approach

Move the server's reductions into `tools/ci-dashboard/feeds.mjs` and state their
contracts as Hegel properties, one per test, with a model of the feed cache and
of a reader following a growing log. Explore the page with Bombadil against the
real server, whose `ci` and `gh` are fakes over a world that keeps changing, and
state the page's invariants as Bombadil properties.

## Implementation Steps

### Task

**Files:** `tools/ci-dashboard/feeds.mjs`, `tools/ci-dashboard/feeds.test.mjs`,
`tools/ci-dashboard/fake/`, `tools/ci-dashboard/checks.nix`,
`tests/bombadil/ci-dashboard.ts`, `tools/ci-dashboard/index.html`, `flake.nix`,
`modules/nixos/homelab.nix`.

- [x] Hegel properties for every export of `feeds.mjs`, an adversarial review of
  the contract, and a scale probe (`ci-dashboard-feeds`, gating).
- [x] Fake `ci` and `gh`, and a Bombadil specification for the page
  (`ci-dashboard-bombadil`, a remote check).
- [x] Fix what the properties found.

## Verification

The properties found, and the change fixes:

- `jobLog` dropped a line starting exactly at its opening window, showed an
  empty log when no line started within it, read a replaced log from its last
  window instead of its start, and split characters and color codes across the
  pieces of a line longer than a read.
- `cachedFeed` retried on every request while collection failed, and lost its
  stale fallback for a failure that was not an `Error`.
- `summarizeJobs` listed cancelled jobs, which the page draws as failures.
- `workflowHeader` skipped a header after a byte-order mark.
- The page showed lost runs as passed, collapsed open run details on each
  refresh, and re-read a log in a tight loop while its last line was still being
  written.

## Out of scope

- Moving the Bombadil exploration into the gating `checks` once it has a record.
- The page's overlapping refreshes and its permanent caching of a failed GitHub
  log fetch.

## Key references

- 2026-10-16 — [feeds.mjs](../../../../tools/ci-dashboard/feeds.mjs),
  [feeds.test.mjs](../../../../tools/ci-dashboard/feeds.test.mjs),
  [ci-dashboard.ts](../../../../tests/bombadil/ci-dashboard.ts).
