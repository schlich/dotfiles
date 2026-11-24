---
type: hub
description: Feature design documents, each carrying its lifecycle stage.
stage: living
generated:
  by: human:author
  at: 2026-08-01T00:00:00Z
---

# ✨ Features

*One document per feature in `features/<slug>.md`, from first proposal to
deprecation — the `status` frontmatter (`proposed` → `accepted` → `implemented`,
terminal `deprecated`/`cancelled`) carries the lifecycle, so the list stays
flat. Group with `##` headings once it outgrows a single list.*

jj-normalize, the change-graph normalizer that began here as jj-graph, is now
a flake input: it lives in
[github:schlich/jj-graph](https://github.com/schlich/jj-graph/tree/main/crates/jj-normalize),
with its feature, plans, and decision under that crate's `docs/`, and jj runs
it as `jj normalize`.

[Reactive CI and Nix dashboard](features/ci-nix-dashboard.md)

[Stately MCP tools](features/stately-mcp.md)

[Streamed flake-check progress](features/flake-check-progress.md)

[Traces of ci landings](features/ci-traces.md)
