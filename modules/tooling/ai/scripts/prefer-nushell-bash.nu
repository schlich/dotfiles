#!/usr/bin/env -S nu --stdin

# Commands that already run through personal automation (not raw shell
# pipelines) and shouldn't be asked about again here.
const exempt_pattern = '(^|[;&|][&|]?|\n)\s*(jev\b|nu\s+(/home/schlich/dotfiles-jev|~/dotfiles-jev)/jev/jev\.nu\b)'

# IWE memory writes pass a note to `iwe create --content -` as a heredoc; its
# prose lines would otherwise read as pipeline stages.
const iwe_pattern = '^\s*iwe\s'

# Read-only file and text tools with a direct structured Nushell equivalent.
# Any command stage that starts with one of these is denied without a model
# call; Jev classifies everything else.
const text_tools = [
  awk cat cut egrep fd fgrep find grep head jq less ls more rg sed sort tail tr uniq wc yq
]

const deny_reason = "Run this in the Nushell MCP tool (mcp__plugin_hm_nushell__evaluate) instead of Bash, rewriting the text tools as structured Nushell (open, ls, glob, lines, where, parse, from json; slice $history afterwards instead of capping output). For large files, logs, or command output, keep the data in a Nushell variable and follow the rlm skill (rlm load, rlm find, rlm peek, rlm map) rather than printing it."

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

# First program of each pipeline stage or sequenced command, skipping leading
# `VAR=value` assignments and `sudo`/`env`/`command`/`exec` prefixes.
def stage-programs [command: string] {
  $command
  | split row --regex '\|\|?|&&|;|\n|[()`]'
  | each {|stage|
    $stage
    | str trim
    | split row --regex '\s+'
    | skip while {|word| $word =~ '^[A-Za-z_][A-Za-z0-9_]*=' or $word in [sudo env command exec] }
    | get -o 0
    | default ""
    | path basename
  }
  | where {|program| $program != "" }
}

def decide [decision: string, reason: string] {
  print (
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse"
        permissionDecision: $decision
        permissionDecisionReason: $reason
      }
    } | to json --raw
  )
}

def main [] {
  let input = $in
  let parsed = (try {
    { command: (extract-command (parse-payload $input)) }
  } catch { |err|
    { error: $err.msg }
  })

  if ($parsed.error? != null) {
    print --stderr $"prefer-nushell: ($parsed.error)"
    decide "ask" $"The prefer-nushell guard could not inspect this command: ($parsed.error). Confirm before running it."
    return
  }

  if ($parsed.command =~ $exempt_pattern) or ($parsed.command =~ $iwe_pattern) {
    return
  }

  let matched = (stage-programs $parsed.command | where {|program| $program in $text_tools } | uniq)

  # Stay silent otherwise so Jev and the normal permission flow decide.
  if ($matched | is-not-empty) {
    decide "deny" $"Bash call uses ($matched | str join ', '). ($deny_reason)"
  }
}
