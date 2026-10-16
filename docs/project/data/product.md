---
type: tracker
description: What the dotfiles configuration is, who it serves, and the rules every plan and spec derives from.
stage: living
generated:
  by: claude-code/opus-5.5
  at: 2026-10-16T16:52:00Z
sources:
- id: flake
  resource: flake.nix
  title: flake inputs and outputs
- id: inventory
  resource: den/inventory.nix
  title: typed host inventory
- id: arch
  resource: docs/architecture.md
  title: configuration architecture
- id: agents
  resource: AGENTS.md
  title: repository workflows
---

# Product

## What is it

A single Nix flake that declares every machine and user environment the author
runs: NixOS systems and Home Manager homes for a personal fleet, built from
Den's feature-first aspect graph. A host is a short list of typed facts and
aspects; Den resolves those into NixOS and Home Manager module graphs, and the
flake exposes the resulting configurations, checks, and Clan deployments
(`docs/architecture.md`). It also carries the author's agent tooling — skills,
MCP servers, hooks, and the `ci` landing workflow — so the same repository
configures the agents that change it (`AGENTS.md`).

## Users

- **The author**, on their own machines: every host in the inventory is
  personal, and a win is a fleet that stays reproducible and switches without
  surprises.
- **Agents working on the author's behalf** (Claude Code, Codex, Copilot, and
  others): first-class users that read, change, check, and land this repository,
  so its instructions, skills, and tooling are product surface, not incidental
  files.

Not for:

- **Anyone adopting it as a framework.** It is not a reusable distribution or
  starter kit; nothing here promises outsiders support or a stable interface.
- **Non-NixOS hosts.** No nix-darwin, macOS, or non-NixOS Linux targets.

## Platforms

All hosts are `x86_64-linux` NixOS (`den/inventory.nix`).

- **asus** — the AMD laptop workstation: Niri desktop, development, XR, and
  remote tooling; deployed in place with `clan machines update`, with a
  45-second staged-switch watch.
- **asus-usb** — the same workstation profile on removable media; `disposable`,
  so it evaluates in `remoteChecks` rather than the landing gate.
- **asus-headless** — the asus hardware as a server with no desktop.
- **homelab** — the `critical` Intel server and canary: it auto-deploys each
  landing of `main` through the staged-switch watch, with `ssh` and `tailscale`
  health checks, and runs the shell home only.

Changes are delivered through Tangled: a topic lands on `main` through the local
`ci land` gate, then a host switches with `system-switch` (or `home-activate`
when the NixOS toplevel is unchanged). Deliberately unsupported: nix-darwin,
macOS, and non-NixOS Linux.

## Stack

- **Nix flake** on nixpkgs (via FlakeHub), Home Manager, Den v0.18 for host
  composition, Clan for push deployment, impermanence, and the Niri flake
  (`flake.nix`).
- **Nushell** for scripts, deploy logic (`deploy/switch.nu`), and the `ci`
  workflow; Jujutsu for version control on Tangled.
- **Layout**: `den/` owns the inventory, aspects, and host composition; `hosts/`
  holds hardware and storage facts only; `modules/` holds ordinary NixOS and
  Home Manager modules the aspects consume; `lib/` holds helpers such as
  `wrap-with-config.nix`; `deploy/` holds the staged-switch scripts; `tests/`
  and `tests.nix` hold VM and evaluation tests; `.agents/skills/` holds
  provider-neutral agent skills; `docs/` holds design notes, and `docs/project/`
  is this graph.
- **Build and check**: Checkmate formats the repository; prek runs the
  pre-commit gates; `ci preflight` runs them on a topic; flake `checks` evaluate
  every declared host and the Home Manager activation graph, while
  `remoteChecks` run after push without blocking.

## Constraints

From `docs/architecture.md`:

- No activation is implied by evaluation or a build: a system or home activation
  needs an explicit operator decision, except homelab's standing canary
  auto-deploy.
- A NixOS generation is warranted only when the candidate toplevel's store path
  differs from `/run/current-system`.
- Hardware, storage, boot, encryption, and generated machine files stay under
  `hosts/`; reusable aspects never infer or rewrite them.
- Programs that rewrite their own configuration keep it as runtime state, not
  Home Manager links; configuration that can ride on the executable ships with
  the package through `lib/wrap-with-config.nix`.
- Programs that agents run must keep their configuration visible inside the
  Claude Desktop sandbox: `/nix/store` and `/etc/profiles/per-user`, not `/etc`.

From the author:

- **Agent sandbox compatibility.** Everything agents run must work inside the
  Claude Desktop sandbox: no `sudo`, and only paths the sandbox can see.
- **Secrets stay encrypted.** Secrets live only as age-encrypted files in
  `secrets/`; plaintext never reaches the Nix store, agent or CI logs, or the
  public knowledge base.
- **Prefer the binary cache.** Avoid overrides and patches that force a local
  rebuild of a large package when a cached build exists.

## Authoring rules

- **Every document** — summarize and link to `docs/*.md` and the code rather
  than restating them; the graph records state and decisions, while the design
  detail stays in its existing home.

## Changelog

- 2026-10-16 — vendored from iwe-org/dev-workspace; drafted What is it,
  Platforms, Stack, and Constraints from the code, then filled Users,
  Constraints, and Authoring rules from the setup interview.
