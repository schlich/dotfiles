# Repository workflow

## Development

- Keep project tooling, languages, services, processes, and tasks declarative
  in `devenv.nix`. Pin inputs in `devenv.yaml`; `devenv.lock` records them.
- Keep machine-specific overrides in the ignored `devenv.local.nix` and
  `devenv.local.yaml`.
- Treat application-owned, self-mutating configuration as runtime state. Use a
  package wrapper or command-line override for immutable defaults instead of
  Home Manager-managed dotfiles; reserve Home Manager for files the
  application does not rewrite.
- Target only `x86_64-linux` unless explicitly requested to support additional
  architectures.
- Enter the environment with `direnv allow` or `devenv shell`, and start
  processes and services with `devenv up`.
- Prefer Nushell for scripts and structured data pipelines. Use `.nu` files and
  `#!/usr/bin/env nu` for executable scripts.
- Format with `nixfmt` and validate with `devenv test` and
  `prek run --all-files`.

## Version control

- Use Jujutsu for changes, descriptions, bookmarks, rebases, conflict
  resolution, and pushes. Use Git only for read-only interoperability.
- Start work by inspecting `jj status`, `jj diff`, and `jj log`.
- Preserve unrelated working-copy changes.
- Keep one coherent topic per Codex task. Use one stable JJ change ID for a
  single deliverable, but use a small stack when the task contains multiple
  deliverables that should be split. Rewrite each in-scope change throughout
  the task; publication does not create unrelated follow-up changes.
- Use a dedicated JJ workspace per concurrent task and open it as a local
  project. Do not use the desktop Git worktree or commit actions.
- Start each workspace from `main@origin`, rebase after trunk advances and
  before review or queue updates, and never share a mutable topic worktree.
- Where available, use `jj-ci rebase`, `jj-ci publish`, and `jj-ci finish` for
  updating, publishing, and closing out the topic. Archive only after verified
  delivery of the current head to main.
- Before implementation or publication, inspect for mixed deliverables and
  split them into separate JJ changes. Use a parent/child chain only when a
  later change depends on the earlier change to build, test, or make sense;
  use sibling changes when the parts are independently reviewable and can land
  independently. `jj split` creates parent/child changes by default, and
  `jj split --parallel` creates siblings. Check the resulting graph with
  `jj log`, and checkpoint before splitting or other history surgery.
- Do not push directly to `main`; publish a change bookmark and merge it through
  a pull request.
