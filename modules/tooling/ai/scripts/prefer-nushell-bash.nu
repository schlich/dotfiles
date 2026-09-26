#!/usr/bin/env -S nu --stdin

# Commands that already run through personal automation (not raw shell
# pipelines) and shouldn't be asked about again here.
const exempt_pattern = '(^|[;&|][&|]?|\n)\s*(jev\b|nu\s+(/home/schlich/dotfiles-jev|~/dotfiles-jev)/jev/jev\.nu\b)'
const ask_reason = "Prefer the nushell MCP tool (mcp__plugin_hm_nushell__evaluate) for shell pipelines and text processing; use Bash only when nushell can't do this."

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

def extract-command [payload: any] {
  let tool_args = ($payload | get -o tool_input | default null)

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

def main [] {
  let input = $in
  let command = (try {
    extract-command (parse-payload $input)
  } catch { |err|
    # Asking is this hook's default, so an unreadable payload only loses the exemption.
    print --stderr $"prefer-nushell: ($err.msg)"
    ""
  })

  # Stay silent on exempt commands so Claude Code's normal permission flow applies.
  if not ($command =~ $exempt_pattern) {
    print (
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse"
          permissionDecision: "ask"
          permissionDecisionReason: $ask_reason
        }
      } | to json --raw
    )
  }
}
