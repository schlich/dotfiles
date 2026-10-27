# GitHub rulesets

These JSON files are export/import sources for the repository ruleset UI and
REST API; GitHub does not automatically apply files committed under `.github`.

GitHub (`origin`) holds `main`, `luvus/integration`, and any branch pushed
for review. `luvus-deliver` is the only way to `main`: it fast-forwards it to
the exact commit of `luvus/integration` that nixbot built, so this repository
never merges a pull request on GitHub. Squash, rebase, and merge commits all
rewrite or bypass the commit that nixbot tested.

`main-checks.json` describes the active personal-repository ruleset. It blocks
deleting `main` and rewriting it with a non-fast-forward push, and it requires
the `nixbot/nix-eval` and `nixbot/nix-build` check runs, which nixbot on
homelab reports on every commit it builds (`docs/nixbot.md`). Each names
nixbot's GitHub App as its `integration_id`, so only that App can satisfy it.
That admits only commits nixbot built, without a pull request rule, which
would reject the push. GitHub Actions still builds every push but gates
nothing. It has no bypass actors. GitHub requires at least one merge method to stay enabled, so nothing
here can stop a pull request from being merged; that rule lives in
`AGENTS.md`.

Apply it with `gh api --method PUT repos/schlich/dotfiles/rulesets/17738995 --input .github/rulesets/main-checks.json`.
