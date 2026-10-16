---
type: feature
description: Every ci dispatch and landing becomes an OpenTelemetry trace in the local viewer, so slow landings can be broken down by attempt, phase, check, and lock wait.
stage: implemented
generated:
  by: claude-code/opus-5.5
  at: 2026-10-16T21:20:00Z
sources:
- id: ci-traces-module
  resource: modules/programs/ci.nix
  title: ci package carrying the traces endpoint
- id: viewer-module
  resource: modules/nixos/nix-observability.nix
  title: Local OpenTelemetry viewer and its ci endpoint
---

# Traces of ci landings

## Purpose

Show where a landing's time goes. On 2026-10-16, 124 dispatch and land runs
since 2026-10-07 had taken 18.1 hours. A quarter of that time was spent waiting
for another topic's local checks. Twenty runs started over 32 times because main
moved. Clearance time was almost all Nix evaluation, not building.

## Behaviour

- On a host with the nix-observability service, the ci package carries
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` for the local viewer
  (<http://127.0.0.1:8000>). Only ci exports traces; other programs that read
  `OTEL_EXPORTER_OTLP_*` do not.
- Each `ci dispatch` and `ci land` sends its trace when it ends. The trace has a
  span for the run, one per attempt, one per phase and check, and one per wait
  for another topic's local checks.
- `ci trace export` sends runs recorded earlier, from the ci log and the ci MCP
  job store. The job store goes back to 2026-10-07; that history was sent on
  2026-10-16.

## Scenario

### Scenario: Find why a landing took an hour

- **WHEN** a `ci land` starts over several times
- **THEN** its trace in the viewer shows each attempt, how long each attempt
  waited for local checks, and how long each phase took
