# Implementation modules

The repository's composition layer is `../den/`. This directory contains
ordinary NixOS and Home Manager modules that are imported by Den aspects.
No directory here holds more than six entries
(`github:schlich/honeycomb`); a seventh means a new group.

- `nixos/` contains system modules, grouped as `base`, `workstation`,
  `builds`, `homelab`, `fleet` and `services`.
- `home/` contains shared Home Manager state: packages and files at the top,
  with `nix`, `session` and `openchamber` beside them.
- `programs/` contains program integrations, grouped as `shell`, `vcs`,
  `desktop`, `multiplexers` and `ssh`.
- `tooling/` contains reusable terminal, editor, and AI integrations; under
  `ai/` they are grouped as `claude`, `clients`, `shared` and `mcp`.

New reusable behavior should normally start as a Den aspect under `../den/`
and use these modules only for class-specific implementation details. Den's
aspects are grouped the same way, as `roles`, `desktop`, `services`, `fleet`
and `users`.
