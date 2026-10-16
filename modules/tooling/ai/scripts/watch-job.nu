# Follow a background job for the Monitor tool, one stdout line per event,
# written to be read at a glance in a narrow task panel and by the agent
# that started the job. The first line names the job:
#
#   JOB: ci land --clearance local · bash-feedback · since 17:10
#
# A job reports its progress as OSC 7501 program status, which osc7501.nu's
# `pst report` appends to `LOG.status.jsonl` (its PST_FILE) as JSON records.
# The watcher prints each one but `clear` as a line led by its state's glyph:
#
#   ▶ closures: Proving every NixOS closure unchanged
#   ✓ preflight 40sec
#   ✗ closures 2min 3sec: Closure of homelab changed
#   ⏸ BLOCKED land: Waiting for approval
#
# A finished phase gives how long it took since its `working` report, and its
# message only when that differs from the one it started with. Once a job has
# reported, those lines tell its story, and the log adds only the lines that
# match --alarm, as `⚠ ALARM: LINE`: trouble the job did not report, such as
# an evaluator that died. Lines that match --ignore never print; by default
# these include nix-eval-jobs replacing a worker that outgrew its memory
# budget, which it does routinely. A job that reports nothing, such as a bare
# `nix build`, falls back to its log lines that match --pattern, as they are.
# After --quiet-after without an event, a heartbeat names the job's latest
# phase, how long it has been in it, and its last log line, and repeats each
# --quiet-after, so a long build reads as alive and a stuck one shows where
# it stopped:
#
#   ⋯ STILL closures 12min 5sec, quiet 5min: building desktop-primary
#
# Exit with a DONE line when the job finishes, giving its exit code and how
# long it ran: a `job-log` job saves `LOG.done.nuon`, and a ci MCP job (LOG is
# its `log`) writes `exit` beside it. If the process that owns the job dies
# first, print a `lost` DONE rather than wait out the Monitor's timeout:
#
#   ✓ DONE exit 0 after 14min 32sec
#   ✗ DONE exit 3 after 1sec: error message
#   ✗ DONE lost: owner 4194305 exited without a result
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

# The job's owner, whose death without a result means the job was lost, its
# cross.stream topic, and what the JOB line says about it: what `job-log`
# recorded, or a ci MCP job's meta.
def job-record [log: path]: nothing -> record {
  let record = $"($log).job.nuon"
  let meta = ($log | path dirname | path join meta.json)
  let job = if ($record | path exists) {
    open $record
  } else if ($log | path basename) == log and ($meta | path exists) {
    let meta = (open $meta)
    {
      pid: $meta.pid
      topic: $meta.topic?
      task: ($meta.args? | default [] | prepend ci | str join ' ')
      cwd: $meta.workspace?
      started: $meta.started?
    }
  } else {
    {}
  }
  {
    pid: $job.pid?
    topic: $job.topic?
    task: ($job.task? | default ($log | path basename))
    cwd: $job.cwd?
    started: (try { $job.started | into datetime } catch { null })
  }
}

# The line that names the job: what it runs, where, and since when.
def job-line [job: record]: nothing -> string {
  [
    $job.task
    (if $job.cwd != null { $job.cwd | path basename })
    (if $job.started != null { $"since ($job.started | format date '%H:%M')" })
  ] | compact | str join ' · ' | $"JOB: ($in)"
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

# The `working` report each phase started with, by id, among `reports`,
# added to those already known.
def phases [known: record, reports: list<record>]: nothing -> record {
  $reports
  | where state == working and id? != null
  | reduce --fold $known {|report, acc| $acc | upsert $report.id $report }
}

# The last line in `lines` with any text, shortened for a notification.
def last-text [lines: list<string>]: nothing -> any {
  let texts = ($lines | ansi strip | where {|line| ($line | str trim) != '' })
  if ($texts | is-empty) { null } else { $texts | last | str trim | str substring 0..<200 }
}

# A duration as a notification reads it, `12min 5sec`; NUON would write
# nanoseconds.
def whole-seconds []: duration -> string { $in // 1sec * 1sec | into string }

# How long ago `time` was, or null when it is missing or unreadable.
def since [time: any]: nothing -> any {
  try { (date now) - ($time | into datetime) | whole-seconds } catch { null }
}

# A report as one line: its state's glyph, its phase, how long a finished
# phase took, and its message unless it only repeats the one it started with.
def report-line [report: record, started: any]: nothing -> string {
  let took = if $started == null or $report.state == working { null } else {
    try { ($report.time | into datetime) - ($started.time | into datetime) | whole-seconds } catch { null }
  }
  let msg = if $report.state != working and $report.msg? == $started.msg? { null } else { $report.msg? }
  let head = match $report.state {
    working => '▶'
    done => '✓'
    error | failed => '✗'
    blocked => '⏸ BLOCKED'
    _ => $"• ($report.state)"
  }
  let phase = ([$head $report.id? $took] | compact | str join ' ')
  if $msg == null { $phase } else { $"($phase): ($msg)" }
}

# A quiet job's heartbeat: its latest phase and how long it has been in it,
# how long nothing has been printed, and its last log line.
def heartbeat [phase: any, quiet: duration, last_line: any]: nothing -> string {
  # Between phases, the last one has finished, so it says what came after.
  let where = if $phase == null { null } else {
    let name = ($phase.id? | default $phase.msg?)
    let name = if $phase.state? == working { $name } else { $"after ($name)" }
    [$name (since $phase.time?)] | compact | str join ' '
  }
  let head = ([$where $"quiet ($quiet | whole-seconds)"] | compact | str join ', ')
  if $last_line == null { $"⋯ STILL ($head)" } else { $"⋯ STILL ($head): ($last_line)" }
}

# The job's outcome as its last line.
def done-line [outcome: record, started: any]: nothing -> string {
  let after = (since $started)
  let line = ([
    (if $outcome.exit_code? == 0 { '✓ DONE' } else { '✗ DONE' })
    $"exit ($outcome.exit_code? | default '?')"
    (if $after != null { $"after ($after)" })
  ] | compact | str join ' ')
  if $outcome.error? == null { $line } else { $"($line): ($outcome.error)" }
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
  # A re-armed Monitor still times the phases it saw start, and names the
  # latest one in its heartbeat.
  let earlier = if ($status | path exists) and $seen.status > 0 {
    status-reports (open --raw $status | bytes at ..<$seen.status | decode utf-8 | lines)
  } else { [] }
  mut started = (phases {} $earlier)
  mut latest = if ($earlier | is-empty) { null } else { $earlier | last }
  print (job-line $job)
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
        let reports = (status-reports $new.lines)
        for report in $reports {
          $started = (phases $started [$report])
          $events = ($events | append (report-line $report ($started | get --optional ($report.id? | default ''))))
        }
        if ($reports | is-not-empty) { $latest = ($reports | last) }
        $seen.status = $new.offset
      }
      let wanted = if $seen.status == 0 { $pattern } else { $alarm }
      let prefix = if $seen.status == 0 { '' } else { '⚠ ALARM: ' }
      $events = ($events | append ($logged | where {|line| $line =~ $wanted and $line !~ $ignore } | each {|line| $"($prefix)($line)" }))
      $last_line = (last-text $logged | default $last_line)
      if ($events | is-empty) and ((date now) - $last_event) >= $quiet_after and $outcome == null and $alive {
        $events = [(heartbeat $latest ((date now) - $last_event) $last_line)]
      }
      $events | each { print $in } | ignore
      if ($events | is-not-empty) { $last_event = (date now) }
      $seen | to nuon | save --force $cursor
      if $outcome != null {
        print (done-line $outcome $job.started)
        return
      }
      if not $alive {
        print $"✗ DONE lost: owner ($job.pid) exited without a result"
        return
      }
    }
    # The follow ended before the job did, as when the store restarts.
    sleep $interval
  }
}
