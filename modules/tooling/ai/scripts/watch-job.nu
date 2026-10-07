# Follow a background job for the Monitor tool, one stdout line per event:
# each new log line that matches --pattern, and each OSC 7501 status report
# the job appends to `LOG.status.jsonl` (osc7501.nu's PST_FILE), printed as
# `STATUS state [id]: msg`. Exit with a DONE line when the job finishes: a
# `job-log` job saves `LOG.done.nuon`, and a ci MCP job (LOG is its `log`)
# writes `exit` beside it. If the process that owns the job dies first, print
# `DONE: {state: lost}` rather than wait out the Monitor's timeout.
#
# The position is kept in `LOG.seen` as the byte offset of each file's last
# complete line, so a line caught mid-write is read once its newline lands,
# and a Monitor re-armed after its timeout resumes where the last one stopped
# instead of repeating earlier events.

# The process whose death without a result means the job was lost: the
# Nushell that `job-log` recorded, or a ci MCP job's runner.
def owner-pid [log: path] {
  let pid_file = $"($log).pid"
  let meta = ($log | path dirname | path join meta.json)
  if ($pid_file | path exists) {
    open --raw $pid_file | str trim | into int
  } else if ($log | path basename) == log and ($meta | path exists) {
    open $meta | get pid
  } else {
    null
  }
}

def result [log: path] {
  let done = $"($log).done.nuon"
  let exit = ($log | path dirname | path join exit)
  if ($done | path exists) {
    open $done
  } else if ($log | path basename) == log and ($exit | path exists) {
    { exit_code: (open --raw $exit | str trim | into int) }
  } else {
    null
  }
}

# The complete lines `file` gained past byte `offset`, and the offset after
# them. A line still being written waits for its newline, unless `--final`
# says the job is over and nothing more will be written.
def read-lines [file: path, offset: int, --final]: nothing -> record {
  let chunk = (open --raw $file | bytes at $offset.. | into binary)
  let end = if $final { $chunk | bytes length } else { ($chunk | bytes index-of --end 0x[0a]) + 1 }
  { lines: ($chunk | bytes at ..<$end | decode utf-8 | lines), offset: ($offset + $end) }
}

def status-line [report: record] {
  let id = if $report.id? != null { $" ($report.id)" } else { "" }
  let progress = if $report.progress? != null { $" ($report.progress)%" } else { "" }
  let text = ([$report.title? $report.msg? $report.kind?] | compact | str join " · ")
  let tail = if $text != "" { $": ($text)" } else { "" }
  $"STATUS ($report.state)($id)($progress)($tail)"
}

def main [
  log: path # Log the job writes both streams to
  --pattern: string = '(?i)^===|landed|releas|tagg|mirror|error|fail|refus|conflict|status=|oom|passed|waiting' # Lines worth a notification
  --ignore: string = '(?i)\bno conflicts?\b' # Matching lines to drop anyway
  --interval: duration = 2sec # How often to read the log
  --replay # Start from the beginning instead of the saved position
] {
  let log = ($log | path expand)
  let cursor = $"($log).seen"
  let status = $"($log).status.jsonl"
  let owner = (owner-pid $log)
  mut seen = if $replay or not ($cursor | path exists) { { log: 0, status: 0 } } else { open $cursor | from nuon }
  loop {
    # Check the owner before the result, so a job that finishes in between
    # reads as finished rather than lost.
    let alive = $owner == null or ($"/proc/($owner)" | path exists)
    let outcome = (result $log)
    # A job that is over writes nothing more, so its last line counts even
    # without a newline.
    let final = $outcome != null or not $alive
    if ($log | path exists) {
      let new = (read-lines $log $seen.log --final=$final)
      $new.lines | where {|line| $line =~ $pattern and $line !~ $ignore } | each { print $in } | ignore
      $seen.log = $new.offset
    }
    if ($status | path exists) {
      let new = (read-lines $status $seen.status --final=$final)
      $new.lines | each {|line| try { print (status-line ($line | from json)) } } | ignore
      $seen.status = $new.offset
    }
    $seen | to nuon | save --force $cursor
    if $outcome != null {
      print $"DONE: ($outcome | to nuon)"
      break
    }
    if not $alive {
      print $"DONE: {state: lost, owner: ($owner)}"
      break
    }
    sleep $interval
  }
}
