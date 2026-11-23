# Project Update Log

The history of this workspace, newest first. The `ship` skill appends a dated
group on every release; any skill that creates or retires a document adds a line
to the current day's group.

## 2026-11-23

- **Architecture**: [Embedded server homes](architecture/embedded-server-homes.md)
  records homelab's home moving into its system, so the canary deploys it;
  [Configuration factory](architecture/configuration-factory.md) keeps
  standalone homes for workstations.

## 2026-11-21

- **Retired**: [Reactive CI and Nix dashboard](features/ci-nix-dashboard.md).
  homelab stops serving it on the tailnet's 8443, and its source and its two
  checks are removed; Fieldnotes' CI panel covers the same view.
- **Architecture**: [Delivery risk](architecture/delivery-risk.md) no longer
  asks Jev. `luvus-deliver` stops for approval only on its approval paths,
  high- or critical-risk configuration reaching several hosts, or an unknown
  reach.

## 2026-11-19

- **Desktop**: Prepared the switch from Hex's upstream flake to the pinned
  nixpkgs `anomaly-hex` release. Home Manager provides the on-demand user unit
  used by the existing Niri shortcuts.
- **Architecture**: [Workaround watch](architecture/workaround-watch.md). A
  flake check now fails on a flake input's package, local build, or
  overrideAttrs that no `dotfiles.nixpkgsWatch` entry covers; entries gain an
  upstream `fix`, and the daily check also asks public caches for upstream's own
  build of an input and FlakeHub for a local build's repository. The timer
  queues a luvus task for each workaround that can go. Twelve workarounds that
  had no entry gained one.

## 2026-11-06

- **Delivery**: Updated every flake input; nixpkgs moved from 2026-10-15 to
  2026-11-03. Landing it took six fixes: hex's package override dropped (fixed
  upstream), the Tangled knot's operator email (a newly required option),
  marimohub patched without an RPATH (patchelf's edit made it segfault),
  tangled's lix flake-compat dropped (Nix 2.34 cannot refetch it, which failed
  nixbot's prefetch), tailscale serve units that wait for tailscaled (asus
  reverted the first switch over t3code-tailscale-serve), and nixpkgs' nushell
  0.116.1 for the MCP server.
- **Workflow**: The update spent most of its hours waiting on builds. Nothing
  built asus's system or home before a switch, so the switch built them on asus;
  flake inputs that follow nixpkgs rebuilt from source; failures surfaced one
  round at a time; and Claude restarts killed job-log jobs.
- **Workflow**: `gateChecks`, the flake checks plus asus's system and home, is
  what the luvus gate and nixbot build, so a closure that fails to build stops
  before delivery and the switch finds it built. fh and jj-starship come from
  nixpkgs' cache, `nix-suite update` passes gh's token to GitHub,
  `luvus-deliver` fast-forwards the local main that tasks branch from, and a
  den-config test requires tailscale serve and funnel units to wait for
  tailscaled (it caught homelab's nixbot-funnel).

## 2026-10-29

- **Desktop**: Prepared Noctalia Minimizer with Niri shortcuts and persistent
  hints; the change awaits validation and delivery.
- **Workflow**: Allow agents to resolve merge conflicts automatically when
  intent is clear, preserving both sides and rerunning checks; ask only for
  ambiguous intent or product decisions.
- **Bug**: [nixbot roots only jj topics](bugs/nixbot-roots-only-jj-topics.md);
  `branches.topics` now matches the `luvus/*` branches nixbot builds.
- **Delivery**: The product page, the nixbot, homelab-builds, and
  session-environment docs, and the pull request template describe the luvus
  gate, `luvus-deliver`, and nixbot instead of `ci land`.
- **Bug**:
  [The staged switch crashes on socket units](bugs/staged-switch-crashes-on-socket-units.md);
  homelab's dead-man reverted `807fe228` when nixbot.socket restarted, and the
  watch now judges units without a restart count or a result.
- **Delivery**: homelab runs the fixed watch since `1860874b`, delivered with
  nixbot's root rule held at `jj-*` so that the old watch could stage it; the
  delivery after it restores `luvus/*`.
- **Architecture**: Recorded [delivery risk](architecture/delivery-risk.md):
  `luvus-deliver` classifies each delivery with Jev and holds a high-risk one
  for the owner's approval of that exact commit.
- **Plan**: [Run the flake checks with Dagger](plans/20261029-dagger-ci.md);
  Dagger 1.0 beta runs `checks.x86_64-linux` locally and as Dagger Cloud Checks,
  beside nixbot and nix-ci.

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
