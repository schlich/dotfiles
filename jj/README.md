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
