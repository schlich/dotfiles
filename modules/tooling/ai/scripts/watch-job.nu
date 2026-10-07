# Follow a background job for the Monitor tool, one stdout line per event.
# A job reports its progress as OSC 7501 program status, which osc7501.nu's
# `pst report` appends to `LOG.status.jsonl` (its PST_FILE) as JSON records;
# the watcher prints each one but `clear` as `STATUS: {...}` in NUON. Once a
# job has reported, those records are its whole story and the log goes
# unsearched. Only a job that reports nothing, such as a bare `nix build`,
# falls back to its log lines that match --pattern. Exit with a
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

# The status reports among `lines`, less their timestamps, which the
# Monitor's own clock already gives. A `clear` only tells a terminal to drop
# its records, so a watcher skips it, along with any line that is not a
# report.
def status-reports [lines: list<string>]: nothing -> list<record> {
  $lines
  | each {|line| try { $line | from json } catch { null } }
  | where {|report| ($report | describe) starts-with record and $report.state? not-in [null clear] }
  | reject --optional time
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
  --ignore: string = '(?i)\bno conflicts?\b' # Matching log lines to drop anyway
  --interval: duration = 2sec # How often to read the files between job events
  --replay # Start from the beginning instead of the saved position
] {
  let log = ($log | path expand)
  let cursor = $"($log).seen"
  let status = $"($log).status.jsonl"
  let job = (job-record $log)
  mut seen = if $replay or not ($cursor | path exists) { { log: 0, status: 0 } } else { open $cursor | from nuon }
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
      if ($status | path exists) {
        let new = (read-lines $status $seen.status --final=$final)
        status-reports $new.lines | each {|report| print $"STATUS: ($report | to nuon)" } | ignore
        $seen.status = $new.offset
      }
      if $seen.status == 0 {
        $logged | where {|line| $line =~ $pattern and $line !~ $ignore } | each { print $in } | ignore
      }
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
