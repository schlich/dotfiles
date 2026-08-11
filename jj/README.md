# Flake Update Flow

`jj-flake` keeps flake updates isolated from other work and sends them through
the protected `main` branch.

```nu
# Update everything, run the full check, and stop for review.
jj-flake update

# Update selected inputs only.
jj-flake update nixpkgs home-manager

# Publish the reviewed current change as a pull request.
jj-flake publish

# Update, publish, wait for CI, squash-merge, and sync in one command.
jj-flake update --merge
```

The command always starts from `main@origin`, requires an empty working-copy
change, and accepts only `flake.lock` as update output. A failed update or check
stays in the current JJ change for inspection. Use `jj undo` to reverse the last
repository operation or `jj abandon @` to discard a failed update.

`jj-flake sync` fetches `origin`, aligns the local `main` bookmark with
`main@origin`, and rebases an empty working-copy change. It leaves non-empty work
untouched.

## Trunk workflow

`jj-trunk` is the general JJ-first publication flow. It installs from this flake
with `prek` and `gh-stack`; Home Manager installs the Prek hook for this checkout.

```nu
# Inspect the local JJ change and open PRs.
jj-trunk status

# Update an empty working copy to origin/main.
jj-trunk sync

# Run deterministic local formatting and evaluation gates.
jj-trunk validate

# Push the current described JJ change, create/update its PR, and enable auto-merge.
jj-trunk publish --auto-merge

# Inspect GitHub settings, then explicitly reconcile safe repository defaults.
jj-trunk github reconcile
jj-trunk github reconcile --apply
```

Use JJ for all change, bookmark, rebase, and push operations. Git is for
read-only interoperability only. GitHub owns required checks, merge queues, and
delivery to `main`.

For an explicitly planned dependency stack, create and push the ordered JJ
bookmarks, link the existing PRs with `gh stack link`, inspect with
`gh stack view --json`, and submit the fully green stack with:

```nu
jj-trunk stack-merge <stack-or-pr>
```

Do not use `gh stack init`, `add`, `submit`, `sync`, or `rebase`: those commands
mutate Git-managed branches and bypass the JJ ownership boundary.
