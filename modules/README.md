# Implementation modules

The repository's composition layer is `../den/`. This directory contains
ordinary NixOS and Home Manager modules that are imported by Den aspects.

- `nixos/` contains system implementation modules.
- `home/` contains shared Home Manager state.
- `programs/` contains program integrations.
- `tooling/` contains reusable terminal, editor, and AI integrations.

New reusable behavior should normally start as a Den aspect under `../den/`
and use these modules only for class-specific implementation details.
