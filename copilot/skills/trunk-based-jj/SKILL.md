---
name: trunk-based-jj
description: "Use for JJ-first trunk development and Nix flake changes in schlich/dotfiles: inspect or sync main, edit NixOS or Home Manager configuration, validate with Prek and Nix, publish a GitHub PR, monitor CI, use merge queues, or inspect JJ-managed stacks."
---

# JJ-first trunk development

Use this skill for repository changes that should land through `main`.

## Boundaries

| Surface | Owns | Must not own |
| --- | --- | --- |
| JJ | Changes, descriptions, bookmarks, rebases, pushes, conflict resolution | GitHub PR merging |
| Git | Read-only inspection and the backend used by JJ | Mutating working copies or history |
| GitHub | PRs, required checks, auto-merge, merge queues, stacked-PR metadata | Local history surgery |

Run `jj status`, `jj diff`, and `jj log` before work. Keep unrelated changes
intact. Use `jj-ci sync` only from an empty working copy and run
`jj-ci validate` before publication.

## Nix flake changes

Preserve the repository's modular flake structure unless the user explicitly
requests an architecture migration. Read `flake.nix`, the affected module, and
nearby conventions before editing. Do not introduce the Dendritic Pattern as
part of an unrelated change; adopting it requires deliberate top-level options,
automatic module imports, and removal of cross-layer `specialArgs` plumbing.

Query current packages, options, flakes, and cache information through the Nix
MCP tools rather than relying on remembered names or versions. Keep input and
lock-file changes intentional, format Nix edits with `nix fmt`, and run the
smallest relevant build:

```nu
nix build .#homeConfigurations.schlich.activationPackage
nix build .#nixosConfigurations.asus.config.system.build.toplevel
```

Use the Home Manager build for home-level changes and the NixOS build for
system changes. Do not activate or switch a configuration unless requested.

## Publication

1. Describe and locally validate the current JJ change.
2. Run `jj-ci publish --auto-merge`.
3. Let GitHub merge a same-repository non-draft PR only after required checks
   pass against the current head SHA.
4. Use `jj-ci github reconcile` to inspect GitHub policy. Use `--apply` only
   when explicitly reconciling the flake-declared repository defaults.

Successful publication starts an empty child changeset. Make later edits there
so they do not rewrite the pushed revision; explicitly return to the published
changeset only when intentionally updating its PR.

## Stacked PRs

Use stacks only for a preplanned chain of dependent, independently reviewable JJ
changes. Create, describe, rebase, and push each layer with JJ. Link the already
managed branches to GitHub with `gh stack link`, and inspect only with:

```nu
gh stack view --json
```

After every layer's required checks is green at its current head, use:

```nu
jj-ci stack-merge <stack-or-pr>
```

This submits the stack to GitHub's merge queue. Never use `gh stack init`, `add`,
`submit`, `sync`, or `rebase` because they mutate Git-managed branches.

## GPT-5.6 Luna

Delegate only status triage, PR/CI summaries, stack inspection, and
formatting-only fixes to the `trunk-triage` agent. Escalate any configuration
edit, conflict, validation failure, JJ mutation, GitHub write, or merge decision
to the primary agent.
