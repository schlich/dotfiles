---
type: architecture
description: jj-graph computes a change graph's normal form directly and applies it as one verified operation, instead of the guide's iterative crawler.
generated:
  by: claude-code/opus-5
  at: 2026-10-19T21:40:00Z
sources:
- id: spec
  resource: tools/jj-graph/spec/Normalize.qnt
  title: Normal form specification
- id: apply-spec
  resource: tools/jj-graph/spec/Apply.qnt
  title: Apply protocol specification
---

# jj-graph normal form

## Decision

The normal form is a function, not a process: the transitive reduction of the
closure of the requirements (references, same-symbol and same-file order,
anchors) and the base each change was built on. jj-graph computes it, then
places changes with `jj rebase -s` in a topological order of it.
`spec/Normalize.qnt` states it, checks soundness, minimality, idempotence,
uniqueness, and the plan by simulation and TLC, and `tests/conformance.rs`
replays its traces against the Rust core.

The plan runs on a detached chain of operations and is integrated with
`jj op integrate` only after jj-graph re-reads the result and finds the planned
parents, no new conflict, unchanged anchor and working-copy trees, and unchanged
per-change diffs, and only if the head operation has not moved
(`spec/Apply.qnt`).

Splits (Pass 2 and the refactor precursor) are planned from a change's diff
before jj runs: the plan holds each file's text in the new change, assembled
from whole top-level syntax units and checked to parse and to hold exactly what
it moves. jj-graph's diff editor only lays the plan out, and the change's
symbols come from the same plan, so the graph hoists exactly what the split
moves. Pass 2 moves only new contracts.

## Boundaries

- Only mutable changes are rewritten; trunk commits are bases a change keeps.
- A hoisted precursor holds new contracts only: one that changed or removed a
  contract would break the code still written against the old one.
- Anchors (working copies, changes with children outside the scope) keep their
  trees; growth that soundness forces is refused unless allowed.
- Requirements over-approximate dependencies by simple names and per-file order,
  so a normalization is safe and may be less parallel than possible.

## Alternatives considered

- **The guide's four-pass crawler.** Its Pass 3
  (`jj rebase -r v -d "parents(u)"`) strips a dependency from `v`'s descendants,
  and a crawler of safe local moves can stop short of the normal form (both
  shown by tests in the specification).
- **Rebasing with `-r`.** It re-parents descendants on every move, so a change
  placed earlier can move again; `-s` keeps placed changes put.
- **Applying commands one by one with rollback.** Other workspaces would see
  half a plan, and rolling back with `jj op restore` would also undo their
  operations.
- **Line-level contract hoisting.** A line diff can align lines of different
  items (closing braces), which leaves the contract part malformed; hoisting
  assembles whole items.
- **Hoisting every contract change, and matching items by name and occurrence.**
  An adversarial review found precursors that did not parse (multi-line imports
  split by line), did not compile (an edited import next to the old one, a
  changed trait over its old implementations), or lost items (overloads, items
  sharing a line). Unit-level assembly of new contracts, with one import per
  name they use, fixes each; the property tests in `tests/split_properties.rs`
  cover every language.
