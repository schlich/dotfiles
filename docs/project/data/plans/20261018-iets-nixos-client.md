---
type: plan
description: Integrate iets as the NixOS Nix client while preserving classic command compatibility.
created: 2026-10-18
generated:
  by: copilot/gpt-6-luna
  at: 2026-10-18T05:15:55Z
sources:
- id: iets
  resource: https://github.com/numtide/iets
  title: iets Nix client and NixOS module
- id: nixos-core
  resource: ../../../../modules/nixos/core.nix
  title: Shared NixOS module imports
stage: done
completed: 2026-10-18
---

# Integrate iets as the NixOS client

## Context

Adopt [iets](../features/iets.md) as the Nix evaluator and client for the
repository's NixOS hosts, using upstream's NixOS module and compatibility layer.

## Approach

Import the upstream NixOS module through the shared NixOS core and enable its
classic command names, allowing unsupported commands to fall back to Nix. Pin
iets as a flake input that follows the repository's nixpkgs. Do not replace the
daemon or add a separate Home Manager configuration.

## Implementation Steps

### Task 1: Integrate the upstream NixOS module

**Files:** Modify: `flake.nix`, `flake.lock`,
`modules/nixos/core.nix`

- [x] Add the iets flake input and lock it.
- [x] Import the upstream module for every NixOS host.
- [x] Enable classic command compatibility.

### Task 2: Record the shipped behavior

**Files:** Create: `data/features/iets.md`, `data/spec/iets.md`;
Modify: `data/features.md`, `data/spec.md`, `data/releases/unreleased.md`

- [x] Specify the default client and classic command fallback behavior.
- [x] Mark the feature implemented and list it in the unreleased accumulator.

## Spec changes

Add `data/spec/iets.md` for classic command routing and fallback behavior.

## Verification

- Format the Nix changes.
- Run `iwe normalize` and `iwe schema validate`.
- Do not build NixOS configurations unless explicitly requested.

## Out of scope

- Replacing the Nix daemon or changing Home Manager's direnv configuration.
- Adding support for non-`x86_64-linux` flake outputs.

## Key references

Verified anchor points (line numbers as of 2026-10-18):

- `flake.nix:6` — `iets` flake input
- `modules/nixos/core.nix:4` — shared imports
- `modules/nixos/core.nix:12` — classic command enablement
