# Run the Luvus hook against sample payloads with a stub luvus that records
# its arguments, inside and outside a Luvus pane.
# Usage: nu luvus-hook.nu <hook script>
def main [script: string] {
  # Run from a Luvus pane, the hook would otherwise report to the live server.
  hide-env --ignore-errors LUVUS_ENV LUVUS_SOCKET_PATH LUVUS_BIN_PATH LUVUS_PANE_ID LUVUS_API_ADDRESS DEVIN_PROJECT_DIR
  let dir = (mktemp --directory)
  let calls = ($dir | path join calls)
  let stub = ($dir | path join luvus)
  $"#!/bin/sh\nprintf '%s\\n' \"$*\" >> ($calls)\necho reported\n" | save $stub
  chmod +x $stub
  let pane = { LUVUS_ENV: "1", LUVUS_SOCKET_PATH: ($dir | path join luvus.sock) }
  let long = ("x" | fill --width 300 --character "x")
  let cases = [
    [name env payload expect];
    ["reports the session at start" $pane { hook_event_name: SessionStart, session_id: abc, source: startup } "pane report --agent claude --session abc"]
    ["forwards a permission prompt" $pane { hook_event_name: Notification, session_id: abc, message: "Claude needs your permission", notification_type: permission_prompt } "pane report-event --agent claude --kind Notification --message Claude needs your permission --notification-type permission_prompt"]
    ["forwards a turn end" $pane { hook_event_name: Stop, session_id: abc } "pane report-event --agent claude --kind Stop --message  --notification-type "]
    ["forwards a prompt" $pane { hook_event_name: UserPromptSubmit, session_id: abc, prompt: hi } "pane report-event --agent claude --kind UserPromptSubmit --message  --notification-type "]
    ["cuts a long message to 200 characters" $pane { hook_event_name: Notification, message: $long } $"pane report-event --agent claude --kind Notification --message ($long | str substring 0..199) --notification-type "]
    ["prefers the pane's luvus" ($pane | insert LUVUS_BIN_PATH $stub) { hook_event_name: SessionStart, session_id: def } "pane report --agent claude --session def"]
    ["ignores a session outside Luvus" {} { hook_event_name: SessionStart, session_id: abc } null]
    ["ignores a pane without a socket" { LUVUS_ENV: "1" } { hook_event_name: Stop } null]
    ["ignores Devin's hooks" ($pane | insert DEVIN_PROJECT_DIR /tmp) { hook_event_name: SessionStart, session_id: abc } null]
    ["ignores a start with no session" $pane { hook_event_name: SessionStart } null]
  ]
  let failures = ($cases | each {|c|
    rm --force $calls
    # The pane's luvus case passes a missing fallback, so only the injected one can answer.
    let fallback = if ($c.env.LUVUS_BIN_PATH? | default "") != "" { $dir | path join missing } else { $stub }
    let r = (with-env $c.env { $c.payload | to json | ^nu --stdin $script --luvus $fallback | complete })
    let got = if ($calls | path exists) { open --raw $calls | str trim --right --char "\n" } else { null }
    let ok = $r.exit_code == 0 and $r.stdout == "" and $r.stderr == "" and $got == $c.expect
    print $"(if $ok { 'ok  ' } else { 'FAIL' }) luvus-hook: ($c.name)"
    if not $ok { print $"     got: ($got | to json) stdout: ($r.stdout | to json) stderr: ($r.stderr | to json)" }
    $ok
  } | where {|ok| not $ok } | length)
  # Malformed input must not fail the session.
  let bad = (with-env $pane { "not json" | ^nu --stdin $script --luvus $stub | complete })
  let bad_ok = $bad.exit_code == 0 and $bad.stdout == ""
  print $"(if $bad_ok { 'ok  ' } else { 'FAIL' }) luvus-hook: survives malformed input"
  if $failures > 0 or not $bad_ok { exit 1 }
}
