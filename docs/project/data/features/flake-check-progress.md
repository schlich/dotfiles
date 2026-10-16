---
type: feature
description: Show per-attribute evaluation and build progress in the manual flake-check job.
stage: implemented
generated:
  by: codex/gpt-6-luna
  at: 2026-10-16T19:26:00Z
sources:
- id: flake-check-workflow
  resource: .tangled/workflows/flake-checks.yml
  title: Manual flake-check workflow
---

# Streamed flake-check progress

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
