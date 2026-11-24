# job-stream: show a job-log run in a terminal as it happens: what it runs,
# its log as the job writes it, and how it ended. t3code-jobs types this into
# the terminal it opens for each job in the job's T3 Code thread; it works in
# any terminal too. It prints the log's bytes unchanged, colour included, and
# returns once the job's LOG.done.nuon appears and the log is drained.

def done-line [log: string, meta: record]: nothing -> string {
  let outcome = (try { open $"($log).done.nuon" } catch { {} })
  let ended = (try { ls $"($log).done.nuon" | get 0.modified } catch { date now })
  # Whole seconds, as Nushell writes a duration: `2min 5sec`, `1hr 3min 9sec`.
  let took = (try { ($ended - ($meta.started | into datetime)) // 1sec * 1sec | into string } catch { '?' })
  let code = ($outcome.exit_code? | default '?')
  let head = if $code == 0 { $"(ansi green)✓ DONE(ansi reset)" } else { $"(ansi red)✗ DONE(ansi reset)" }
  let line = $"($head) exit ($code) after ($took)"
  if $outcome.error? == null { $line } else { $"($line): ($outcome.error)" }
}

def main [
  log: path                        # the job's log, as job-log was given it
  --interval: duration = 500ms     # how often to look for new output
] {
  let log = ($log | path expand)
  let meta = (try { open $"($log).job.nuon" } catch { {} })
  let since = (try { $meta.started | into datetime | format date '%H:%M' } catch { '?' })
  print $"(ansi cyan_bold)JOB(ansi reset) ($meta.task? | default ($log | path basename))"
  print $"(ansi dark_gray)($meta.cwd? | default '') · since ($since) · ($log)(ansi reset)"
  mut offset = 0
  loop {
    # Look for the outcome before reading, so the bytes written before it
    # are printed in this round.
    let finished = ($"($log).done.nuon" | path exists)
    let size = (try { ls $log | get 0.size | into int } catch { 0 })
    # A rerun into the same log starts it over.
    if $size < $offset { $offset = 0 }
    if $size > $offset {
      ^tail --bytes $"+($offset + 1)" $log | ^head --bytes ($size - $offset)
      $offset = $size
    }
    if $finished { break }
    sleep $interval
  }
  print ''
  print (done-line $log $meta)
}
