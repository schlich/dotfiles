---
type: feature
description: NixOS hosts use iets as their Nix client with classic command compatibility.
stage: implemented
generated:
  by: copilot/gpt-6-luna
  at: 2026-10-18T05:15:55Z
sources:
- id: iets
  resource: https://github.com/numtide/iets
  title: iets Nix client and NixOS module
- id: nixos-core
  resource: ../../../../modules/nixos/core.nix
  title: Shared NixOS iets integration
---

# iets NixOS client

## Purpose

Use [iets](https://github.com/numtide/iets) as the Nix client on every declared
NixOS host.

## Behaviour

- The upstream NixOS module installs iets and, with classic compatibility
  enabled, routes supported Nix command names through iets while retaining Nix
  as the fallback.
- Unsupported iets features continue to use the real Nix client.
- The Nix daemon remains NixOS-managed and unchanged.
