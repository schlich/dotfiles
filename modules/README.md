# Home Manager Modules

This tree uses a shallow layout: profiles import broad branches, and `programs/` keeps one module per concern in a single directory.

- `profiles/` selects which components are active for a machine or user, including profile-specific identity.
- `home/` contains shared packages, session variables, files, and Nix settings.
- `programs/` contains swappable tool modules consolidated by concern.

The split mirrors the differences between this active `nixos` config and `~/dotfiles`: identity, packages, desktop files, MCP servers, editor settings, VCS prompt, and AI tools can be merged or swapped independently without a deeper programs tree or per-tool files.
