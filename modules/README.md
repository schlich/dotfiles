# Configuration Modules

- `nixos/` contains shared system policy and services.
- `home/` contains shared Home Manager state, packages, files, and services.
- `programs/` groups Home Manager program settings by concern.
- `tooling/` contains the generic launch interfaces and one self-contained module per tool.

The active machine composition is in `hosts/asus/`; `configuration.nix` and `home.nix` are intentionally small entry points.

Named Home Manager configurations are generated from modules in `profiles/`. Activate one with, for example,
`home-manager switch --flake .#schlich-focused`. The `schlich` output aliases `schlich-full` for compatibility.
Each profile also provides `terminal`, `editor`, and `ai` commands that launch its primary choices.
Importing a tool module installs and configures it; removing that import removes all of its integration and checks.
