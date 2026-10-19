# GitHub rulesets

These JSON files are export/import sources for the repository ruleset UI and
REST API; GitHub does not automatically apply files committed under `.github`.

GitHub (`origin`) holds `main` and every `jj-*` topic branch. `ci land` is
the only way to `main`: it fast-forwards it to the exact commit its landing
clearance passed and then mirrors it to Tangled, so this repository never
merges a pull request on GitHub. Squash, rebase, and merge commits all rewrite
or bypass the commit that the clearance tested.

`main-checks.json` describes the active personal-repository ruleset. It blocks
deleting `main` and rewriting it with a non-fast-forward push, and it requires
the `ci land` commit status, which `ci land` sets on the head it cleared just
before pushing `main` to it. That admits only commits `ci land` cleared,
without a pull request rule, which would reject the push. It has no bypass
actors. GitHub requires at least one merge method to stay enabled, so nothing
here can stop a pull request from being merged; that rule lives in
`AGENTS.md`.

Apply it with `gh api --method PUT repos/schlich/dotfiles/rulesets/17738995 --input .github/rulesets/main-checks.json`.
