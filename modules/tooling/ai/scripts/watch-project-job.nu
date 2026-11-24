# Follow the latest job-log run registered for this workspace.
def main [] {
  let workspace = ($env.PWD | path expand)
  let store = ($env.XS_ADDR? | default ($env.HOME | path join .local/share/cross.stream/store))
  let events = (xs cat --topic 'job.*' $store | complete)
  if $events.exit_code != 0 {
    error make {msg: $"Could not read job events: ($events.stderr | str trim)"}
  }

  let job = (
    $events.stdout | lines | each {|line| $line | from json }
    | where {|event| ($event.topic | str ends-with '.start') and $event.meta.cwd? == $workspace }
    | where {|event|
      let log = $event.meta.log?
      let topic = try { open --raw $"($log).job.nuon" | from nuon | get topic }
      $log != null and ($log | path exists) and $"($topic).start" == $event.topic
    }
    | last 1
    | get 0?
  )
  if $job == null {
    print $"No job-log runs found for ($workspace)."
    return
  }

  watch-job $job.meta.log --no-cursor
}
