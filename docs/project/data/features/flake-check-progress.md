---
type: feature
description: Show per-attribute evaluation and build progress in the manual flake-check job, retired with the spindle that ran it.
stage: deprecated
status: deprecated
generated:
  by: claude-code/opus-5.5
  at: 2026-10-19T19:20:00Z
sources:
- id: github-trunk
  resource: data/architecture/github-trunk.md
  title: The trunk move that retired the spindle
---

# Streamed flake-check progress

*Deprecated 2026-10-19: the homelab spindle and
`.tangled/workflows/flake-checks.yml` were retired. `ci land`'s local clearance
and GitHub Actions build the same checks.*

## Purpose

Make it clear which flake checks are being evaluated or built while the manual
flake-check job is running.

## Behaviour

- The workflow streams `nix-fast-build` JSON-line events as checks are evaluated
  and built, so the job log identifies each attribute and its result as work
  proceeds.
- The check set, cache behavior, and evaluator memory limits remain the same.

## Scenario

### Scenario: Follow a manual flake-check run

- **WHEN** the manual workflow builds `checks.x86_64-linux`
- **THEN** its log shows per-attribute evaluation and build events as they
  arrive
