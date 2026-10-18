---
type: spec
description: Behavioral contract for using iets as the NixOS client.
generated:
  by: copilot/gpt-6-luna
  at: 2026-10-18T05:15:55Z
sources:
- id: iets
  resource: https://github.com/numtide/iets
  title: iets classic command behavior
- id: nixos-core
  resource: ../../../../modules/nixos/core.nix
  title: Shared NixOS iets integration
---

# iets NixOS client

### Requirement: NixOS uses iets with Nix fallback

NixOS hosts SHALL route supported classic Nix command names through iets and
preserve the real Nix client as the fallback for unsupported commands.

#### Scenario: Supported classic command

WHEN a user invokes a command supported by iets through a classic Nix command
name
THEN the iets implementation handles it.

#### Scenario: Unsupported classic command

WHEN a user invokes an unsupported command through a classic Nix command name
THEN the command falls back to the real Nix client.
