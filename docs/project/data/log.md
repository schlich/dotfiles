# Project Update Log

The history of this workspace, newest first. The `ship` skill appends a dated
group on every release; any skill that creates or retires a document adds a line
to the current day's group.

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
