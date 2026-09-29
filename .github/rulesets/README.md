# GitHub rulesets

These JSON files are export/import sources for the repository ruleset UI and
REST API; GitHub does not automatically apply files committed under `.github`.

`main-checks.json` describes the active personal-repository ruleset. Required
checks live in the classic branch protection that `ci github reconcile`
manages; they are not strict, so a PR need not be up to date with `main`.

`main-checks-merge-queue.json` is the queue profile for when this repository is
owned by an organization or otherwise runs on a GitHub plan that supports merge
queues. It pairs with the `merge_group` trigger in `nix-ci.yml`. Apply it only
after confirming the account supports merge queues; the queue then owns
freshness testing.

The queue keeps one entry per build and merge with squash. Each queued PR
therefore becomes one commit on `main`, and each behavior or breaking commit
gets its own CalVer release. The `impact classification` check runs on the pull
request only; it is skipped for queue groups because the queue merges exactly
the commits that were classified.
