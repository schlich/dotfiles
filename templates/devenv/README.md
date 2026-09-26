# Project

## Start

```nu
direnv allow
```

Without direnv, use `devenv shell`.

## Run

```nu
devenv up
```

`devenv up` starts the processes and services declared in `devenv.nix`.

## Checks

```nu
nixfmt devenv.nix
devenv test
prek run --all-files
```

The environment includes Nushell, Jujutsu, GitHub CLI, `prek`, `nixfmt`, and
the usual file-search and diff tools. Enable languages, services, processes,
and tasks in `devenv.nix` as the project takes shape.
