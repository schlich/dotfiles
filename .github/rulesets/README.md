# GitHub rulesets

These JSON files are export/import sources for the repository ruleset UI and
REST API; GitHub does not automatically apply files committed under `.github`.

`main-checks.json` describes the active personal-repository ruleset. The
repository currently has strict required checks and linear history enabled.

`main-checks-merge-queue.json` is the queue profile for when this repository is
owned by an organization or otherwise runs on a GitHub plan that supports merge
queues. It pairs with the `merge_group` trigger in `nix-ci.yml`. Apply it only
after confirming the account supports merge queues, then relax the redundant
strict up-to-date setting so the queue owns freshness testing.

The queue keeps one entry per build and merge with squash. Each queued PR
therefore becomes one commit on `main`, and each behavior or breaking commit
gets its own CalVer release. The `impact classification` check runs on the pull
request only; it is skipped for queue groups because the queue merges exactly
the commits that were classified.
