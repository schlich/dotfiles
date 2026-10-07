# GitHub rulesets

These JSON files are export/import sources for the repository ruleset UI and
REST API; GitHub does not automatically apply files committed under `.github`.

GitHub (`origin`) only mirrors `main`. `ci land` delivers to Tangled and then
fast-forwards GitHub's `main` to the same commit, so this repository never
merges a pull request on GitHub: squash, rebase, and merge commits all rewrite
or bypass the commit that the landing clearance tested.

`main-checks.json` describes the active personal-repository ruleset. It only
blocks deleting `main` and rewriting it with a non-fast-forward push. It sets
no required checks or pull request rule, because either would also reject the
mirror push from `ci land`. GitHub requires at least one merge method to stay
enabled, so nothing here can stop a pull request from being merged; that rule
lives in `AGENTS.md`.
