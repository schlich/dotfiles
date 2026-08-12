# Project

## Start

```nu
direnv allow
```

Without direnv, use `nix develop`.

## Checks

```nu
nix fmt
nix flake check
prek run --all-files
```

The development shell includes Nushell, Jujutsu, GitHub CLI, `prek`, Nix
language servers, and the usual file-search and diff tools. Add
language-specific packages to `devShells` as the project takes shape.
