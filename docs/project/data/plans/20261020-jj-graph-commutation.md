---
type: plan
description: Replace jj-graph's per-file ordering rule with a commutation test asked of jj, with mergiraf as an opt-in structural fallback.
created: 2026-10-20
generated:
  by: claude-code/opus-5
  at: 2026-10-20T16:10:00Z
sources:
- id: readme
  resource: tools/jj-graph/README.md
  title: jj-graph README
- id: commute
  resource: tools/jj-graph/src/commute.rs
  title: jj-graph's commutation test
stage: done
completed: 2026-10-27
---

# Commute jj-graph's edits of one file

## Context

[jj-graph](../features/jj-graph.md) kept two changes that touch the same file in
their original order, so changes editing different functions of one file were
never reordered or made siblings. The [first plan](20261019-jj-graph.md) left
hunk-level commutation out of scope. jj's own rebase merges text, so whether two
diffs commute is asked of jj itself.

## Approach

Model first: `spec/Normalize.qnt` takes `commutes` as an input to `requires`, so
a shared file orders an ancestor pair only when their diffs do not commute. The
Rust core mirrors it, and `load` computes the relation once per read. For each
pair whose order only a shared file keeps, jj-graph runs `jj rebase -r u -A v`
on a detached operation it never integrates. The pair commutes when nothing
conflicts, each change keeps its own patch, and the pair ends on the tree it
started from. Behind `--mergiraf`, mergiraf (GPL-3.0, run as jj's external merge
tool, never linked) resolves what jj's text merge cannot. Its result counts when
each change keeps its edit item by item, as pieces built from the same items
extraction reads. Rejected: computing hunk overlap in jj-graph itself. That
would duplicate jj's merge, and a disagreement with jj would surface only as a
refused plan.

## Implementation Steps

### Task 1: Model

**Files:** Modify: `tools/jj-graph/spec/Normalize.qnt`, `spec/Apply.qnt`.

- [x] `commutes` in the graph, read by `requires`, forgotten for split changes
- [x] Examples: commuting edits fork, untangle an inversion, and release only
  the file
- [x] Invariant that unordering needs commuting, and a witness that some pair is
  released; hoisting's normalizability restated, since splitting forgets what
  commuted

### Task 2: Core and properties

**Files:** Modify: `tools/jj-graph/src/graph.rs`, `tests/graph_properties.rs`,
`tests/conformance.rs`.

- [x] `Graph::commutes`, `commute`, `commutation_candidates`, and hoisting
- [x] Hegel properties: order kept unless commuting, only shared-file
  requirements dropped, candidates exact, either order, hoisting forgets
- [x] Conformance replays `commutes` from the traces

### Task 3: Repository side

**Files:** Create: `tools/jj-graph/src/commute.rs`; Modify: `src/load.rs`,
`src/apply.rs`, `src/jj.rs`, `src/extract.rs`, `src/main.rs`,
`tests/jj_end_to_end.rs`, `default.nix`.

- [x] The swap test on a detached operation, once per load
- [x] `--mergiraf` on `check`, `plan`, and `normalize`: probes, plan resolution,
  anchors given their trees back, and item-by-item checks
- [x] End-to-end: different functions become siblings, overlapping edits stay
  ordered, mergiraf releases what jj cannot
- [x] mergiraf in the package's tests, and named by the wrapper

## Spec changes

None: `data/spec/` has no documents yet; the behaviour is specified in Quint
under `tools/jj-graph/spec/`.

## Verification

``` nu
$env.CARGO_TARGET_DIR = ($nu.temp-path | path join jj-graph-target)
cargo test
quint test --main=NormalizeExamples spec/Normalize.qnt
```

`ci preflight` runs the repository's formatting and hooks.

## Key references

Verified anchor points (as of 2026-10-20):

- [commute.rs](../../../../tools/jj-graph/src/commute.rs) — `commutations`,
  `swap`, `same_edit`
- [graph.rs](../../../../tools/jj-graph/src/graph.rs) — `Graph::requires`,
  `Graph::commutation_candidates`
- [apply.rs](../../../../tools/jj-graph/src/apply.rs) — `merge_structurally`,
  `merged_edit`, `verify`
- [extract.rs](../../../../tools/jj-graph/src/extract.rs) — `pieces`,
  `piece_edit`
- [Normalize.qnt](../../../../tools/jj-graph/spec/Normalize.qnt) — `requires`,
  `EditsOfAFileStayOrderedUnlessTheyCommute`
