# Configuration Modules

- `nixos/` contains shared system policy and services.
- `home/` contains shared Home Manager state, packages, files, and services.
- `programs/` groups Home Manager program settings by concern.

The active machine composition is in `hosts/asus/`; `configuration.nix` and `home.nix` are intentionally small entry points.
