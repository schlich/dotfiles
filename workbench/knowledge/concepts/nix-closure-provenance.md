---
type: concept
---

# Nix closure provenance

Three graphs describe a computed result:

- the IWE graph: what knowledge exists and how it is related;
- the marimo graph: which cells produced the result from which inputs;
- the Nix closure: which exact software environment ran those cells.

An executable document names its environment in frontmatter
(`environment: visualization`). Nix resolves that name to an immutable store
path, so the closure is recorded by the same flake lock that pins the rest of
the system.
