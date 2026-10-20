# Claude Code hook for Luvus: report the session id when a session starts, so
# Luvus resumes the exact conversation, and forward permission prompts, turn
# ends, and prompt submissions so its AGENTS sidebar shows precise state. It
# replaces the bash and python3 script `luvus integration install claude`
# writes into ~/.claude/settings.json, and reports what that script reports.
# Outside a Luvus pane, or with no luvus to call, it does nothing. It never
# prints, since SessionStart output would reach the agent's context, and never
# fails a session.

const events = [Notification Stop SubagentStop UserPromptSubmit]

# The luvus a pane's server injects, else the one this hook was built with.
def luvus-bin [fallback: string] {
  let injected = ($env.LUVUS_BIN_PATH? | default "")
  if $injected != "" and ($injected | path exists) { $injected } else { $fallback }
}

def main [--luvus: string] {
  let input = $in
  if ($env.LUVUS_ENV? | default "") == "" or ($env.LUVUS_SOCKET_PATH? | default "") == "" { return }
  # Devin runs Claude-format hooks too; its sessions are not Claude's.
  if ($env.DEVIN_PROJECT_DIR? | default "") != "" { return }
  try {
    let bin = (luvus-bin ($luvus | default ""))
    if $bin == "" { return }
    let payload = ($input | into string | from json)
    let event = ($payload.hook_event_name? | default ($payload.event? | default ""))
    if $event in $events {
      let message = ($payload.message? | default "" | into string | str substring 0..199)
      let kind = ($payload.notification_type? | default "")
      ^$bin pane report-event --agent claude --kind $event --message $message --notification-type $kind | complete | ignore
    } else {
      let session = ([$payload.session_id? $payload.sessionId? $payload.id?] | compact | where {|s| $s != "" } | get 0? | default "")
      if $session != "" {
        ^$bin pane report --agent claude --session $session | complete | ignore
      }
    }
  }
}
