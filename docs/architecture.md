# Configuration architecture

This repository is organized around Den's feature-first model. The top-level
`den/` tree owns the entity schema, host inventory, policies, and aspect graph.
The flake exposes the configurations produced by that graph directly.

## Repository shape

- `den/inventory.nix` contains typed host and user facts.
- `den/aspects/` contains reusable capabilities and user environments.
- `den/default.nix` supplies behavior shared by every host.
- `den/aspects/master.nix` resolves typed host facts into reusable aspects.
- `den/hosts.nix` contains only Den-wide host schema defaults.
- `hosts/` contains host-local hardware and storage facts only.
- `modules/` contains ordinary NixOS and Home Manager implementation modules
  consumed by aspects. It is not the composition layer.

The NixOS implementation is split by scope: `core.nix` is safe for every
host, while `workstation.nix` owns audio, Bluetooth, portals, Chrome, and
other interactive workstation services. The latter is reached through the
workstation aspect and never through `den.default`.

The inventory is the host composition interface. For example, `asus` selects
the workstation, Niri, laptop, development, remote, XR, AMD, ASUS platform,
and internal-storage behavior through its profile. `asus-headless` selects the
server, headless, ASUS platform, and internal-storage behavior instead.

## Resolution flow

```text
typed inventory -> host aspect composition -> Den host/user pipeline
                 -> NixOS + Home Manager module graph -> outputs/checks
```

`den.default` contributes the common base and system-file behavior. The
parametric `master` aspect then adds only profile-dependent behavior.

User configuration is supplied by Den user aspects. The workstation aspect
only enables the Home Manager integration; it does not hardcode a username,
home directory, or user-specific `extraSpecialArgs`.

The `schlich` user aspect also owns that account's NixOS policy: UID, shell,
groups, and SSH login restrictions. Generic user behavior must not import a
specific account module.

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
