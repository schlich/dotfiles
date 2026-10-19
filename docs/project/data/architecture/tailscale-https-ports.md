---
type: architecture
description: Each module that publishes through Tailscale Serve or Funnel claims its HTTPS port in one per-host option, and evaluation fails when two claims collide.
generated:
  by: claude-code/opus-5
  at: 2026-10-19T20:40:00Z
sources:
- id: registry
  resource: modules/nixos/tailscale-https.nix
  title: The dotfiles.tailscale.https option and its assertions
- id: workbench-hub
  resource: modules/nixos/workbench-hub.nix
  title: marimohub's private Serve endpoint
- id: homelab
  resource: modules/nixos/homelab.nix
  title: The CI dashboard's private Serve endpoint
---

# Tailscale HTTPS ports

## Decision

Tailscale Serve and Funnel share one HTTPS port space per node, and Funnel
publishes only 443, 8443, and 10000. A module that publishes a service through
either claims its port in `dotfiles.tailscale.https.<service>` and reads the
port back from there. One assertion fails evaluation when two services claim the
same port. Another fails it when a Funnel claim uses a port Funnel cannot
publish. `marimohub-homelab-evaluation` and the host checks evaluate those
assertions, so CI catches a clash before any switch.

Claims as of 2026-10-19:

| Node    | Port | Service         | Exposure |
| ------- | ---- | --------------- | -------- |
| homelab | 8443 | `ci-dashboard`  | Serve    |
| homelab | 9443 | `marimohub`     | Serve    |
| asus    | 443  | `jj-ci-webhook` | Funnel   |

nixbot's Funnel does not claim its port yet: its Funnel moves to port 443 in the
topic "Make nixbot's GitHub App and secrets declarative", which rewrites its
module. The Tangled knot runs its own tailscaled as the separate node `knot`, so
it claims nothing here.

marimohub stays on Serve. Its `proxy-header` auth trusts `Tailscale-User-Login`,
which only Serve sets, and only for a signed-in tailnet user. Its port, 9443,
sits outside Funnel's three ports so they stay free for public endpoints.

## Alternatives considered

- **Hard-coded ports with comments:** this is how the clash arose. nixbot's
  Funnel and marimohub's planned Serve unit both chose 8443 next to the CI
  dashboard's, and nothing failed until a person compared the live
  `tailscale serve status`.
- **A fleet-wide table in `den/inventory.nix`:** ports would be facts beside the
  hosts, but the module that runs a service would no longer own its endpoint.
  Each claim would also need a host name even though only one node serves it.
- **Funnel's 10000 for marimohub:** this is the one Funnel port still free, but
  the hub must not be public. Using it would also spend the last spare Funnel
  port on a private service.
