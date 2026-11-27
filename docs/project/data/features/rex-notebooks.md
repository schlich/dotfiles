---
type: feature
description: Open marimo notebooks from a terminal on asus, served on asus or homelab by servers that keep running in Rex terminals, in the browser on asus.
stage: accepted
generated:
  by: claude-code/opus-5.5
  at: 2026-11-27T01:10:00Z
sources:
- id: module
  resource: ../../../../modules/tooling/terminals/rex-notebooks/default.nix
  title: The notebook commands, notebook-serve, and their check
- id: rex-docs
  resource: https://www.superlogical.com/rex/docs
  title: Rex documentation
---

# marimo notebooks in Rex

## Purpose

Open a marimo notebook from a repository, on asus or on homelab, with one
command in a terminal on asus, and keep its server running in Rex rather than in
that terminal.

## Behaviour

- `notebook open PATH` starts `marimo edit` on the notebook's folder in a Rex
  terminal labelled `nb:FOLDER`, in the session `notebooks` on the host that
  holds the files, and opens its URL in the browser on asus. A later open reuses
  the running server, and a notebook below a served folder opens in that
  folder's server.
- `HOST:PATH`, or `--on HOST`, names a host from `dotfiles.rex.hosts`. That
  host's marimo listens on its own loopback and reaches asus through
  `rex forward open`, which a local terminal labelled `fwd:HOST:LABEL` keeps
  running.
- `notebook-serve` picks the environment on the host: a uv project
  (`uv run marimo`), a pixi project, an allowed `.envrc` whose Python has
  marimo, PEP 723 notebooks (`--sandbox`), or else marimo from nixpkgs.
- `notebook ls`, `notebook log`, and `notebook stop` list, read, and stop the
  servers. `--app` serves a notebook read-only with `marimo run`.

## Scenario

### Scenario: Open a homelab notebook from asus

- **WHEN** `notebook open homelab:Research/whiteboard/notebooks` runs on asus
- **THEN** homelab's Rex server runs marimo in the whiteboard uv project, asus
  forwards its port, and the browser on asus opens the forwarded URL with
  marimo's token
