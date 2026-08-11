# Copilot Instructions

## Build, test, and format commands

- Format Nix files: `nix fmt`
- Build the Home Manager configs:
  - `nix build .#homeConfigurations.schlich.activationPackage`
  - `nix build .#checks.x86_64-linux.home-profiles`
- Build the NixOS system configs:
  - `nix build .#nixosConfigurations.asus.config.system.build.toplevel`
- There is no separate lint target defined in the flake; formatting is handled through `nix fmt` / `nixfmt-tree`

## High-level architecture

- `flake.nix` pins inputs and generates named Home Manager configurations from `profiles/`. `homeConfigurations.schlich` aliases `schlich-full`; `nixosConfigurations.asus` is the active NixOS host.
- `home.nix` imports shared modules. Each profile imports self-contained terminal, editor, and AI modules from `modules/tooling/` and selects one primary tool per category.
- Importing a tool module is the enablement boundary. Its package, settings, integrations, launcher capability, and checks must remain in that module so removing one profile import removes the complete tool.
- `modules/tooling/interface.nix` validates profile primaries and generates the generic `terminal`, `editor`, `ai`, and `ai-run` commands.
- Copilot-specific assets live under `copilot/`. Only profiles importing `modules/tooling/ai/copilot.nix` install the Copilot CLI and its projected assets.
- Helix's `nixd` setup reads flake outputs directly for Home Manager and NixOS option awareness, so broken output names or moved flake attrs will also break editor assistance.

## Key conventions

- Prefer Nushell, not Bash, for shell snippets and scripts. The repo's shell config, aliases, and AI assistant instructions are written around `nu`.
- Prefer Jujutsu (`jj`) workflows over Git-centric ones. The repo config enables `jjui`, custom starship `jj` status, and bundled JJ skills/reference material.
- Keep shared state in `modules/home` and `modules/programs`; keep selectable tools isolated under `modules/tooling/<category>/<tool>.nix`.
- Add or remove selectable tooling through profile imports. Do not reintroduce central enums, duplicated package lists, or client-specific settings in shared modules.
- When editing Nix support tooling, preserve the flake output names and option paths used by `nixd`, Home Manager builds, and the AI client configuration unless you intentionally update all of those call sites together.
