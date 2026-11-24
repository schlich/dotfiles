---
type: plan
description: Run T3 Code 0.1.4 as a declarative user service on asus and homelab, published to the tailnet, so the desktop and phone drive agents on both and agents delegate across them.
created: 2026-10-29
generated:
  by: codex/gpt-6.2-sol
  at: 2026-11-24T05:42:31Z
sources:
- id: t3-docs
  resource: https://github.com/pingdotgg/t3code/tree/v0.1.4/docs/user
  title: T3 Code user docs at v0.1.4 (install, background service, remote access, outside agents)
- id: t3-release
  resource: https://github.com/pingdotgg/t3code/releases/tag/v0.1.4
  title: T3 Code v0.1.4 release notes (linked environments, delegate_task)
- id: nixpkgs-pr
  resource: https://github.com/NixOS/nixpkgs/pull/580444
  title: 't3code: 0.1.2 -> 0.1.4'
- id: fleet-doc
  resource: docs/agents/T3-FLEET.md
  title: The fleet's architecture, setup and verification
- id: fleet-service
  resource: modules/tooling/ai/clients/t3code/t3code-server.nix
  title: The fleet server and its shared Jobs action
---

# Run a T3 Code agent fleet

## Context

T3 Code was installed only as a desktop app (0.0.45 from the locked nixpkgs),
whose embedded server lives and dies with its window. The goal is a fleet: NixOS
hosts as durable execution environments, the desktop app and the Android app as
control surfaces, and cross-machine delegation through T3's own linked
environments, which first shipped in v0.1.4.

## Approach

Take `t3code` 0.1.4 from the nixpkgs commit that packaged it (input
`nixpkgs-t3code`), watched by `nixpkgs-watch`. A new inventory service fact,
`services.t3code`, selects a Den aspect with a system half (owner lingers;
root-run Tailscale Serve publishes the loopback listener at
`https://HOST.TAILNET:3773/`) and a home half (the `t3code-server` user unit,
modelled on upstream's, with a direnv `BASH_ENV` hook, MCP entries for Claude
Code and Codex, a client-only desktop launcher and the `t3f` Nushell helpers).

The package now comes from the system nixpkgs pin, alongside Atuin and Hokum.
The separate inputs and their nixpkgs watch entries were removed. The T3 Connect
wrapper still provides the public relay and OAuth settings.

Push notifications use T3 Connect in publish-only mode, without a tunnel.
Rejected: `t3 service install` (imperative, self-updating, pins one store path),
`--tailscale-serve` (needs Tailscale operator rights for the user and its
agents), a managed T3 Connect tunnel (public exposure the tailnet makes
unnecessary), and a second T3 home for the desktop app (two environments on one
machine).

The fleet service provisions a shared **Jobs** action in T3's writable settings.
On projects that inherit the server's actions, it follows the latest job in the
thread's workspace in the terminal drawer. It uses the same job events for
Nushell and Rex-backed runs.

## Implementation Steps

### Task 1: Package and service

**Files:** Create: `modules/tooling/ai/clients/t3code/t3code-package.nix`,
`modules/tooling/ai/clients/t3code/t3code-server.nix`,
`modules/nixos/services/t3code.nix`, `den/aspects/services/t3code.nix`,
`modules/tooling/ai/scripts/t3f.nu`; Modify: `flake.nix`,
`modules/tooling/ai/clients/t3code/t3code.nix`, `den/model/schema.nix`,
`den/model/profile.nix`, `den/inventory.nix`, `den/default.nix`,
`den/aspects/users/schlich.nix`, `tests.nix`, `tests/den-config.nix`

- [x] Pin 0.1.4 and share one package between the app and the server.
- [x] Add the `t3code` service fact, aspect, units and tests.
- [x] Document the fleet in `docs/agents/T3-FLEET.md`.

### Task 2: Roll out and verify

- [x] Deliver, switch asus, activate homelab's home.
- [x] Pair the desktop, link the hosts, delegate a task.
- [x] Load project dev shells in Claude's Nushell MCP server too, not only in
  bash.
- [x] Give `t3` T3 Connect's public configuration, which nixpkgs' build lacks.
- [ ] Owner: pair the phone and link T3 Connect for push notifications.
- [ ] Owner: sign Claude Code in to the `t3` MCP server, then check a tool call;
  sign Claude in on homelab.

## Spec changes

None — the fleet's behavior is recorded in `docs/agents/T3-FLEET.md`.

## Verification

`nix fmt`, the flake checks (`den-config-tests-*`, `den-inventory-tests`, the
home's `t3code-bash-env` check), a smoke test of the unit against a throwaway T3
home, then the rollout steps in `docs/agents/T3-FLEET.md`.

## Out of scope

macOS hosts, T3 Connect managed tunnels, and changing which providers or
permission modes T3 offers by default.

## Key references

Verified anchor points (line numbers as of 2026-10-29):

- `den/inventory.nix:75` — asus runs the server
- `den/inventory.nix:114` — homelab runs the server
- `modules/tooling/ai/clients/t3code/t3code-server.nix:1` — the user unit
- `modules/nixos/services/t3code.nix:1` — linger and Tailscale Serve
