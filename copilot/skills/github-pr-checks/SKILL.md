---
name: github-pr-checks
description: Wait for required GitHub pull request checks to finish and report their final result without arbitrary sleeps or repeated status polling.
---

# GitHub PR check completion

Use this skill after pushing a pull request when the next action depends on its
required checks completing.

Run this from the branch associated with the pull request:

```nu
gh pr checks --required --watch --fail-fast
```

The command remains active until all required checks finish. Its completion is
delivered back to the Copilot session, so do not use `sleep`, scheduled prompts,
or a hand-written polling loop before checking again.

- A zero exit status means every required check passed; continue with the
  requested post-CI action.
- A nonzero status means a check failed or was cancelled; inspect the command
  output and report the failure rather than treating the pull request as ready.
- Supply the PR number or URL as the final argument when the current branch
  does not identify the intended pull request.

GitHub webhooks cannot directly wake a local interactive Copilot CLI process:
the CLI has no repository-configurable inbound webhook endpoint. Do not add a
public webhook listener or store a webhook secret merely to wait for PR checks.
