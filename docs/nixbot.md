# nixbot on homelab

[nixbot](https://github.com/Mic92/nixbot), the rewrite of buildbot-nix by its
author, builds this repository's `checks.x86_64-linux` on homelab whenever
GitHub's mirror receives `main` or a `jj-*` topic branch. It builds in
homelab's own store, which Harmonia already serves to the fleet, so
`ci land`'s local clearance substitutes what nixbot built instead of building
it again on the workstation.

- `modules/nixos/nixbot.nix` configures the service and its Tailscale Funnel;
  `hosts/homelab/nixbot.nix` names the GitHub App. nixbot stays off while
  the App ID there is `null`.
- `nixbot.toml` lists `jj-*` in `build_branches`. nixbot reads it from
  `main` only, so topics build once that file has landed.
- `ci dispatch` pushes every topic to `origin`, the trunk remote, and
  `ci land --clearance nixbot` waits for nixbot's
  `nixbot/nix-eval` and `nixbot/nix-build` check runs on the exact head.
  Both need a `ci` release that has them (`nix flake update ci`).
- nixbot evaluates with one 6 GiB worker and runs two builds at once, and
  roots each topic's outputs until it lands; its gcroots expire after 90
  days.

## Going live

GitHub is the only forge nixbot and this repository share: nixbot has no
Tangled backend, and its polling mode watches only the default branch.

1. Create a GitHub App at <https://github.com/settings/apps/new>, with
   `https://homelab.tail338351.ts.net:8443` (homelab's `fleet.fqdn`) as BASE:
   - Homepage URL: BASE.
   - Webhook: active, URL `BASE/webhooks/github`, and a new random secret,
     such as `random chars --length 40`.
   - Callback URL: `BASE/auth/github/callback`.
   - Repository permissions: Contents read-only, Checks read and write,
     Metadata read-only, Pull requests read-only.
   - Events: Push, Pull request, Check run, Check suite.
   - Install it on `schlich/dotfiles` only.
   - Generate a private key and a client secret.
1. On homelab, as root, put the three secrets in `/var/lib/nixbot-secrets/`
   (mode 0400): `github-app.pem` (the private key),
   `github-webhook-secret`, and `github-oauth-secret` (the client secret).
   They never enter the repository or the store.
1. Set `appId` (the App ID) and `oauthId` (the Client ID) in
   `hosts/homelab/nixbot.nix` and land it. homelab deploys each landing of
   `main`; with the secrets missing, nixbot's unit would fail and the staged
   switch would revert, so do step 2 first.
1. Open BASE, log in with GitHub, and enable the `schlich/dotfiles` project.
1. Dispatch any topic and confirm `nixbot/nix-eval` and `nixbot/nix-build`
   appear on its commit on GitHub. From then on
   `ci land --clearance nixbot` can clear it; the default local clearance
   also benefits, since it substitutes nixbot's outputs from Harmonia.

## Memory

homelab has 8 CPUs and about 15 GiB of memory. nixbot's evaluation takes up
to 6 GiB and its PostgreSQL a little more, which leaves room for the builds
the fleet offloads to homelab.
