#!/usr/bin/env -S nu --stdin

const mutating_git_pattern = '(^|[;&|][&|]?|\n)\s*git\s+(add|am|apply|bisect|branch|checkout|cherry-pick|clean|commit|merge|mv|pull|push|rebase|reset|restore|revert|rm|stash|switch|tag|worktree)\b'
const jj_write_reason = "This repository uses jj for write operations. Use the jj equivalent instead of mutating history or the working copy with git."

# Hook runners spawn this script with a socket for stdin, and Linux cannot
# reopen a socket through /dev/stdin, so read the payload from `$in`. That
# requires running under `nu --stdin`.
def parse-payload [input: any] {
  if ($input | describe) == "nothing" {
    error make { msg: "no hook payload on stdin; run this hook with `nu --stdin`" }
  }
  # `from json` accepts bare words and empty input, so require an object.
  let payload = ($input | into string | from json)
  if not ($payload | describe | str starts-with "record") {
    error make { msg: $"hook payload is not a JSON object \(got ($payload | describe)\)" }
  }
  $payload
}

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
  let input = $in
  let result = (try {
    { denied: ((extract-command (parse-payload $input)) =~ $mutating_git_pattern) }
  } catch { |err|
    { error: $err.msg }
  })

  # A guard that cannot inspect the command must not silently allow it.
  let decision = if ($result.error? != null) {
    print --stderr $"guard-git-writes: ($result.error)"
    {
      permissionDecision: "ask"
      permissionDecisionReason: $"The jj write guard could not inspect this command: ($result.error). Confirm before running it."
    }
  } else if $result.denied {
    { permissionDecision: "deny", permissionDecisionReason: $jj_write_reason }
  } else {
    null
  }

  if $claude {
    # Stay silent on allow so Claude Code's normal permission flow applies.
    if $decision != null {
      print ({ hookSpecificOutput: ({ hookEventName: "PreToolUse" } | merge $decision) } | to json --raw)
    }
  } else {
    print ($decision | default { permissionDecision: "allow" } | to json --raw)
  }
}
