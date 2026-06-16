# Copilot Instructions

## Build, test, and format commands

- Format Nix files: `nix fmt`
- Build the Home Manager configs:
  - `nix build .#homeConfigurations.schlich.activationPackage`
  - `nix build .#homeConfigurations.nixos.activationPackage`
- Build the NixOS system configs:
  - `nix build .#nixosConfigurations.nixos.config.system.build.toplevel` for the WSL-oriented host
  - `nix build .#nixosConfigurations.desktop.config.system.build.toplevel` for the desktop host
- Run the standalone NixOS smoke test: `nix-build system/system_test.nix`
- There is no separate lint target defined in the flake; formatting is handled through `nix fmt` / `nixfmt-tree`

## High-level architecture

- `flake.nix` is the entrypoint. It pins upstream inputs, overlays a custom `github-copilot-cli` package version, exposes two Home Manager outputs (`schlich`, `nixos`), and two NixOS outputs (`nixos`, `desktop`).
- The active Home Manager build is currently rooted in the top-level `home.nix`. `mkHome` in `flake.nix` imports `./home.nix` directly, so do not assume the `modules/` tree is automatically wired into the built profiles.
- The repository carries two host styles:
  - `configuration.nix` is the WSL-focused NixOS configuration used by `nixosConfigurations.nixos`
  - `system/configuration.nix` plus `system/hardware-configuration.nix` define the desktop machine used by `nixosConfigurations.desktop`
- `modules/` is still important context: it documents the intended shallow split between shared home settings (`modules/home`), program/tool configuration (`modules/programs`), and profile selection (`modules/profiles`).
- Copilot-specific assets live under `copilot/` and are part of the repo's actual configuration surface. `home.nix` enables repo-local plugins, skills, and instructions for multiple AI clients, and `.github/plugin/marketplace.json` exposes this repo as a local Copilot marketplace.
- Helix is configured as the default editor and Nushell as the default shell. Helix's `nixd` setup reads flake outputs directly for Home Manager and NixOS option awareness, so broken output names or moved flake attrs will also break editor assistance.

## Key conventions

- Prefer Nushell, not Bash, for shell snippets and scripts. The repo's shell config, aliases, and AI assistant instructions are written around `nu`.
- Prefer Jujutsu (`jj`) workflows over Git-centric ones. The repo config enables `jjui`, custom starship `jj` status, and bundled JJ skills/reference material.
- Keep module structure shallow when working under `modules/`: profiles compose broad branches, `home/` holds shared user environment pieces, and `programs/` groups tool configuration by concern instead of by deeply nested app directories.
- Treat AI tooling as declarative config. Adding or changing a Copilot/Claude/OpenCode capability usually means updating both the repo-local assets in `copilot/` and the corresponding enablement/settings in `home.nix`.
- When editing Nix support tooling, preserve the flake output names and option paths used by `nixd`, Home Manager builds, and the AI client configuration unless you intentionally update all of those call sites together.
