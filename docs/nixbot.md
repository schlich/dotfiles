# nixbot on homelab

[nixbot](https://github.com/Mic92/nixbot), the rewrite of buildbot-nix by its
author, builds this repository's `checks.x86_64-linux` on homelab whenever
GitHub receives `main` or a `jj-*` topic branch. It builds in homelab's own
store, which Harmonia already serves to the fleet, so `ci land`'s local
clearance substitutes what nixbot built instead of building it again on the
workstation.

- `modules/nixos/nixbot.nix` configures the service, its Tailscale Funnel on
  homelab's port 443, and the GitHub App's manifest. `hosts/homelab/nixbot.nix`
  names the App, and `secrets/nixbot/` holds its secrets, encrypted with
  agenix for homelab's host key and asus's login key (`secrets/secrets.nix`).
  nixbot stays off while the App ID is `null`.
- `nixbot.toml` lists `jj-*` in `build_branches`. nixbot reads it from
  `main` only, so topics build once that file has landed.
- `ci dispatch` pushes every topic to `origin`, the trunk remote, and
  `ci land --clearance nixbot` waits for nixbot's
  `nixbot/nix-eval` and `nixbot/nix-build` check runs on the exact head.
  Both need a `ci` release that has them (`nix flake update ci`).
- nixbot evaluates with one 6 GiB worker and runs two builds at once, and
  roots each topic's outputs until it lands; its gcroots expire after 90
  days.

## What the App may do

The App is private to `schlich` and asks for no more than nixbot needs to
build this repository. `nixbot-register` creates it from the manifest in
`modules/nixos/nixbot.nix`, and the `nixbot-app-manifest` check fails when
that manifest and these tables disagree.

| Permission      | Access  | Why                                                                  |
| --------------- | ------- | -------------------------------------------------------------------- |
| `contents`      | `read`  | Clone the repository.                                                |
| `checks`        | `write` | Report `nixbot/nix-eval`, `nixbot/nix-build`, and failed attributes. |
| `metadata`      | `read`  | Look up a user's role in the repository; every App has it.           |
| `pull_requests` | `read`  | Receive the `pull_request` event.                                    |

| Event          | Why                                                           |
| -------------- | ------------------------------------------------------------- |
| `push`         | Build `main` and each `jj-*` topic that `ci dispatch` pushes. |
| `pull_request` | Build a pull request's head.                                  |
| `check_run`    | Rebuild from a check run's Re-run button.                     |
| `check_suite`  | Rebuild a whole suite when GitHub requests it again.          |

## Going live

GitHub is the only forge nixbot and this repository share: nixbot has no
Tangled backend, and its polling mode watches only the default branch.
GitHub reaches nixbot through Tailscale Funnel, which homelab's node may
already use on 443 (the tailnet grants it 443, 8443, and 10000); the private
CI dashboard holds 8443.

1. On asus, start a topic (`ci new -m "Turn on nixbot"`) and run
   `nix run path:.#nixbot-register` in it. It opens a local page that hands
   the manifest to GitHub: click **Create GitHub App** there.
   `nixbot-register` then writes the App's ID and Client ID into
   `hosts/homelab/nixbot.nix`, encrypts its private key, webhook secret, and
   client secret into `secrets/nixbot/`, and adds the topic nixbot enables
   on its first start to `schlich/dotfiles`. It never prints a secret or
   passes one as an argument; `--show-manifest` prints the manifest only.
1. On the install page it opens next, which selects only
   `schlich/dotfiles`, click **Install**.
1. Declare the topic `behavior`, dispatch it, and land it. homelab deploys
   the landing: agenix decrypts the secrets with homelab's host key, and
   nixbot starts and enables `schlich/dotfiles`.
1. Dispatch any topic and confirm `nixbot/nix-eval` and `nixbot/nix-build`
   appear on its commit on GitHub. From then on
   `ci land --clearance nixbot` can clear it; the default local clearance
   also benefits, since it substitutes nixbot's outputs from Harmonia.

To replace the App, for example after a secret leaks, delete it on GitHub,
set both IDs in `hosts/homelab/nixbot.nix` back to `null`, and run
`nixbot-register` again: it refuses while an App ID is set.

## Memory

homelab has 8 CPUs and about 15 GiB of memory. nixbot's evaluation takes up
to 6 GiB and its PostgreSQL a little more, which leaves room for the builds
the fleet offloads to homelab.
