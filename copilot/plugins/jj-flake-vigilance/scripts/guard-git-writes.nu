#!/usr/bin/env nu

const mutating_git_pattern = '(^|[;&|][&|]?|\n)\s*git\s+(add|am|apply|bisect|branch|checkout|cherry-pick|clean|commit|merge|mv|pull|push|rebase|reset|restore|revert|rm|stash|switch|tag|worktree)\b'
const jj_write_reason = "This repository uses jj for write operations. Use the jj equivalent instead of mutating history or the working copy with git."

# Copilot sends `toolArgs`; Claude Code sends `tool_input`.
def extract-command [payload: any] {
  let tool_args = if (($payload | describe | str starts-with "record")) {
    $payload | get -o toolArgs | default ($payload | get -o tool_input) | default null
  } else {
    null
  }

  if (($tool_args | describe | str starts-with "record")) {
    let command = ($tool_args | get -o command | default null)

    if (($command | describe) == "string") {
      $command
    } else {
      ""
    }
  } else {
    ""
  }
}

def main [
  --claude # Emit Claude Code's PreToolUse response shape
] {
  let payload = (open --raw /dev/stdin | from json)
  let command = (extract-command $payload)
  let denied = ($command =~ $mutating_git_pattern)

  if $claude {
    # Stay silent on allow so Claude Code's normal permission flow applies.
    if $denied {
      print ({
        hookSpecificOutput: {
          hookEventName: "PreToolUse"
          permissionDecision: "deny"
          permissionDecisionReason: $jj_write_reason
        }
      } | to json --raw)
    }
  } else {
    let response = if $denied {
      {
        permissionDecision: "deny"
        permissionDecisionReason: $jj_write_reason
      }
    } else {
      { permissionDecision: "allow" }
    }

    print ($response | to json --raw)
  }
}
