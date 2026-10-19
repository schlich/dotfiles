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
#   ▶ switch/build 60%: build 10/20: home-manager-path
#   ✓ preflight 40sec
#   ✗ closures 2min 3sec: Closure of homelab changed
#   ⏸ BLOCKED land: Waiting for approval
#   ✓ Landed the topic
#
# A phase starts with its first `working` report; later ones only update it,
# and show the report's progress when it gives one. A finished phase gives
# how long it took since it started, and its message only when that differs
# from the one it started with. A report without an id prints its message
# after the glyph. Once a job has
# reported, those lines tell its story. The log adds the facts a phase logs
# but does not report, the lines that match --detail, indented under it, and
# tallies the pre-commit hooks a preflight ran under the phase they ran in:
#
#   ▶ rebase: Rebasing onto trunk()
#     · Rebased 1 commits to destination.
#     · onto sorqnvok 4e1383cf main | Update the ci input to 2026.10.19.5
#   ✓ rebase 3sec
#   ✓ preflight 45sec
#     · hooks: 6 passed, failed: check whitespace
#
# It also adds the lines that match --alarm, as `⚠ ALARM: LINE`: trouble the
# job did not report, such as an evaluator that died. Lines that match
# --ignore never print; by default
# these include nix-eval-jobs replacing a worker that outgrew its memory
# budget, which it does routinely, and passing tests, whose names may
# describe the very trouble they check for (`ok killed checks read as
# failed`), even behind a Nix build's `NAME> ` prefix. A job that reports nothing, such as a bare
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

# The first `working` report of each phase still open, by id, after
# `reports`: a progress update keeps the phase's start, and a finished or
# failed phase closes, so a retry starts it again.
def phases [known: record, reports: list<record>]: nothing -> record {
  $reports
  | where id? != null
  | reduce --fold $known {|report, acc|
    if $report.state == working {
      if $report.id in $acc { $acc } else { $acc | insert $report.id $report }
    } else if $report.state in [done error failed] {
      $acc | reject --optional $report.id
    } else {
      $acc
    }
  }
}

# The last line in `lines` with any text, shortened for a notification.
def last-text [lines: list<string>]: nothing -> any {
  let texts = ($lines | ansi strip | where {|line| ($line | str trim) != '' })
  if ($texts | is-empty) { null } else { $texts | last | str trim | str substring 0..<200 }
}

# A log line a phase logged, as the indented line under it: whitespace
# collapsed, git's and jj's wording shortened, and the length capped.
def detail-line [line: string]: nothing -> string {
  let text = (
    $line | ansi strip | str trim | str replace --all --regex '\s{2,}' ' '
    | str replace --regex '^Parent commit \(@-\) ?: ' 'onto '
    | str replace --regex '^Changes to push to (\S+):$' 'pushing to $1'
    | str substring 0..<160
  )
  $"  · ($text)"
}

# A pre-commit hook's result line, `name.....Passed`, as its name and
# result, or null for any other line.
def hook-result [line: string]: nothing -> any {
  let found = ($line | ansi strip | parse --regex '^\s*(?<name>\S.*?)\.{3,}\s*(?<result>Passed|Failed|Skipped)\s*$')
  if ($found | is-empty) { null } else { $found | first }
}

# The hooks a phase ran as one indented line, naming each failure, or null
# when it ran none.
def hooks-line [hooks: list<record>]: nothing -> any {
  if ($hooks | is-empty) { return null }
  let passed = ($hooks | where result == Passed | length)
  let skipped = ($hooks | where result == Skipped | length)
  let failed = ($hooks | where result == Failed | get name)
  let parts = [
    (if $passed > 0 { $"($passed) passed" })
    (if $skipped > 0 { $"($skipped) skipped" })
    (if ($failed | is-not-empty) { $"failed: ($failed | str join ', ')" })
  ] | compact
  $"  · hooks: ($parts | str join ', ')"
}

# A duration as a notification reads it, `12min 5sec`; NUON would write
# nanoseconds.
def whole-seconds []: duration -> string { $in // 1sec * 1sec | into string }

# How long ago `time` was, or null when it is missing or unreadable.
def since [time: any]: nothing -> any {
  try { (date now) - ($time | into datetime) | whole-seconds } catch { null }
}

# A report as one line: its state's glyph, its phase, how long a finished
# phase took or how far a running one is, and its message unless it only
# repeats the one the phase started with.
def report-line [report: record, started: any]: nothing -> string {
  let took = if $started == null or $report.state == working { null } else {
    try { ($report.time | into datetime) - ($started.time | into datetime) | whole-seconds } catch { null }
  }
  let progress = if $report.state == working and $report.progress? != null { $"($report.progress)%" }
  let msg = if $report.state != working and $report.msg? == $started.msg? { null } else { $report.msg? }
  let head = match $report.state {
    working => '▶'
    done => '✓'
    error | failed => '✗'
    blocked => '⏸ BLOCKED'
    _ => $"• ($report.state)"
  }
  let phase = ([$head $report.id? $took $progress] | compact | str join ' ')
  if $msg == null { $phase } else if $report.id? == null and $took == null and $progress == null { $"($phase) ($msg)" } else { $"($phase): ($msg)" }
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
  --detail: string = '^Rebased \d+ commits|^Parent commit \(@-\)|^Changes to push to \S+:$|^Recovery point:|^Impact:|\b\d+/\d+ successful\b|^(PATHS|SIZE|DIFF):' # Log lines a reporting job's phases log but do not report, printed indented under them
  --ignore: string ='(?i)\bno conflicts?\b|^memory budget of \d+ MiB exceeded \(\d+ MiB in use\), killing worker \d+|^(\S+> )?ok\s|^(\S+> )?test .* \.\.\. ok$' # Matching log lines to drop anyway: nix-eval-jobs replacing a worker that outgrew its budget is routine, and a passing test's name may say "killed" or "error"
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
  # The hooks run since the last phase finished, tallied under the next one.
  mut hooks = []
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
      $hooks = ($hooks | append ($logged | each {|line| hook-result $line } | compact))
      mut events = []
      # Where the log's lines go among the reports: before the first phase
      # to finish, which logged them before it reported.
      mut at = -1
      if ($status | path exists) {
        let new = (read-lines $status $seen.status --final=$final)
        let reports = (status-reports $new.lines)
        for report in $reports {
          # The phase's start, read before a finished phase closes.
          let start = ($started | get --optional ($report.id? | default ''))
          if $at < 0 and $report.state in [done error failed] { $at = ($events | length) }
          $events = ($events | append (report-line $report $start))
          $started = (phases $started [$report])
          if $report.state in [done error failed] {
            $events = ($events | append (hooks-line $hooks))
            $hooks = []
          }
        }
        if ($reports | is-not-empty) { $latest = ($reports | last) }
        $seen.status = $new.offset
      }
      let shown = if $seen.status == 0 {
        $logged | where {|line| $line =~ $pattern and $line !~ $ignore }
      } else {
        $logged | where {|line| $line !~ $ignore } | each {|line|
          if $line =~ $alarm { $"⚠ ALARM: ($line)" } else if ($line | ansi strip | str trim) =~ $detail { detail-line $line }
        }
      }
      $events = if $at < 0 { $events | append $shown } else {
        $events | take $at | append $shown | append ($events | skip $at)
      }
      # A reporting job's last hooks go under its last phase.
      if $final and $seen.status > 0 {
        $events = ($events | append (hooks-line $hooks))
        $hooks = []
      }
      $events = ($events | compact)
      $last_line = (last-text $logged | default $last_line)
      if ($events | is-empty) and ((date now) - $last_event) >= $quiet_after and $outcome == null and $alive {
        # A running phase is timed from its start, not its latest update.
        let phase = if $latest == null { null } else { $started | get --optional ($latest.id? | default '') | default $latest }
        $events = [(heartbeat $phase ((date now) - $last_event) $last_line)]
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
