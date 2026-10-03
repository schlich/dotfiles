---
type: concept
---

# Executable knowledge

A document is executable knowledge when one Markdown file is at once a
readable explanation, a typed node in the knowledge graph, and a reactive
program whose results are recomputed from its own source.

The file stays canonical. IWE reads its frontmatter and links; marimo reads
its `python {.marimo}` fences; everything rendered from it — HTML, apps,
dashboards — is a derived view.

See [Nix closure provenance](nix-closure-provenance.md) for the third graph
that records which software produced a result.
