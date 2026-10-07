# Follow a background job's log for the Monitor tool: print each new line
# that matches --pattern, and when the job saves `LOG.done.nuon`, print the
# remaining matches and a DONE line with its result, then exit.
def main [
  log: path # Log the job writes both streams to
  --pattern: string = '(?i)^===|landed|releas|tagg|mirror|error|fail|refus|conflict|status=|oom|passed|waiting' # Lines worth a notification
  --interval: duration = 2sec # How often to read the log
] {
  let done = $"($log).done.nuon"
  mut seen = 0
  loop {
    let finished = $done | path exists
    if ($log | path exists) {
      let lines = open --raw $log | lines
      $lines | skip $seen | where $it =~ $pattern | each { print $in } | ignore
      $seen = $lines | length
    }
    if $finished {
      print $"DONE: (open $done | to nuon)"
      break
    }
    sleep $interval
  }
}
