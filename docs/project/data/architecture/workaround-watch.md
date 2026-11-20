---
type: architecture
description: Every package built here or taken from outside nixpkgs carries a watch entry a flake check enforces, and a daily timer queues a luvus task once nixpkgs, an upstream fix, or a public cache makes it unnecessary.
generated:
  by: claude-code/opus-5.5
  at: 2026-11-19T14:20:00Z
sources:
- id: module
  resource: modules/home/nix/nixpkgs-watch.nix
  title: The watch options, the status the timer reads, and the coverage check
- id: script
  resource: tools/nixpkgs-watch.nu
  title: The daily check, its upstream lookups, task queueing, and coverage
- id: tests
  resource: tests/nixpkgs-watch.nu
  title: The check against stubbed npr, gh, nix, curl, and luvus
---

# Workaround watch

On 2026-11-19 the author asked that every manual build be replaced once nixpkgs,
or a cached FlakeHub or Cachix build, could stand in for it, including overrides
that add something a later release ships. `dotfiles.nixpkgsWatch` already warned
at evaluation and ran a daily npr search, but only for entries someone
remembered to declare: a dozen workarounds had none (the codex fork, the nushell
0.116.0 override, HEX's and ai-usagebar's overrides, luvus's rewrap, acreom,
openchamber, sudoplz, jj-mcp, cross.stream, marimohub), and nushell's and fh's
had outlived nixpkgs catching up.

- **Coverage is a flake check.** `nixpkgs-watch-coverage` scans every Nix file
  for a flake input's package, a local build of upstream source, or an
  `overrideAttrs`, and fails on one nothing covers. An input needs an entry
  whose `input` names it (by default the entry's own name), or an exemption in
  `dotfiles.nixpkgsWatchExempt` for the user's own projects. A local build or
  override needs an entry declared in its file or named for it (`foo` for
  `foo-package.nix`), or a `# nixpkgs-watch:` comment that names an entry or
  says why it is no workaround.
- **Overrides watch an upstream `fix`.** An entry with a pull request or commit
  URL and no `version` is not ready merely because nixpkgs ships the package.
  The daily check reports the fix merged, then asks GitHub whether the release
  nixpkgs ships contains it, or for a package nixpkgs lacks, the locked input.
- **Caches are checked where follows defeat them.** An input that follows this
  flake's nixpkgs always builds here. The daily check evaluates upstream's own
  output at the locked revision with upstream's lock and asks cache.nixos.org,
  FlakeHub Cache, and any cache upstream's `nixConfig` declares for it. A local
  build's `repo` is looked up on FlakeHub and for a new `flake.nix`.
- **Replacements are queued, not started.** The timer adds a luvus task, with
  the declaring files as paths and the flake checks as its gate, for each
  workaround that nixpkgs, a released fix, or a cached build ends. It skips a
  title it filed before and one whose package and way out a task on the board
  already names, and retries after a failed add.

Rejected: comparing each installed package's store path with nixpkgs' at
evaluation (wrappers built with `lib/wrap-with-config.nix` differ by design, and
a package nixpkgs lacks has nothing to compare); a central list of workarounds
(it drifts from the code it describes, which the entry-beside-the-workaround
rule avoids); starting the replacement tasks automatically (a switch to
upstream's cache trades build time for a second nixpkgs in the closure, which
the author decides per package). The cache check stays limited to inputs that
follow this flake's nixpkgs, evaluated without import-from-derivation, so an
input such as atuin, whose flake needs IFD, reports an error rather than
building during the check.
