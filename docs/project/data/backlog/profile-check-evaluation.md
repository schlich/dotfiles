---
type: task
description: Rank the flake checks by evaluation time and memory, with flamegraphs, to decide whether local clearance can evaluate them in parallel.
stage: planned
priority: high
created: 2026-10-16
generated:
  by: claude-code/opus-5.5
  at: 2026-10-16T21:20:00Z
---

# Profile flake-check evaluation

Local clearance spends most of its time evaluating the 20 flake checks, not
building them. ci runs `nix-fast-build --eval-workers 1`, so the checks are
evaluated one at a time. nix-fast-build only reports build events, so nothing
shows which checks are slow to evaluate.

Add an on-demand command that evaluates each check separately with Nix 2.34's
`eval-profiler = flamegraph` and `NIX_SHOW_STATS`. It should produce a ranking
by evaluation time and memory, plus a flamegraph per check. Use the result to
decide whether `--eval-workers 2` fits under the 9 GiB `MemoryMax` of the local
checks unit. See [traces of ci landings](../features/ci-traces.md) for the
measurements that motivated this.
