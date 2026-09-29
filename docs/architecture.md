# Configuration architecture

This repository is organized around Den's feature-first model. The top-level
`den/` tree owns the entity schema, host inventory, policies, and aspect graph.
The flake exposes the configurations produced by that graph directly.

## Repository shape

- `den/inventory.nix` contains typed host and user facts.
- `den/aspects/` contains reusable capabilities and user environments.
- `den/hosts.nix` composes each host from explicit aspects.
- `hosts/` contains host-local hardware and storage facts only.
- `modules/` contains ordinary NixOS and Home Manager implementation modules
  consumed by aspects. It is not the composition layer.

The host declarations are intentionally small. For example, `asus` selects
the workstation, Niri, laptop, development, remote, XR, AMD, and platform
aspects. `asus-headless` selects the server and headless aspects instead.

## Resolution flow

```text
typed inventory -> host aspect composition -> Den host/user pipeline
                 -> NixOS + Home Manager module graph -> outputs/checks
```

User configuration is supplied by Den user aspects. The workstation aspect
only enables the Home Manager integration; it does not hardcode a username,
home directory, or user-specific `extraSpecialArgs`.

## Formatting and future unit tests

Repository-wide formatting and the future nix-unit test surface are provided
by [Checkmate](https://github.com/denful/checkmate). Format locally with:

```text
nix run github:denful/checkmate#fmt --override-input target path:. -- --on-unmatched warn --excludes '.agents/**' --excludes '.codex/**'
```

## Safety boundaries

Hardware, storage, boot, encryption, and generated machine files remain under
`hosts/`. Reusable aspects do not infer or rewrite those facts. Inventory
validation rejects invalid combinations such as server plus Niri or XR without
a graphical workstation.

The typed aspect policy registry records risk and reviewer domains in Den
aspect metadata. CI evaluates every declared host, checks the Home Manager
activation graph, and runs the independent desktop configuration checks.

No activation is implied by evaluation or builds. A system or home activation
requires an explicit operator decision after the generated output has been
reviewed.

## NixOS generation policy

A NixOS generation is warranted exactly when the candidate system toplevel's
store path differs from the active system at `/run/current-system`. Compare the
realized `nixosConfigurations.<host>.config.system.build.toplevel` path with
the active symlink target. If they match, do not run a NixOS switch just to
record the source change; evaluation and builds do not create generations.

When the paths differ and the system change is to be applied, use the deliberate
NixOS activation workflow. Home Manager-only changes use `home-activate` when
they leave the NixOS toplevel unchanged. In this repository,
`home-manager.useUserPackages = true`, so changes to `home.packages` are
system-owned and can change the NixOS toplevel; classify those by the same path
comparison rather than by where the option is declared.
