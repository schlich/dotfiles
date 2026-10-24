---
type: architecture
description: The `ci` trunk workflow applies only in a repository whose jj config sets `ci.enable = true`; every other repository uses plain jj.
generated:
  by: claude-code/opus-5.5
  at: 2026-10-24T20:00:00Z
sources:
- id: ci-module
  resource: modules/programs/ci.nix
  title: The opt-in option, its jj scope, and ci-enabled
- id: hooks
  resource: modules/tooling/ai/scripts/only-in-ci-repos.nu
  title: The wrapper around ci's Claude Code hooks
- id: instructions
  resource: modules/tooling/ai/global-agent-instructions.md
  title: The agent instructions' Jujutsu section
- id: readme
  resource: jj/README.md
  title: How a repository opts in
---

# ci opt-in

On 2026-10-24 an agent ran `ci rebase` and `ci dispatch` in a brand-new project:
the agent instructions said to use `ci` wherever the command was installed, and
the session-start note named the next `ci` step in every JJ workspace. The
author ruled that the workflow must be opt-in per repository.

- The one signal is the jj config key `ci.enable = true`. A clone opts in with
  `jj config set --repo ci.enable true`; `dotfiles.ci.repositories` opts in a
  path through a `--when.repositories` scope in the wrapped jj's config, and
  lists the repositories that used `ci` that day. jj resolves both alike, the
  way `ci` already finds `trunk()`.
- `ci-enabled` reads the key. ci's Claude Code hooks run only for an opted-in
  repository (the edited file's, for the edit guard; the session's directory,
  otherwise) and never for a session started in
  `dotfiles.tooling.gitWorkflowRepos`. The prompt's ci segment and the shell's
  readout on entering a workspace show only there.
- The agent instructions apply the `ci` rules only in an opted-in repository;
  elsewhere agents use plain jj and never run `ci`. `tangled-init` sets no
  `ci.enable`.

Rejected: a `ci` flake input as the signal (this repository has the input but
takes writes through Git and luvus, and the ci repository has none); a list in
Nix alone (a clone could not opt itself in); a file committed to the repository
(it would opt in every collaborator's clone, and `ci` reads no such file).
Making `ci` refuse to run outside an opted-in repository would belong in the ci
repository and is not done. The `ci` skill, which the `ci` input provides from
release 2026.10.24.1, applies itself only in an opted-in repository and
documents opting in and out in its Setup section.
