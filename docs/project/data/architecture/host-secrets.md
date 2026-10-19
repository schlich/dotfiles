---
type: architecture
description: Hosts decrypt repository secrets with agenix and their own OpenSSH host key, so a pull-based deploy needs no key pushed to it.
generated:
  by: claude-code/opus-5.5
  at: 2026-10-19T20:10:00Z
sources:
- id: secrets-module
  resource: modules/nixos/secrets.nix
  title: The secrets mechanism a host gets with profile.secrets
- id: rules
  resource: secrets/secrets.nix
  title: Each encrypted file's recipients
- id: nixbot
  resource: modules/nixos/nixbot.nix
  title: nixbot's App manifest and the secrets it decrypts
---

# Host secrets

A host whose inventory sets `profile.secrets` gets the `secrets` aspect: agenix,
decrypting at activation with the host's OpenSSH ed25519 key. Each module that
needs a secret declares it under `age.secrets`, and `secrets/secrets.nix` lists
the host's key among that file's recipients, beside asus's login key so the
files can be edited and rekeyed from asus. homelab is the first host to use it,
for nixbot's GitHub App, and `nixbot-register` writes those files.

- The `.age` files live in the repository. A host decrypts them during the
  switch that activates them, so a secret lands with the configuration that uses
  it, in the same commit.
- A file the host cannot decrypt fails activation, and the staged switch
  reverts. The mechanism therefore declares no secret itself: an earlier shared
  `github-token` declaration, encrypted for keys no current host holds, was
  dropped when homelab adopted it.
- agenix stays off on a host that declares no secret, so turning on
  `profile.secrets` changes nothing until a module declares one.

## Rejected alternatives

- **Clan vars (sops).** clan-core is already pinned for deploys, but its vars
  decrypt with an age key that `clan vars upload` or `clan machines update`
  pushes to the host. homelab deploys pull-based through `system-switch` and its
  canary timer, which never run that upload, so the key would need a separate
  push and a recovery story of its own.
- **Hand-copied files under `/var/lib`.** nixbot's module first expected its
  three secrets in `/var/lib/nixbot-secrets`, copied there by hand. The landing
  that turned nixbot on had to wait for them, and a missing file would have
  failed the unit and reverted the switch.
