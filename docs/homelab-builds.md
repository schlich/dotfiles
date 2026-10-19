# Offloading builds to homelab

homelab is the fleet's build host and binary cache. Keep editing,
formatting, quick checks, publication, and landing coordination on the
workstation; activation happens only through `system-switch`, after a
landing that changes a closure or when the user asks.
Remote CI is GitHub Actions (`.github/workflows/nix-ci.yml`), which builds
every flake check on each pushed topic branch and the `remoteChecks` system
closures after each push. homelab used to run a Tangled spindle for that; it
was retired on 2026-10-19 once GitHub Actions took over.

## Existing infrastructure

- Every other host builds on homelab and substitutes from its Harmonia
  cache over the tailnet (`homelab-builder-client.nix`,
  `homelab-cache-client.nix`). `ci land`'s local clearance offloads its
  builds the same way.
- Harmonia serves homelab's whole store and signs with a host-local key.
  Outputs that nothing roots are subject to GC; this is a reusable cache,
  not permanent artifact storage.
- homelab imports nixbot, which stays off until `hosts/homelab/nixbot.nix`
  names its GitHub App; [nixbot.md](nixbot.md) has the steps to go live.

## Capacity

homelab has eight CPUs, about 15.4 GiB of RAM, and about 319 GiB free on its
root filesystem (2026-10-02). One large offloaded build can starve
everything else: on 2026-10-19 an LTO build of Codex held about 8 GiB and
most of the CPU for over an hour, and `den-inventory-tests`, normally 23
seconds, took 17 minutes behind it. Build large packages in GitHub Actions
rather than offloading them here.

## Access

Read-only inspection reaches homelab through OpenSSH on port 2222. Port 22
uses Tailscale SSH and requests a separate authentication check, so
automation that uses ordinary SSH keys should select the OpenSSH port.

See [Nix's distributed-build setup](https://nix.dev/tutorials/nixos/distributed-builds-setup.html)
and [the activation policy](architecture.md).
