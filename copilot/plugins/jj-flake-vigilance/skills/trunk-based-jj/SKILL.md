---
name: trunk-based-jj
description: Use for JJ-first trunk development, Prek validation, GitHub PR publication, merge queues, and JJ-managed stacked pull requests in schlich/dotfiles.
---

# JJ-first trunk development

Use JJ for changes, descriptions, bookmarks, rebases, pushes, and conflict
resolution. Use Git only for read-only inspection. Use GitHub for PRs, required
checks, auto-merge, merge queues, and stacked-PR metadata.

Run `jj status`, `jj diff`, and `jj log` first. From a described conflict-free
change, run `jj-trunk validate`, then `jj-trunk publish --auto-merge`.

For an explicitly planned dependency stack, create and push each layer with JJ,
link existing PRs using `gh stack link`, inspect only with `gh stack view --json`,
and after every current head is green run:

```nu
jj-trunk stack-merge <stack-or-pr>
```

Never use `gh stack init`, `add`, `submit`, `sync`, or `rebase`; those mutate
Git branches rather than JJ changes.

Use the GPT-5.6 Luna triage agent only for status, CI/PR summaries, stack
inspection, and formatting-only fixes. Escalate all writes and decisions.
