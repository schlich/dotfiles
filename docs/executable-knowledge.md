# Executable knowledge

Markdown is the durable truth. IWE supplies semantic structure. marimo
supplies executable structure. marimohub supplies the runtime. Nix supplies
the environment. jj supplies history. HTML is a view.

The working proof of concept is [`workbench/`](../workbench/README.md). This
note records what upstream supports today (checked 2026-10-03), the design
choices layered on top, and what is still open.

## Responsibilities

| Layer     | Owns                                                     | Here                                         |
| --------- | -------------------------------------------------------- | -------------------------------------------- |
| Markdown  | Canonical knowledge and executable source                | `workbench/knowledge/**/*.md`                |
| IWE       | Identity, links, inclusion graph, schemas, retrieval     | `.iwe/`, `iwe` CLI, `iwec` MCP, `iwe_bridge` |
| marimo    | Reactive cells, analysis, controls, computed results     | `python {.marimo}` fences                    |
| marimohub | Sessions, apps, jobs, remote access; operational history | `services.marimohub` (`modules/nixos/`)      |
| Nix       | Environments, images, server, versions                   | `workbench/environments/`, `flake.lock`      |
| jj        | Source history and review                                | the repository                               |

Three graphs describe a result: the IWE graph (what knowledge exists and how
it relates), the marimo graph (which cells produced it), and the Nix closure
(which software ran them). The demo shows all three: it asks IWE about
itself, computes reactively, and reports the store path of its interpreter.

## Verified against upstream

### marimo 0.24.2 (nixpkgs pin; PyPI has 0.25.1)

- Markdown notebooks mark code with `python {.marimo}` fences, and
  `sql {.marimo query="df"}` for SQL. A file is a notebook only if it has a
  marimo fence or a `marimo-version` key, so plain notes are never notebooks.
  Prose between fences becomes `mo.md` cells and is written back verbatim.
- **The editor save preserves arbitrary frontmatter.** It re-reads the YAML
  from disk and merges marimo's keys over it. On the demo, a save that edited
  one cell changed only that line once `marimo-version` was pinned.
  `marimo-version` is rewritten on every save, and `title` is added if
  missing. The workbench check asserts this.
- **`marimo convert` and IR round-trips are not safe.** They keep only
  string-valued frontmatter keys: lists, maps, and numbers are dropped.
  Never route knowledge documents through them.
- `marimo check`, `export html`, `edit`, and `run` accept `.md`. Upstream
  states Markdown notebooks cannot be imported as modules or run as scripts.

### IWE 0.24.2 (pinned; 0.25.0 released 2026-10-02)

- The documented integration surfaces are the CLI and the MCP server
  (`iwec`). The `liwe` library is not API-stable. `iwe_bridge` therefore
  shells out to `iwe … -f json` and keeps no index of its own.
- `iwe find -k KEY -f json` returns the frontmatter plus `references`,
  `includedBy`, and the other edges. The YAML filter (`--filter`) is marked
  experimental upstream.
- Schemas (`.iwe/schemas/NAME.yaml`, JSON Schema for frontmatter) bind by
  key glob in `config.toml`, not by a `type` field. The schemas here pin
  `type` so the two agree.
- IWE keeps arbitrary frontmatter keys. Its writer reflows paragraphs and
  writes fences as ` ``` python {.marimo} `. marimo parses that form into
  identical cells, which the round-trip test asserts. The two tools differ
  only in byte style, so do not run a workspace-wide `iwe normalize` over
  executable documents; `iwe normalize -k KEY` is safe but produces churn.
- 0.25.0 renames `[library]` to `[workspace]` and rewrites `config.toml` in
  place on first read. `iwe_bridge` accepts both forms.

### marimohub 0.4.14

- An Apache-2.0 TypeScript server, configured only with `MARIMOHUB_*`
  variables. Its releases ship `marimohub-linux-x64`, a Node
  single-executable that unpacks its bundle into `MARIMOHUB_SEA_CACHE_DIR`.
  nixpkgs does not package it. The package here patches that binary's ELF
  interpreter; the build runs `--version` to prove it starts.
- Storage: `s3`, `gcs`, `azure`, `fs`, `r2`, `memory`, or an external
  `library`. There is no database: the object store holds catalog, versions,
  and snapshots. `fs` is single-replica and needs one filesystem for atomic
  renames.
- Compute: `coreweave`, `wandb`, `modal`, `e2b`, `fargate`, `kubernetes`,
  `docker`, `podman`, `local`, `cloudflare`, `none`, or an external Node
  `library` adapter. `local` is documented as development-only, with no
  isolation. `podman` supports rootless Podman and is single-host.
- The Podman adapter runs `podman run -d … IMAGE sleep infinity`, then drives
  the kernel with `podman exec … sh -lc`: `uv sync --inexact` into
  `UV_PROJECT_ENVIRONMENT`, then `uv run --no-sync marimo edit`. The image
  must provide `uv`, `python3`, `sh`, coreutils, a writable `/workspace`, and
  a pinned marimo (0.23.10 or 0.24.x).
- Auth: `oidc`, `proxy-header` (including Tailscale Serve's
  `Tailscale-User-Login`), `cloudflare-access`, or `dev`.
- Hub-native notebooks are `notebook.py` plus `pyproject.toml`. **`.md` entry
  notebooks are only supported through Git-synced sources** (`push` or
  `pull`), which are read-only, versioned, and marked work in progress.
  Pull mode needs a GitHub App. Push mode accepts an archive and token from
  any CI.

## Design choices (experimental)

- **One file, two readers.** The demo's frontmatter carries IWE's keys
  (`type`, `status`, `project`) and the workbench's `environment`. marimo
  owns only `title` and `marimo-version`. Executable cells are plain marimo
  fences. No second representation is generated.
- **Environments are named in frontmatter, defined in Nix.**
  `environments/NAME.nix` adds Python packages and tools to a base of
  marimo, `iwe_bridge`, and IWE. Each environment builds a runtime, a sandbox
  image, and a manifest entry. `workbench` resolves a document's
  `environment` against the manifest and runs marimo from that store path.
- **Nix-built sandbox images.** `dockerTools.streamLayeredImage` produces a
  marimohub-compatible image whose tag is its Nix output hash. A writable
  `--system-site-packages` virtualenv over the store Python satisfies uv's
  environment contract while every pre-installed package resolves to
  `/nix/store`. `UV_OFFLINE=1` makes a dependency missing from the closure
  fail rather than install from PyPI. Images are `podman load`ed into the
  hub account before it starts. No registry is involved.
- **Isolation stays in Podman.** The dev shell and `workbench edit` are not
  sandboxes. marimohub's `local` backend is excluded from the module.
- **The repository stays authoritative.** marimohub receives landed commits
  through push sync (`workbench sync`, a `git archive` of `workbench/` plus
  the commit ID). Its versions and session snapshots are operational history.
  Edits made in the hub reach the repository only as ordinary commits:
  export or copy the file back, then review it with `jj diff`. Hub-side
  source-control publishing (a GitHub App) is the upstream path for
  automating that and is not configured.
- **Deployment follows the repository's pattern.** `services.marimohub` is a
  generic module, `workbench-hub.nix` specializes it, and the `marimohub` Den
  aspect carries server policy metadata. No host includes it yet. The
  `marimohub-homelab-evaluation` check proves the homelab evaluates with it,
  as `nixbot-homelab-evaluation` does for nixbot.

## Not yet verified

- The hub and a Podman kernel have not been run end to end; this
  environment has neither Podman nor a NixOS host. The module evaluates, the
  image builds, and the binary starts. The first real start should confirm
  rootless Podman under a lingering system user, `uv sync` against the
  `--system-site-packages` venv, and the notebook bridge install.
- Whether `uv sync --inexact` reinstalls packages already visible from the
  store when a synced notebook's `pyproject.toml` declares them. With
  `UV_OFFLINE=1` that would fail rather than drift.
- Whether a synced `.md` entry notebook keeps its frontmatter through hub
  edit sessions (hub saves go through the same marimo serializer, so it
  should).

## Open questions and upstream limits

- **Environment binding in the hub.** marimohub selects an image per notebook
  in its own metadata and ignores frontmatter. A sync step could set the image
  from `environment`, but the image-selection API has not been checked.
- **A Nix-native compute backend.** marimohub's external `library` compute
  adapter is the documented extension point. A `compute-nix` adapter could
  start each kernel as a transient systemd unit (DynamicUser, a private
  writable workspace, read-only `/nix/store`, cgroup limits, namespaces)
  from a realized closure, with no image or uv step. It is not built: rootless
  Podman already gives an isolation boundary through documented interfaces,
  and the adapter API should first be read in `development_docs/ports.md`.
- **Write-back.** The hub's versions are immutable snapshots of the source.
  Turning a hub edit into a JJ change is manual today.
- **IWE 0.25.** Bump deliberately. It rewrites `config.toml` on first read,
  and unknown keys in `tree`, `export`, and `update -k` become errors.
- **Agents.** Agents should use `iwec` (MCP) for graph operations. Wiring a
  workbench-scoped IWE MCP server into the AI client modules is a follow-up.
- **marimo Studio** (released 2026-10-01) builds audience-specific views of a
  notebook. It is a candidate for the "derived presentation" layer and is not
  integrated.
