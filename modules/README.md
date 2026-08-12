# Configuration Modules

- `nixos/` contains shared system policy and services.
- `home/` contains shared Home Manager state, packages, files, and services.
- `programs/` groups Home Manager program settings by concern.
- `tooling/` contains the generic launch interfaces and one self-contained module per tool.

Each profile also provides `terminal`, `editor`, and `ai` commands that launch its primary choices.
Importing a tool module installs and configures it; removing that import removes all of its integration and checks.
