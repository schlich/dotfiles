# Repository workflow

## Development

- Keep project tooling and checks declarative in `flake.nix`.
- Treat application-owned, self-mutating configuration as runtime state. Use a
  package wrapper or command-line override for immutable defaults instead of
  Home Manager-managed dotfiles; reserve Home Manager for files the
  application does not rewrite.
- Target only `x86_64-linux` for all flake outputs unless explicitly requested to support additional architectures.
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
- Keep one topic and one stable JJ change ID per Codex task. Rewrite that change
  throughout the task; publication does not create a follow-up change.
- Use a dedicated JJ workspace per concurrent task and open it as a local
  project. Do not use the desktop Git worktree or commit actions.
- Use `path:` references such as `nix develop path:.` to include new files in
  local flakes without Git staging. Path sources also include ignored files.
- Where available, use `jj-ci rebase`, `jj-ci publish`, and `jj-ci finish` for
  updating, publishing, and closing out the topic. Archive only after verified
  delivery of the current head to main.
- Do not push directly to `main`; publish a change bookmark and merge it through
  a pull request.
