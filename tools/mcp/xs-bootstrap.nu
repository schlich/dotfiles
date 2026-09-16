#!/usr/bin/env nu

def main [store: path] {
    let actor = r###'
{
  run: {|frame, state|
    if $frame.topic != "terminal.command.failed" {
      {next: $state}
    } else if (which ai-run | is-empty) {
      {
        out: {
          topic: "terminal.agent.unconfigured"
          command_id: $frame.id
          warning: "No ai-run command is configured; terminal failure was recorded but not triaged."
        }
        next: $state
      }
    } else {
      let event = ($frame.meta | default {})
      let prompt = $"
You are performing read-only terminal-error triage.
Do not edit files, execute corrective commands, publish changes, or ask another agent to mutate state.
Analyze this failed interactive Nushell command and return a concise diagnosis and one recommended next step.
If an Atuin history ID is available, use the Atuin MCP tools to inspect the command and retrieve its captured output before diagnosing it.

Command: ($event.command? | default "unknown")
Working directory: ($event.cwd? | default "unknown")
Exit code: ($event.exit_code? | default "unknown")
Atuin history ID: ($event.atuin_history_id? | default "unknown")
"
      let result = (do -i { ^ai-run $prompt --agent trunk-triage } | complete)
      if $result.exit_code == 0 {
        {
          out: {
            topic: "terminal.triage.completed"
            command_id: $frame.id
            atuin_history_id: ($event.atuin_history_id? | default null)
            response: ($result.stdout | str trim)
          }
          next: $state
        }
      } else {
        {
          out: {
            topic: "terminal.triage.failed"
            command_id: $frame.id
            error: ($result.stderr | str trim)
          }
          next: $state
        }
      }
    }
  }
  start: "new"
  topics: ["terminal.command.failed"]
  return_options: {
    suffix: ".result"
    ttl: "last:100"
  }
}
'###

    let script = $"
let actor = r###'($actor)'###
($actor) | .append xs.actor.terminal-triage.create
"
    let result = (do -i { ^xs eval $store -c $script } | complete)
    if $result.exit_code != 0 {
        print --stderr ($result.stderr | str trim)
        exit $result.exit_code
    }
}
