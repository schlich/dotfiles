---
name: trunk-based-jj
description: "Use for JJ-first trunk development in schlich/dotfiles: inspect or sync main, validate with Prek, publish a JJ change as a GitHub PR, monitor CI, use GitHub merge queues, or inspect JJ-managed stacked PRs."
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
intact. Use `jj-trunk sync` only from an empty working copy and run
`jj-trunk validate` before publication.

## Publication

1. Describe and locally validate the current JJ change.
2. Run `jj-trunk publish --auto-merge`.
3. Let GitHub merge a same-repository non-draft PR only after required checks
   pass against the current head SHA.
4. Use `jj-trunk github reconcile` to inspect GitHub policy. Use `--apply` only
   when explicitly reconciling the flake-declared repository defaults.

## Stacked PRs

Use stacks only for a preplanned chain of dependent, independently reviewable JJ
changes. Create, describe, rebase, and push each layer with JJ. Link the already
managed branches to GitHub with `gh stack link`, and inspect only with:

```nu
gh stack view --json
```

After every layer's required checks is green at its current head, use:

```nu
jj-trunk stack-merge <stack-or-pr>
```

This submits the stack to GitHub's merge queue. Never use `gh stack init`, `add`,
`submit`, `sync`, or `rebase` because they mutate Git-managed branches.

## GPT-5.6 Luna

Delegate only status triage, PR/CI summaries, stack inspection, and
formatting-only fixes to the `trunk-triage` agent. Escalate any configuration
edit, conflict, validation failure, JJ mutation, GitHub write, or merge decision
to the primary agent.
