---
name: jj-ci
description: Use the repository's jj-ci workflow to inspect, synchronize, validate, publish, and reconcile JJ changes. Apply when jj-ci is available; do not use it as a generic Jujutsu tutorial.
---

# jj-ci workflow

Use this skill when the repository provides the `jj-ci` command. It is the
repository's policy layer around Jujutsu, Prek, GitHub pull requests, and the
trunk workflow.

## Before acting

- Start with `jj status`, `jj diff`, and a focused `jj log` for the current
  change and its ancestors.
- Preserve unrelated working-copy changes. Jujutsu has no staging area, so
  every file in the working copy belongs to the current change unless the
  user says otherwise.
- Treat change IDs as the stable identity of a change and commit IDs as
  content hashes that can change when the change is rewritten.
- Inspect conflicts and emptiness before choosing a workflow.
- Before a synchronization that rebases history, create a checkpoint with
  `.agents/skills/jj/scripts/jj-checkpoint`.

## Command routing

Use the narrowest workflow that matches the request:

| User intent | Command | Notes |
| --- | --- | --- |
| Inspect local and open-PR state | `jj-ci status` | Read-only, but includes GitHub PR state. |
| Align an empty working copy with trunk | `jj-ci sync` | Fetches `origin`, advances `main`, and rebases onto `main@origin`. |
| Check readiness and run repository gates | `jj-ci validate` | Describes an undescribed change, runs `jj fix -s @`, then `prek run --all-files`. |
| Publish the current change | `jj-ci publish` | Validates, creates or updates a bookmark and PR, then starts a follow-up change. |
| Publish and request auto-merge | `jj-ci publish --auto-merge` | Requires an explicit user request because it changes GitHub PR state. |
| Inspect declared GitHub policy | `jj-ci github reconcile` | Dry run by default. |
| Apply GitHub policy changes | `jj-ci github reconcile --apply` | Requires an explicit user request. |
| Submit a validated PR stack | `jj-ci stack-merge <stack-or-pr>` | Requires an explicit user request and an already-ready stack. |

## Safety rules

- Do not run `jj-ci sync` while preserving an unreviewed assumption about the
  current change. If the working copy is non-empty, explain that sync starts
  a fresh empty change first and preserves the existing change above it.
- Do not publish an empty or conflicted change. `jj-ci publish` enforces this,
  but inspect the state first so the user understands the blocker.
- Do not add `--auto-merge`, use `github reconcile --apply`, or run
  `stack-merge` unless the user explicitly asks for that external mutation.
- Do not activate NixOS or Home Manager configuration as part of validation.
  If configuration changes are ready, report the appropriate activation command
  and request approval separately.
- Prefer `jj-ci` over manually reproducing its fetch, bookmark, push, PR, and
  validation sequence. Use raw JJ commands only for focused inspection or when
  the user explicitly asks for a different history operation.

## Publication expectations

`jj-ci publish` derives a short bookmark from the first line of the current
change description, pushes it to `origin`, creates or updates the PR, and
starts an empty follow-up change. Report the PR URL and the new current change
after publication.

For stacked work, inspect the stack before acting. Use the repository's JJ and
GitHub stack workflow; do not bypass it with direct branch or merge commands.
