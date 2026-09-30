---
name: bash-feedback
description: Review the log of Claude Code Bash requests and turn repeated use cases into agent-instruction or Bash-policy changes in the dotfiles repository. Use when the user asks to review Bash denials, tune the Bash guard, or run the Bash feedback loop.
---

# Bash feedback loop

Claude Code's prefer-nushell hook denies foreground Bash unless
`modules/tooling/ai/bash-policy.nuon` allows it, and logs every Bash request
and its outcome. Denials show where the agent instructions fall short. Calls
that were allowed show which uses of Bash are legitimate. This skill reviews
the unreviewed part of the log and changes the dotfiles repository so the
next session needs Bash less often.

## When it starts on its own

A Stop hook (`claude-bash-audit stop-hook`) raises each use case, keyed by
rule and leading program, the first time a session logs it without a prior
review. It names those use cases and keeps the session going. Review only
the named use cases and keep it brief: the user was in the middle of other
work. Ask whether to review them now. If the user declines, stop. The use
cases stay in the report and are not raised again. Set
`CLAUDE_BASH_FEEDBACK=off` in headless or automated sessions to suppress
the hook.

## 1. Read the pending requests

Run in the Nushell evaluate tool:

```nu
^claude-bash-audit report --json | complete | get stdout | from json
```

The report lists clusters keyed by `rule` and leading `program`, with
counts, distinct sessions, outcomes, and example commands. `--all` includes
requests that were already reviewed. The raw JSONL log is at
`claude-bash-audit path`; load it with the rlm skill if it is large.

## 2. Classify each cluster

Decide what each cluster needs. Weigh clusters that recur across sessions
over one-off requests.

| Pattern | Change |
| --- | --- |
| Denied, and a Nushell rewrite is straightforward | Instruction gap. Add a concrete recipe or rule to `modules/tooling/ai/global-agent-instructions.md` ("Shell conventions") so the first attempt uses the evaluate tool. |
| Denied, and a dedicated MCP tool covers it (jj, GitHub, Nix) | Point the instruction at that tool by name. |
| Denied, but Bash is really needed, such as a TTY, sudo, or a harness-only feature | Add a narrow `allow` rule with a `why` to `bash-policy.nuon`. Anchor the regex and never allow a whole interpreter such as `bash -c`. |
| `text_tools` denial repeated inside background runs | Tell agents to write the log to the scratchpad and read it from Nushell. |
| Allowed, then ran, and Nushell would have worked | Consider tightening: remove or narrow the allow rule. |
| Denied or not run because the evaluate tool lacked a capability | Report the tooling gap to the user instead of loosening the policy. |

Keep instruction edits short and general. Describe the use case, not the
session that produced it, and never copy command lines that contain paths
or data from other projects into the repository.

## 3. Change the repository

Work in the dotfiles repository under its own rules: a dedicated JJ
workspace, `Impact: behavior` for instruction or policy changes, and
approval before activation. If `bash-policy.nuon` changes, add a case to
`modules/tooling/ai/tests/pretooluse-hooks.mjs` that the new rule
decides.

Present the proposed edits to the user with the clusters that motivated
them before publishing.

## 4. Close the review window

After the user accepts the changes, or decides a cluster needs none, run:

```nu
^claude-bash-audit mark-reviewed | complete
```

This records the newest log timestamp, so the next report starts after it,
and marks every logged use case as known, so the Stop hook stays quiet for
them.
Do not mark requests reviewed before the user has seen the clusters.
