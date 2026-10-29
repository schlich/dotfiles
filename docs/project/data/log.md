# Project Update Log

The history of this workspace, newest first. The `ship` skill appends a dated
group on every release; any skill that creates or retires a document adds a line
to the current day's group.

## 2026-10-29

- **Bug**: [nixbot roots only jj topics](bugs/nixbot-roots-only-jj-topics.md);
  `branches.topics` now matches the `luvus/*` branches nixbot builds.
- **Delivery**: The product page, the nixbot, homelab-builds, and
  session-environment docs, and the pull request template describe the luvus
  gate, `luvus-deliver`, and nixbot instead of `ci land`.
- **Architecture**: Recorded [delivery risk](architecture/delivery-risk.md):
  `luvus-deliver` classifies each delivery with Jev and holds a high-risk one
  for the owner's approval of that exact commit.

## 2026-10-27

- **Delivery**: Landed the work left open when this repository moved from jj and
  `ci` to Git and luvus: `nix-fast-build` and a worktree-safe
  `den-inventory-tests` for the luvus gate, luvus's PATH order, niri's
  left-aligned columns and slower scrolling, the keymap fixes, quieter agent
  output, the show-me skill, the Discord digest (off until its secret exists),
  the Cachix cache in CI, the staged switch's TLA+ model, Helix on homelab, and
  Zed's removal. The rest was closed as superseded or stale.
- **Delivery**:
  [Commute jj-graph's edits of one file](plans/20261020-jj-graph-commutation.md)
  done.

## 2026-10-24

- **Architecture**: Recorded [ci opt-in](architecture/ci-opt-in.md): the `ci`
  workflow, its hooks, and its prompt segment apply only where jj's config sets
  `ci.enable`; other repositories use plain jj.

## 2026-10-20

- **Plan**:
  [Commute jj-graph's edits of one file](plans/20261020-jj-graph-commutation.md);
  two changes that touch one file keep their order only when jj cannot move each
  past the other, with mergiraf as an opt-in structural fallback.
- **Delivery**:
  [Make nixbot's GitHub App and secrets declarative](plans/20261019-nixbot-app-declarative.md)
  done: release 2026.10.20.3 turned nixbot on at homelab, which builds every
  push and reports `nixbot/nix-eval` and `nixbot/nix-build` on GitHub.

## 2026-10-19

- **Plan**:
  [Make nixbot's GitHub App and secrets declarative](plans/20261019-nixbot-app-declarative.md);
  `nixbot-register` creates the App from the flake's manifest and stores its
  secrets with agenix for homelab.
- **Architecture**: Recorded [host secrets](architecture/host-secrets.md):
  agenix with each host's OpenSSH key, chosen over Clan vars for pull-based
  deploys.

## 2026-10-16

- **Bug**:
  [The CI dashboard's exploration hid the page behind a GitHub tab](bugs/ci-dashboard-exploration-hides-the-page.md);
  its keyboard actions no longer press links that open new tabs.
- **Delivery**: Added Stately's hosted MCP server to shared AI client
  configuration; it is available on `main`.
- **Delivery**: [Reactive CI and Nix dashboard](features/ci-nix-dashboard.md)
  implemented and deployed to homelab with tailnet-only HTTPS access; the live
  `/api/tower` feed returned fresh data.
- **Setup**: Vendored the workspace into the dotfiles repository at
  `docs/project/`; drafted [product](product.md) from the code and captured the
  [configuration factory](architecture/configuration-factory.md) architecture.
- **Onboarding**: Filled Users, Constraints, and Authoring rules in
  [product](product.md) from the setup interview and removed the example
  documents.
- **Architecture**: Recorded
  [generation provenance](architecture/generation-provenance.md): hosts log
  which commit produced each generation beside it, not in the closure.

## 2026-08-01

- **Initialization**: Created the project workspace — [product](product.md) as
  the foundation, with [plans](plans.md), [backlog](backlog.md),
  [milestones](milestone.md), and [someday](someday.md) for work, and
  [features](features.md), [bugs](bugs.md), and [releases](releases.md) for
  delivery.
- **Creation**: Seeded the reference side — [spec](spec.md),
  [codebase](codebase.md), [architecture](architecture.md), and
  [concept](concept.md) — with example documents showing the shape of each type.
