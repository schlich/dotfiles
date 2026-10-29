# Dagger

[Dagger](https://dagger.io) 1.0 (beta) runs this flake's checks as cached
container functions: on this machine with `dagger check`, on Dagger's Cloud
Engines with `dagger check --engine cloud`, and after every push as Dagger Cloud
Checks. It reports alongside nixbot and nix-ci and gates nothing: the
`main-checks` ruleset still requires only nixbot's checks.

## What runs

`dagger.toml` is the workspace. It installs two modules:

- `flake` (`.dagger/modules/flake/main.dang`, written in Dang, Dagger's DSL)
  exposes each attribute of `checks.x86_64-linux` as one check. Running several
  at once is one `nix-fast-build --skip-cached` run, the same command as the
  luvus gate and nix-ci, so an output that a binary cache already holds passes
  without being downloaded.
- `dang-sdk` adds a staleness check for the module's generated configuration.

The build runs in `nixos/nix`, pinned by `dagger.lock`, with the repository
mounted at `/src` and read as `path:/src`: tracked and untracked files, minus
`.gitignore`d ones, VCS state, and agent worktrees. The container cannot create
the namespaces Nix's sandbox needs, so builds run unsandboxed there.

## Three caches

1. **Dagger's function and exec cache** keys every step by its inputs. When the
   source a check reads is unchanged, `dagger check` returns the earlier result
   without starting a container, so a second run of an unchanged tree takes
   seconds. The same holds on one engine for any branch with that tree, such as
   `main` fast-forwarded to a checked `luvus/integration`.
1. **The Nix store** lives in the `flake-nix` cache volume, seeded from the
   image's `/nix`, and Nix's fetcher cache lives in `flake-nix-fetchers`. A
   changed source still runs `nix-fast-build`, but only the derivations that
   changed build: flake inputs, tools, and unchanged check outputs are already
   there.
1. **Binary caches**: cache.nixos.org, `schlich.cachix.org` (which nix-ci fills),
   and Niri's. `--skip-cached` passes any check already in them. Locally,
   `--env homelab` adds homelab's cache, which holds what nixbot built.

A cache hit is exact: Dagger keys by content, not by branch or commit, so a hit
never stands in for a different tree.

## Using it

The CLI is `pkgs.dagger` from `modules/programs/dagger-package.nix`, in the
workstation home and the dev shell.

```nu
dagger check                                  # every check, as the gate runs them
dagger check -l --all                         # list them, one row per flake check
dagger check --flake-check=whitespace         # one flake check
dagger check --flake-check=ruff --flake-check=niri-config
dagger check -i                               # open a shell where a build failed
dagger check --env homelab                    # also substitute from homelab
dagger check --engine cloud                   # run on Dagger's Cloud Engines
```

`dagger check` exits non-zero when a check fails, and its trace links to Dagger
Cloud once you are logged in (`dagger cloud login`).

Settings live in `dagger.toml` (`dagger module settings flake`). `maxJobs` (2)
and `cores` (4) match the workstation's `nix.conf`, and `evalWorkers` (4) bounds
evaluation memory: each evaluation of a NixOS host can take several GiB. The
`homelab` env sets `extraSubstituters` and `extraTrustedPublicKeys`. `image`,
`substituters`, `trustedPublicKeys`, and `system` complete the list.

## Cloud Checks

`dagger cloud checks on` connects the GitHub repository to Dagger Cloud. After
that, each push and pull request runs `dagger check` on Dagger's Cloud Engines
and reports a commit status; no workflow file is involved.

```nu
dagger cloud checks status                    # is it on?
dagger cloud checks list --watch              # follow the checks for HEAD
dagger workspace activity                     # recent runs and their CHECKS column
dagger cloud usage                            # engine minutes and cost this month
```

Cloud Engines bill by usage, and work served from cache bills at a lower rate.

## Updating Dagger

Bump `version` and `hash` in `modules/programs/dagger-package.nix` (the
release's `checksums.txt` has the SHA-256), then `dagger lock update` and
`dagger generate` so the module's `engineVersion` follows. `nixpkgs-watch` says
when nixpkgs packages Dagger again.

## Known issues

- Dagger cannot open this repository's Git metadata, because it does not
  support the `worktreeconfig` and `relativeworktrees` extensions. Every command
  warns about it. Local checks do not need Git, and Cloud Checks clone from
  GitHub.
