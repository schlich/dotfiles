---
type: plan
description: Declare nixbot's GitHub App manifest and agenix secrets in the flake, so going live is nixbot-register, two clicks, and a landing.
created: 2026-10-19
generated:
  by: claude-code/opus-5.5
  at: 2026-10-19T20:10:00Z
sources:
- id: nixbot-module
  resource: nixbot:nixosModules/nixbot.nix
  title: Locked nixbot module (github.topic, the *File options)
- id: agenix-module
  resource: agenix:modules/age.nix
  title: Locked agenix module
- id: manifest-flow
  resource: https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest
  title: Registering a GitHub App from a manifest
- id: probot-setup
  resource: https://github.com/probot/probot/blob/master/src/apps/setup.ts
  title: Probot's local manifest flow, which redirects to localhost
---

# Make nixbot's GitHub App and secrets declarative

## Context

nixbot on homelab stayed off because going live needed a hand-made GitHub App
and three secrets copied into `/var/lib/nixbot-secrets` by hand. The user asked
to move as much of that into the flake as possible. The secrets backend is
recorded in [Host secrets](../architecture/host-secrets.md).

## Approach

The App's manifest is derived in the nixbot module from the values the service
uses, and `nixbot-register` hands it to GitHub's manifest flow, which accepts a
localhost `redirect_url` (Probot's local setup relies on it). The conversion
returns the App's IDs and secrets; the command encrypts the secrets with age for
homelab's host key and asus's login key and writes the IDs, so a single landing
turns nixbot on. nixbot's legacy `topic` import enables the repository on its
first start. nixbot's Funnel moves to 443, because the private CI dashboard
already serves 8443 on homelab's node.

## Implementation Steps

### Task 1: Manifest and registration

- [x] Derive the manifest in `modules/nixos/nixbot.nix` and expose it with the
  secrets' files and recipients as `dotfiles.nixbot.registration`.
- [x] Move the Funnel to 443 and set `github.topic`.

### Task 2: nixbot-register

- [x] Nushell command with a Python localhost listener, shipped as
  `packages.nixbot-register` and `apps.nixbot-register`.
- [x] Never print a secret or pass one as an argument.

### Task 3: Decrypt on homelab

- [x] Add the agenix input; make `modules/nixos/secrets.nix` the mechanism.
- [x] `profile.secrets = true` for homelab; point the `*File` options at
  `/run/agenix`.

### Task 4: Tests and docs

- [x] `nixbot-app-manifest` check against `docs/nixbot.md`'s tables.
- [x] Placeholder secrets in `nixbot-homelab-evaluation`.
- [x] Rewrite `docs/nixbot.md`'s go-live section.

### Task 5: Go live (the user)

- [ ] Run `nixbot-register`, create and install the App, land the result.

## Spec changes

None: no spec covers nixbot yet.

## Key references

Verified anchor points (line numbers as of 2026-10-19):

- modules/nixos/nixbot.nix:14 — `funnelPort`
- modules/nixos/nixbot.nix:47 — `manifest`
- modules/nixos/nixbot.nix:75 — `dotfiles.nixbot.registration`
- modules/nixos/nixbot.nix:130 — `age.secrets`
- modules/nixos/secrets.nix:9 — agenix import
- secrets/secrets.nix:22 — nixbot's recipients
- den/inventory.nix:104 — homelab `secrets = true`
- tools/nixbot-register/register.nu:56 — `main`
- tools/nixbot-register/listen.py:46 — listener `main`
- flake.nix:394 — `nixbotHomelabEvaluationCheck`
- flake.nix:734 — `nixbot-app-manifest`
- tests/nixbot-manifest.nu:29 — check `main`
- docs/nixbot.md:25 — "What the App may do"
