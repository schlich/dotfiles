---
type: architecture
description: GitHub's main is the trunk that `ci land` fast-forwards, gated by a required `ci land` status; Tangled only mirrors main.
generated:
  by: claude-code/opus-5.5
  at: 2026-10-19T07:45:00Z
sources:
- id: vcs
  resource: modules/programs/vcs.nix
  title: The jj scope that names trunk() and the push remote
- id: system-switch
  resource: modules/nixos/system-switch.nix
  title: The repository the staged switch and generation read
- id: ruleset
  resource: .github/rulesets/main-checks.json
  title: The ruleset that requires the ci land status
---

# GitHub trunk

On 2026-10-19 the trunk moved from Tangled back to GitHub. Tangled had held
`main` and every topic since 2026-09-26, but its spindle never passed a run,
pushes did not start it, and nixbot and GitHub Actions need GitHub anyway, so
two forges were maintained for one repository.

- `trunk()` is `main@origin`, and `ci dispatch` pushes topics to GitHub only.
- `ci land` is unchanged in what it proves: it rebases onto trunk, clears the
  exact head (the local flake checks by default), and fast-forwards `main`.
  Before the push it sets the `ci land` commit status on that head. The
  `main-checks` ruleset requires that status, blocks deletion and
  non-fast-forward pushes, has no bypass actors, and asks for no pull request,
  so only commits `ci land` cleared reach `main`. GitHub pull requests are for
  review and are never merged.
- After landing, `ci` pushes `main` and each new release tag to every other
  trunk remote, here Tangled. A failed mirror push is reported and does not undo
  the landing.
- `nixos-switch-main`, its canary timer, and `generation` read
  `https://github.com/schlich/dotfiles`. Their logs key revisions by commit,
  which is the same on both forges, so nothing was migrated.

Rejected: keeping Tangled as trunk with GitHub as the mirror (the status quo),
and protecting GitHub's `main` with no required check (the ruleset could not
tell a cleared commit from any other fast-forward). The `ci` repository itself
stays on Tangled until this setup has proved itself.
