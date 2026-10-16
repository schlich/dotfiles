# Follow a background job for the Monitor tool, one stdout line per event.
# A job reports its progress as OSC 7501 program status, which osc7501.nu's
# `pst report` appends to `LOG.status.jsonl` (its PST_FILE) as JSON records;
# the watcher prints each one but `clear` as `STATUS: {...}` in NUON. Once a
# job has reported, those records tell its story, and the log adds only the
# lines that match --alarm, as `ALARM: LINE`: trouble the job did not report,
# such as an evaluator that died. Lines that match --ignore never print; by
# default these include nix-eval-jobs replacing a worker that outgrew its
# memory budget, which it does routinely. A job that reports nothing,
# such as a bare `nix build`, falls back to its log lines that match
# --pattern. After --quiet-after without an event, a `STILL: {...}` heartbeat
# names the job's latest phase, how long it has been in it, and its last log
# line, and repeats each --quiet-after, so a long build reads as alive and
# a stuck one shows where it stopped. Exit with a
# `DONE: {...}` line when the job finishes: a `job-log` job saves
# `LOG.done.nuon`, and a ci MCP job (LOG is its `log`) writes `exit` beside
# it. If the process that owns the job dies first, print `DONE: {state:
# lost}` rather than wait out the Monitor's timeout.
#
# Both kinds of job announce their start and end on cross.stream, under a
# topic of their own. The watcher follows that topic and reads the files on
# each of its frames and on the store's heartbeat every --interval, so the
# job's end wakes it at once. Without the store or a topic, it reads every
# --interval instead.
#
# The position is kept in `LOG.seen` as the byte offset of each file's last
# complete line, so a line caught mid-write is read once its newline lands,
# and a Monitor re-armed after its timeout resumes where the last one stopped
# instead of repeating earlier events.

# The job's owner, whose death without a result means the job was lost, and
# its cross.stream topic: what `job-log` recorded, or a ci MCP job's meta.
def job-record [log: path]: nothing -> record {
  let record = $"($log).job.nuon"
  let meta = ($log | path dirname | path join meta.json)
  if ($record | path exists) {
    open $record
  } else if ($log | path basename) == log and ($meta | path exists) {
    let meta = (open $meta)
    { pid: $meta.pid, topic: $meta.topic? }
  } else {
    { pid: null, topic: null }
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

# The status reports among `lines`. A `clear` only tells a terminal to drop
# its records, so a watcher skips it, along with any line that is not a
# report.
def status-reports [lines: list<string>]: nothing -> list<record> {
  $lines
  | each {|line| try { $line | from json } catch { null } }
  | where {|report| ($report | describe) starts-with record and $report.state? not-in [null clear] }
}

# The job's latest status report, the phase a heartbeat names.
def latest-report [file: path]: nothing -> any {
  if not ($file | path exists) { return null }
  let reports = (status-reports (open --raw $file | lines))
  if ($reports | is-empty) { null } else { $reports | last }
}

# The last line in `lines` with any text, shortened for a notification.
def last-text [lines: list<string>]: nothing -> any {
  let texts = ($lines | ansi strip | where {|line| ($line | str trim) != '' })
  if ($texts | is-empty) { null } else { $texts | last | str trim | str substring 0..<200 }
}

# A duration as a notification reads it, `12min 5sec`; NUON would write
# nanoseconds.
def whole-seconds []: duration -> string { $in // 1sec * 1sec | into string }

# A quiet job's heartbeat: its latest phase and how long it has been in it,
# how long nothing has been printed, and its last log line.
def heartbeat [status: path, quiet: duration, last_line: any]: nothing -> record {
  let report = (latest-report $status)
  let since = (try { $report.time | into datetime } catch { null })
  {
    quiet: ($quiet | whole-seconds)
    phase: $report.msg?
    phase_for: (if $since == null { null } else { (date now) - $since | whole-seconds })
    last_line: $last_line
  }
}

# What wakes the watcher: each frame on the job's topic and the store's
# heartbeat, or without a store or topic, a timer. Either wakes it at once,
# so the files are read even when a follow fails as it starts.
def wakeups [interval: duration, topic: any] {
  let store = ($env.XS_ADDR? | default ($env.HOME | path join .local/share/cross.stream/store))
  let up = $topic != null and (try { (^xs version $store | complete).exit_code == 0 } catch { false })
  if $up {
    do -i { ^xs cat $store --follow --pulse ($interval / 1ms | into int) --topic $"($topic).*" } | lines | prepend start
  } else {
    generate {|first| if not $first { sleep $interval }; { out: tick, next: false } } true
  }
}

def main [
  log: path # Log the job writes both streams to
  --pattern: string = '(?i)^===|landed|releas|tagg|mirror|error|fail|refus|conflict|status=|oom|passed|waiting' # Log lines worth a notification, for a job that writes no status reports
  --alarm: string = '(?i)\bkill(ed|ing)\b|exceeded|out of memory|\boom\b|panicked|segmentation fault|^error[:\s]|\berror:' # Log lines worth an alarm even from a job that reports its status
  --ignore: string = '(?i)\bno conflicts?\b|^memory budget of \d+ MiB exceeded \(\d+ MiB in use\), killing worker \d+' # Matching log lines to drop anyway: nix-eval-jobs replacing a worker that outgrew its budget is routine
  --interval: duration = 2sec # How often to read the files between job events
  --quiet-after: duration = 5min # How long without an event before each heartbeat
  --replay # Start from the beginning instead of the saved position
] {
  let log = ($log | path expand)
  let cursor = $"($log).seen"
  let status = $"($log).status.jsonl"
  let job = (job-record $log)
  mut seen = if $replay or not ($cursor | path exists) { { log: 0, status: 0 } } else { open $cursor | from nuon }
  mut last_event = (date now)
  mut last_line = if ($log | path exists) { last-text (open --raw $log | lines) } else { null }
  loop {
    for _ in (wakeups $interval $job.topic) {
      # Check the owner before the result, so a job that finishes in between
      # reads as finished rather than lost.
      let alive = $job.pid == null or ($"/proc/($job.pid)" | path exists)
      let outcome = (result $log)
      # A job that is over writes nothing more, so its last line counts even
      # without a newline.
      let final = $outcome != null or not $alive
      # Read the log before the reports: a job that reported before it
      # logged a line is then always seen to have reported.
      mut logged = []
      if ($log | path exists) {
        let new = (read-lines $log $seen.log --final=$final)
        $logged = $new.lines
        $seen.log = $new.offset
      }
      mut events = []
      if ($status | path exists) {
        let new = (read-lines $status $seen.status --final=$final)
        # The Monitor's own clock already gives each report's time.
        $events = (status-reports $new.lines | reject --optional time | each {|report| $"STATUS: ($report | to nuon)" })
        $seen.status = $new.offset
      }
      let wanted = if $seen.status == 0 { $pattern } else { $alarm }
      let prefix = if $seen.status == 0 { '' } else { 'ALARM: ' }
      $events = ($events | append ($logged | where {|line| $line =~ $wanted and $line !~ $ignore } | each {|line| $"($prefix)($line)" }))
      $last_line = (last-text $logged | default $last_line)
      if ($events | is-empty) and ((date now) - $last_event) >= $quiet_after and $outcome == null and $alive {
        $events = [$"STILL: (heartbeat $status ((date now) - $last_event) $last_line | to nuon)"]
      }
      $events | each { print $in } | ignore
      if ($events | is-not-empty) { $last_event = (date now) }
      $seen | to nuon | save --force $cursor
      if $outcome != null {
        print $"DONE: ($outcome | to nuon)"
        return
      }
      if not $alive {
        print $"DONE: {state: lost, owner: ($job.pid)}"
        return
      }
    }
    # The follow ended before the job did, as when the store restarts.
    sleep $interval
  }
}
