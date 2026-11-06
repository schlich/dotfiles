#!/usr/bin/env -S nu --stdin

# Deny Claude Code Bash calls that belong in the Nushell MCP tool, ask Jev
# about the calls the policy leaves open, and log every Bash request and
# outcome so denials can be reviewed with `claude-bash-audit report` and
# turned into instruction or policy changes. A Monitor command runs through
# Bash too, so it is judged as a foreground Bash call, except that the
# policy's `monitor_allow` commands, such as `watch-job LOG`, are allowed.

# Mirrors jev's credential filter: such command lines are not logged verbatim.
const credential_pattern = '(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*='

const nushell_hint = "Run it in the Nushell MCP tool (mcp__plugin_hm_nushell__evaluate) instead, wrapping external programs in `| complete`. Without that tool, as in some subagents, page through files and saved tool results with the Read tool's offset and limit; never route around this guard through `nu -c`, `python3`, or another interpreter in Bash."

const text_hint = "Rewrite the text tools as structured Nushell (open, ls, glob, lines, where, parse, from json; slice $history afterwards instead of capping output). For large files, logs, or command output, keep the data in a Nushell variable and follow the rlm skill (rlm load, rlm find, rlm peek, rlm map) rather than printing it."

const default_hint = "Foreground Bash is disabled. Long commands whose progress matters may use Bash with run_in_background, logging to the scratchpad. If this command truly needs Bash (a TTY, or a harness feature the evaluate tool lacks), stop and tell the user why; every Bash request is logged for review."

const job_hint = "Run it as a Nushell job from the evaluate tool instead: `job-log $log --cwd $workspace { ci land }`, with the log in the scratchpad, then follow it with a Monitor running `watch-job $log`, as the Shell conventions describe."

const monitor_hint = "This guard judges Monitor commands as foreground Bash and allows only `watch-job LOG`, optionally after one `# title` line: run the work as a `job-log` job from the evaluate tool and follow it with that Monitor."

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

# Claude Code names the tool on every call; without a name, it is Bash.
def tool-name [payload: record] {
  let tool = ($payload | get -o tool_name | default null)
  if ($tool | describe) == "string" { $tool } else { "Bash" }
}

# A Monitor call that starts no shell command, such as a WebSocket watch.
# Claude Code never sends one to a plain Bash matcher, so it is left alone.
def shell-less-monitor [payload: record] {
  (tool-name $payload) == "Monitor" and (((tool-input $payload) | get -o command | describe) != "string")
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
    tool_name: (tool-name $payload)
    agent_type: ($payload.agent_type? | default null)
    cwd: ($payload.cwd? | default null)
    command: (if $command =~ $credential_pattern { "[redacted: credential assignment]" } else { $command })
  }
}

# Classify a Bash request against the policy. `decision` is "deny", "allow"
# for a Monitor command the policy allows outright, or "defer" to leave it to
# Jev and the normal permission flow.
def classify [command: string, background: bool, policy: record, tool: string] {
  if $tool == "Monitor" {
    let watcher = ($policy.monitor_allow? | default [] | where {|rule| $command =~ $rule.pattern } | get -o 0)
    if $watcher != null {
      return { decision: "allow", rule: $"monitor: ($watcher.why)", reason: $watcher.why }
    }
  }

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
  let jobs = ($programs | where {|program| $program in ($policy.long_jobs? | default []) } | uniq)
  if ($jobs | is-not-empty) {
    return {
      decision: "deny"
      rule: "long_jobs"
      matched: $jobs
      reason: $"Bash call runs ($jobs | str join ', '). ($job_hint)"
    }
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

# Pass a call the policy deferred to `jev bash-guard` and print its decision.
# Running Jev only here, not as a hook of its own, keeps a model call off the
# calls the policy denies and keeps Jev's reason from replacing the policy's:
# Claude Code shows the agent one reason when two hooks deny.
def ask-jev [payload: record, jev: string] {
  let result = (try {
    $payload | to json --raw | run-external $jev "bash-guard" | complete
  } catch {|err|
    { exit_code: null, stdout: "", stderr: $err.msg }
  })
  let output = (try { $result.stdout | from json } catch { null })
  if $result.exit_code != 0 or not ($output | describe | str starts-with "record") {
    let detail = ($result.stderr | lines | where {|line| $line | str trim | is-not-empty } | get -o 0 | default "no decision on stdout")
    decide "ask" $"Jev could not judge this Bash call: ($detail). Confirm before running it."
    return
  }
  if ($output | is-not-empty) {
    print ($output | to json --raw)
  }
}

def pre-tool-use [payload: record, policy: record, jev: string] {
  let tool = (tool-name $payload)
  let command = (extract-command $payload)
  let background = ((tool-input $payload) | get -o run_in_background | default false) == true
  let verdict = (classify $command $background $policy $tool)

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

  # On "defer", Jev decides, or without Jev the normal permission flow.
  if $verdict.decision == "deny" {
    decide "deny" (if $tool == "Monitor" { $"($monitor_hint) ($verdict.reason)" } else { $verdict.reason })
  } else if $verdict.decision == "allow" {
    decide "allow" $verdict.reason
  } else if ($jev | is-not-empty) {
    # Jev judges only Bash calls, so a Monitor command, which the policy
    # judges as one, goes to Jev as a Bash call.
    ask-jev (if $tool == "Monitor" { $payload | update tool_name "Bash" } else { $payload }) $jev
  }
}

def main [
  --policy: path # bash-policy.nuon; defaults to the file beside this script's source
  --jev: string # Jev executable that judges deferred calls; CLAUDE_BASH_JEV overrides it, and empty skips Jev
] {
  let input = $in
  let jev_command = ($env.CLAUDE_BASH_JEV? | default ($jev | default ""))
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

  if (shell-less-monitor $parsed.payload) {
    return
  }

  match ($parsed.payload.hook_event_name? | default "PreToolUse") {
    "PostToolUse" => { append-log (base-entry $parsed.payload "ran") }
    "PostToolUseFailure" => { append-log (base-entry $parsed.payload "failed") }
    _ => { pre-tool-use $parsed.payload $parsed.policy $jev_command }
  }
}
