# Offloading builds to homelab

homelab is the fleet's build host and binary cache. Keep editing,
formatting, quick checks, publication, and delivery coordination on the
workstation; activation happens only through `system-switch`, after a
delivery that changes a closure or when the user asks.
The gating CI is nixbot on homelab ([nixbot.md](nixbot.md)), which builds
`checks.x86_64-linux` for `main` and every `luvus/*` branch in homelab's own
store. GitHub Actions (`.github/workflows/nix-ci.yml`) also builds every
flake check on each push, and the `remoteChecks` system closures after it,
but gates nothing. homelab used to run a Tangled spindle; it was retired on
2026-10-19.

## Existing infrastructure

- Every other host builds on homelab and substitutes from its Harmonia
  cache over the tailnet (`homelab-builder-client.nix`,
  `homelab-cache-client.nix`). The luvus gate's `nix-fast-build` on asus
  offloads its builds the same way, and its `--skip-cached` skips any check
  whose output a substituter, Harmonia among them, already has.
- Harmonia serves homelab's whole store and signs with a host-local key, so
  what nixbot and offloaded builds produce is the fleet's cache. Outputs
  that nothing roots are subject to GC; nixbot roots the latest result of
  each check it built on `main` or a `luvus/*` branch. This is a reusable
  cache, not permanent artifact storage.

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
