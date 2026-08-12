# Repository workflow

## Development

- Keep project tooling and checks declarative in `flake.nix`.
- Enter the environment with `direnv allow` or `nix develop`.
- Prefer Nushell for scripts and structured data pipelines. Use `.nu` files and
  `#!/usr/bin/env nu` for executable scripts.
- Format with `nix fmt` and validate with `nix flake check` and
  `prek run --all-files`.

## Version control

- Use Jujutsu for changes, descriptions, bookmarks, rebases, conflict
  resolution, and pushes. Use Git only for read-only interoperability.
- Start work by inspecting `jj status`, `jj diff`, and `jj log`.
- Preserve unrelated working-copy changes.
- Keep changes small and give each one a concise description with `jj desc`.
- Do not push directly to `main`; publish a change bookmark and merge it through
  a pull request.
