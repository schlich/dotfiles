#!/usr/bin/env -S nu --stdin

# Nushell spells an external call `^git` and nests one as `(git ...)`.
const mutating_git_pattern = '(^|[;&|(][&|]?|\n)\s*\^?git\s+(add|am|apply|bisect|branch|checkout|cherry-pick|clean|commit|merge|mv|pull|push|rebase|reset|restore|revert|rm|stash|switch|tag|worktree)\b'
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

# Copilot sends `toolArgs`; Claude Code sends `tool_input`. A shell tool names
# its script `command`; the Nushell MCP tool names it `input`.
def extract-command [payload: any] {
  let tool_args = if (($payload | describe | str starts-with "record")) {
    $payload | get -o toolArgs | default ($payload | get -o tool_input) | default null
  } else {
    null
  }

  if (($tool_args | describe | str starts-with "record")) {
    let command = ($tool_args | get -o command | default ($tool_args | get -o input) | default null)

    if (($command | describe) == "string") {
      $command
    } else {
      ""
    }
  } else {
    ""
  }
}

# The repository's shared Git directory, which its main checkout and every
# linked worktree, wherever it lives, have in common; null outside Git, and
# when git cannot run at all, so the guard then denies as before.
def git-common-dir [dir: string] {
  if ($dir | is-empty) or not ($dir | path exists) { return null }
  let result = (try { ^git -C $dir rev-parse --path-format=absolute --git-common-dir | complete } catch { null })
  if $result != null and $result.exit_code == 0 { $result.stdout | str trim } else { null }
}

# A session started inside a repository that takes Git writes, such as one
# luvus drives, may run them. Only consulted for a mutating command, so
# ordinary calls spawn no git.
def git-writes-allowed [payload: record, repos: list<string>] {
  if ($repos | is-empty) { return false }
  let common = (git-common-dir ($payload.cwd? | default ""))
  if $common == null { return false }
  $repos | any {|repo| (git-common-dir ($repo | path expand)) == $common }
}

def main [
  --claude # Emit Claude Code's PreToolUse response shape
  ...git_repos: string # Repositories that use Git, not jj, for writes
] {
  let input = $in
  let result = (try {
    let payload = (parse-payload $input)
    let mutating = ((extract-command $payload) =~ $mutating_git_pattern)
    { denied: ($mutating and not (git-writes-allowed $payload $git_repos)) }
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
