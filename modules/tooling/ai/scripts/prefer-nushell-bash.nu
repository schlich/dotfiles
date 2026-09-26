#!/usr/bin/env nu

# Commands that already run through personal automation (not raw shell
# pipelines) and shouldn't be asked about again here.
const exempt_pattern = '(^|[;&|][&|]?|\n)\s*(jev\b|nu\s+(/home/schlich/dotfiles-jev|~/dotfiles-jev)/jev/jev\.nu\b)'
const ask_reason = "Prefer the nushell MCP tool (mcp__plugin_hm_nushell__evaluate) for shell pipelines and text processing; use Bash only when nushell can't do this."

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
  let payload = (open --raw /dev/stdin | from json)
  let command = (extract-command $payload)

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
