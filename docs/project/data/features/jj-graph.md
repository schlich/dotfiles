---
type: feature
description: A command that plans, checks, and normalizes Jujutsu change graphs against what the code defines and references.
stage: accepted
generated:
  by: claude-code/opus-5
  at: 2026-10-19T21:40:00Z
sources:
- id: readme
  resource: tools/jj-graph/README.md
  title: jj-graph README
- id: guide
  resource: https://docs.google.com/document/d/1o1gkaVrv9LoINiwOCi27yAAOd3wiZnjYeulgqCo3tuM
  title: Architectural Graph Engineering in Jujutsu (jj)
---

# jj-graph: change-graph normalization

## Purpose

Implement the guide "Architectural Graph Engineering in Jujutsu": keep a stack's
change graph a mirror of the code's dependency graph, so every change descends
from the changes that define what it uses and from nothing else, and build the
empty "ghost graph" of a design before writing code.

## Behaviour

- `jj-graph check` reports requirement cycles, references to changes a change
  does not descend from, parents nobody needs, redundant parents, and changes
  that mix contracts with implementations; it exits 1 unless the graph is in
  normal form.
- `jj-graph plan` and `jj-graph normalize` compute the unique normal form of
  `trunk()..@` (or `-r`) and reach it with `jj rebase -s`; `--hoist` first moves
  each mixed change's new contracts into a change of their own, and `--cosmetic`
  each change's layout and comment edits. The rewrite lands as one operation,
  only after every check passes.
- `jj-graph symbols` shows what each change defines and references.
- `jj-graph shapes` names contract roots, their sibling realizations, merges
  that use a branch's private internals, and contracts that changed since the
  last version, and runs a check command in each affected tree.
- `jj-graph skeleton` turns a Graphviz diagram into empty changes, and each
  Gherkin feature into a change holding its `.feature` file with one empty
  change per scenario on the components its `@needs` tags name; a rerun creates
  only what is missing and updates what changed.

[tools/jj-graph/README.md](../../../../tools/jj-graph/README.md) documents the
model, the commands, and the limits.

## Edge cases

- A requirement cycle, a first merge of one file's edits, or an anchor that
  would gain changes stops `normalize` with the reason; the last two can be
  allowed with a flag.
- Working copies and changes with children outside the scope keep their trees.
- A concurrent operation before the head check abandons the plan; one that races
  the integration and causes divergence makes jj-graph revert its own.
- A split moves nothing from a file whose part would not parse or would hold
  more or less than it should, and nothing from renamed or binary files.
- A DOT diagram is read as Graphviz's own `dot` reads it; what jj-graph cannot
  use (an undirected graph, a self-loop, a reserved `:` in a node ID) is
  refused.

## Open questions

- Hunk-level commutation would let changes to one file move past each other; the
  per-file rule is conservative.
- A Nushell grammar would let `ci.nu` changes order by symbol instead of file.
