# Repository instructions

## Build, test, and validation commands

- From the repo root, use `stow .` to install symlinks and `stow --restow .` after editing dotfiles (`README.md`).
- The active Home Manager / NixOS flake lives in `dot-config/home-manager/`, not a top-level `home-manager/` directory. Run Home Manager commands from there.
- From `dot-config/home-manager/`, update inputs with `nix flake update` (`README.md`, `dot-config/home-manager/flake.nix`).
- Apply the shared config to a target machine with `nix run home-manager/master -- switch --flake .#wsl` or `.#desktop`; the flake outputs are `nixosConfigurations.wsl` and `nixosConfigurations.desktop` (`dot-config/home-manager/flake.nix`).
- `just check-system` runs `nix flake check /etc/nixos/`; it validates the host system flake, not this repository's flake (`justfile`).
- There is no dedicated unit-test suite or single-test runner checked into this repo. Validation is mostly Nix evaluation / switching plus tool-specific formatting.
- Helix is configured to format Nix with `nix fmt`, Python with `ruff format -`, TOML with `taplo format -`, and SQL with `sqlfmt -` (`dot-config/home-manager/home/default.nix`, `dot-config/home-manager/nushell/config.nu`).

## High-level architecture

- This repo mixes two configuration strategies:
  - GNU Stow-managed dotfiles at the repository root (`dot-bashrc`, `dot-gitconfig`, `dot-config/...`), where `dot-*` becomes `.*` when stowed (`README.md`).
  - A Nix flake under `dot-config/home-manager/` that defines machine-specific NixOS + Home Manager setups (`dot-config/home-manager/flake.nix`).
- `dot-config/home-manager/flake.nix` is the entry point. It defines two systems:
  - `wsl`: imports `hosts/wsl/configuration.nix` plus `home/wsl.nix`
  - `desktop`: imports `hosts/desktop/configuration.nix` plus `home/desktop.nix`
- `home/wsl.nix` and `home/desktop.nix` are thin overlays on `home/default.nix`. Keep shared user packages and program configuration in `home/default.nix`, and only add environment-specific differences in the host-specific home files.
- `hosts/*/configuration.nix` is for system-level NixOS settings; `home/*` is for user-level Home Manager settings. The desktop host enables Niri and GUI packages, while WSL enables the `nixos-wsl` module and keeps the setup CLI-focused.
- Tool configs are split between files sourced directly with `home.file` (for example `../helix/config.toml`, `../niri/config.kdl`, `../nushell/config.nu`) and configs expressed directly in Nix (`programs.*` blocks in `home/default.nix`).
- `copilot/prompts/` contains repository-local custom Copilot agents and instruction files. `mcp/dot-mcp/` is a separate MCP server configuration bundle with Nushell utilities and client-specific config exports.

## Key conventions

- Treat `dot-config/home-manager/home/default.nix` as the main shared Home Manager module; do not duplicate shared settings into both `home/wsl.nix` and `home/desktop.nix`.
- When adding machine-specific behavior, wire it through the matching pair of files: `hosts/<machine>/configuration.nix` for system settings and `home/<machine>.nix` for user packages or UI additions.
- Keep Stow naming intact: top-level files use the `dot-` prefix so they map to hidden files in `$HOME` (`README.md`).
- Nushell is a first-class shell in this repo. Check `dot-config/home-manager/nushell/config.nu` for aliases and expected commands (`hm`, `nrb`, `nixfmt`, `helix`) before changing shell-related behavior.
- Helix language tooling is curated in Home Manager and the Helix config files. Reuse the existing formatter / language-server choices instead of introducing parallel tooling without a strong reason (`dot-config/home-manager/home/default.nix`, `dot-config/helix/languages.toml`).
- Custom Copilot content follows the existing prompt naming and frontmatter patterns in `copilot/prompts/`: lowercase hyphenated filenames, `.agent.md` / `.instructions.md` suffixes, and YAML frontmatter as described in `copilot/prompts/agent-guidelines.instructions.md` and `copilot/prompts/agent-skills.instructions.md`.
