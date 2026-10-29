# nixbot on homelab

[nixbot](https://github.com/Mic92/nixbot), the rewrite of buildbot-nix by its
author, builds this repository's `checks.x86_64-linux` on homelab whenever
GitHub receives `main`, a `luvus/*` branch, or a pull request. Its checks gate
`main`: the `main-checks` ruleset requires `nixbot/nix-eval` and
`nixbot/nix-build` from its App (`.github/rulesets/`), and `luvus-deliver`
waits for both on `luvus/integration`'s exact head before fast-forwarding
`main`. It builds in homelab's own store, which keeps what earlier builds made
and which Harmonia serves to the fleet, so a check rebuilds only what changed.

- `modules/nixos/nixbot.nix` configures the service, its Tailscale Funnel on
  homelab's port 443, and the GitHub App's manifest. `hosts/homelab/nixbot.nix`
  names the App, and `secrets/nixbot/` holds its secrets, encrypted with
  agenix for homelab's host key and asus's login key (`secrets/secrets.nix`).
  nixbot stays off while the App ID is `null`.
- `nixbot.toml` lists `luvus/*` in `build_branches`. nixbot reads it from
  `main` only, so a change to that list builds once it has reached `main`.
  It replaces the module's branch globs for building, but not for rooting:
  `branches.topics` in `modules/nixos/nixbot.nix` must match the same
  branches for their outputs to be kept.
- nixbot evaluates with one 6 GiB worker and runs two builds at once, and
  roots the latest result of each attribute built on `main` or a `luvus/*`
  branch; a root expires 90 days after it was last refreshed.

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

| Event          | Why                                                      |
| -------------- | -------------------------------------------------------- |
| `push`         | Build `main` and each `luvus/*` branch pushed to GitHub. |
| `pull_request` | Build a pull request's head.                             |
| `check_run`    | Rebuild from a check run's Re-run button.                |
| `check_suite`  | Rebuild a whole suite when GitHub requests it again.     |

## Registering the App

GitHub is the only forge nixbot and this repository share: nixbot has no
Tangled backend, and its polling mode watches only the default branch.
GitHub reaches nixbot through Tailscale Funnel, which homelab's node may
already use on 443 (the tailnet grants it 443, 8443, and 10000); the private
CI dashboard holds 8443.

The App that `hosts/homelab/nixbot.nix` names was registered this way:

1. In a task worktree on asus, run `nix run path:.#nixbot-register`. It
   opens a local page that hands the manifest to GitHub: click
   **Create GitHub App** there. `nixbot-register` then writes the App's ID
   and Client ID into `hosts/homelab/nixbot.nix`, encrypts its private key,
   webhook secret, and client secret into `secrets/nixbot/`, and adds the
   topic nixbot enables on its first start to `schlich/dotfiles`. It never
   prints a secret or passes one as an argument; `--show-manifest` prints
   the manifest only.
1. On the install page it opens next, which selects only
   `schlich/dotfiles`, click **Install**.
1. Deliver the task. homelab deploys the landing: agenix decrypts the
   secrets with homelab's host key, and nixbot starts and enables
   `schlich/dotfiles`.
1. Push any `luvus/*` branch and confirm `nixbot/nix-eval` and
   `nixbot/nix-build` appear on its commit on GitHub. `luvus-deliver` waits
   for both before it moves `main`, and the luvus gate substitutes what
   nixbot built from Harmonia.

To replace the App, for example after a secret leaks, delete it on GitHub,
set both IDs in `hosts/homelab/nixbot.nix` back to `null`, and run
`nixbot-register` again: it refuses while an App ID is set. The
`main-checks` ruleset names the App whose checks it requires
(`integration_id` in `.github/rulesets/main-checks.json`), and the new App
cannot report until homelab runs it, so delivering the new registration
needs that ruleset changed first, and set to the new App's ID once nixbot
reports again.

## Memory

homelab has 8 CPUs and about 15 GiB of memory. nixbot's evaluation takes up
to 6 GiB and its PostgreSQL a little more, which leaves room for the builds
the fleet offloads to homelab.
