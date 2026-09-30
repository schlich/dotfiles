#!/usr/bin/env -S nu --stdin

# Deny Claude Code Bash calls that belong in the Nushell MCP tool, and log
# every Bash request and outcome so denials can be reviewed with
# `claude-bash-audit report` and turned into instruction or policy changes.

# Mirrors jev's credential filter: such command lines are not logged verbatim.
const credential_pattern = '(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*='

const nushell_hint = "Run it in the Nushell MCP tool (mcp__plugin_hm_nushell__evaluate) instead, wrapping external programs in `| complete`."

const text_hint = "Rewrite the text tools as structured Nushell (open, ls, glob, lines, where, parse, from json; slice $history afterwards instead of capping output). For large files, logs, or command output, keep the data in a Nushell variable and follow the rlm skill (rlm load, rlm find, rlm peek, rlm map) rather than printing it."

const default_hint = "Foreground Bash is disabled. Long commands whose progress matters may use Bash with run_in_background, logging to the scratchpad. If this command truly needs Bash (a TTY, or a harness feature the evaluate tool lacks), stop and tell the user why; every Bash request is logged for review."

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

def tool-input [payload: record] {
  let tool_args = ($payload | get -o tool_input | default null)
  if ($tool_args | describe | str starts-with "record") { $tool_args } else { {} }
}

def extract-command [payload: record] {
  let command = ((tool-input $payload) | get -o command | default null)
  if ($command | describe) == "string" { $command } else { "" }
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

def log-path [] {
  if ($env.CLAUDE_BASH_LOG? | is-not-empty) {
    return $env.CLAUDE_BASH_LOG
  }
  let state = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
  $state | path join "claude-code" "bash-requests.jsonl"
}

# Logging must never change a decision, so failures go to stderr only.
def append-log [entry: record] {
  try {
    let path = (log-path)
    mkdir ($path | path dirname)
    $"($entry | to json --raw)\n" | save --append $path
  } catch {|err|
    print --stderr $"prefer-nushell: could not write the Bash log: ($err.msg)"
  }
}

def base-entry [payload: record, event: string] {
  let command = (extract-command $payload)
  {
    ts: (date now | format date "%+")
    event: $event
    session_id: ($payload.session_id? | default null)
    tool_use_id: ($payload.tool_use_id? | default null)
    agent_type: ($payload.agent_type? | default null)
    cwd: ($payload.cwd? | default null)
    command: (if $command =~ $credential_pattern { "[redacted: credential assignment]" } else { $command })
  }
}

# Classify a Bash request against the policy. `decision` is "deny", or
# "defer" to leave it to Jev and the normal permission flow.
def classify [command: string, background: bool, policy: record] {
  let permissive = ($env.CLAUDE_BASH_GUARD? | default "") == "permissive"
  let allowed = ($policy.allow | where {|rule| $command =~ $rule.pattern } | get -o 0)

  if ($allowed != null) and ($allowed.skip_text_tools? | default false) {
    return { decision: "defer", rule: $"allow: ($allowed.why)" }
  }

  let programs = (stage-programs $command)
  let matched = ($programs | where {|program| $program in $policy.text_tools } | uniq)
  if ($matched | is-not-empty) {
    return {
      decision: "deny"
      rule: "text_tools"
      matched: $matched
      reason: $"Bash call uses ($matched | str join ', '). ($nushell_hint) ($text_hint)"
    }
  }

  if $allowed != null {
    return { decision: "defer", rule: $"allow: ($allowed.why)" }
  }
  if $background {
    return { decision: "defer", rule: "background" }
  }
  if $permissive {
    return { decision: "defer", rule: "permissive" }
  }
  {
    decision: "deny"
    rule: "default"
    reason: $"($default_hint) ($nushell_hint)"
  }
}

def pre-tool-use [payload: record, policy: record] {
  let command = (extract-command $payload)
  let background = ((tool-input $payload) | get -o run_in_background | default false) == true
  let verdict = (classify $command $background $policy)

  append-log (
    (base-entry $payload "request")
    | merge {
      description: ((tool-input $payload) | get -o description | default null)
      background: $background
      programs: (stage-programs $command | uniq)
      decision: $verdict.decision
      rule: $verdict.rule
    }
  )

  # Stay silent on "defer" so Jev and the normal permission flow decide.
  if $verdict.decision == "deny" {
    decide "deny" $verdict.reason
  }
}

def main [
  --policy: path # bash-policy.nuon; defaults to the file beside this script's source
] {
  let input = $in
  let parsed = (try {
    let payload = (parse-payload $input)
    let policy = (open ($policy | default ($env.FILE_PWD | path join ".." "bash-policy.nuon")))
    { payload: $payload, policy: $policy }
  } catch { |err|
    { error: $err.msg }
  })

  if ($parsed.error? != null) {
    print --stderr $"prefer-nushell: ($parsed.error)"
    decide "ask" $"The prefer-nushell guard could not inspect this command: ($parsed.error). Confirm before running it."
    return
  }

  match ($parsed.payload.hook_event_name? | default "PreToolUse") {
    "PostToolUse" => { append-log (base-entry $parsed.payload "ran") }
    "PostToolUseFailure" => { append-log (base-entry $parsed.payload "failed") }
    _ => { pre-tool-use $parsed.payload $parsed.policy }
  }
}
