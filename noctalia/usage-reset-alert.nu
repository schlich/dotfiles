# Send one desktop notification per Claude or Codex usage window that is about
# to reset. Noctalia is the notification server, so alerts appear in its
# notification popup and history.
def main [
  --lead: duration = 30min # How long before a reset to notify.
] {
  let state_dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join .local state)) | path join usage-reset-alert
  let state_file = $state_dir | path join notified.nuon
  let now = date now
  let notified = if ($state_file | path exists) { open $state_file } else { [] }

  let due = ai-usagebar usage --json
    | from json
    | get entries
    | where id in [anthropic openai] and status == ready
    | each {|entry| $entry.metrics | insert vendor $entry.display_name }
    | flatten
    | where reset_at? != null and percent > 0
    | update reset_at { into datetime }
    | where {|m| $m.reset_at > $now and ($m.reset_at - $now) <= $lead }
    # Reset timestamps can carry sub-second jitter between fetches.
    | insert key {|m| $"($m.vendor)|($m.label)|($m.reset_at | format date '%Y-%m-%dT%H:%M')" }
    | where key not-in ($notified | get -o key | default [])

  let sent = $due | each {|m|
    let minutes = ($m.reset_at - $now) / 1min | math round
    let at = $m.reset_at | date to-timezone local | format date '%H:%M'
    let result = notify-send --app-name "AI usage" --icon appointment-soon $"($m.vendor) ($m.label) resets in ($minutes) min" $"($m.value) used; the window resets at ($at)." | complete
    if $result.exit_code == 0 { {key: $m.key, reset_at: $m.reset_at} }
  }

  if ($sent | is-not-empty) or ($state_file | path exists) {
    mkdir $state_dir
    $notified
    | where {|n| ($n.reset_at | into datetime) > ($now - 1day) }
    | append $sent
    | save --force $state_file
  }
}
