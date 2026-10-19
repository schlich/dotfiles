# Follow jobs with watch-job the way a Monitor does, with and without
# cross.stream. Run it under the Nushell MCP config, which defines `job-log`:
#   nu --config nu-mcp-config.nu watch-job.nu WATCH_JOB_SCRIPT

# One watcher run's problems: its exit, each printed line against its
# pattern, and its duration against the limit.
def check [
  name: string
  run: record
  expected: list<string>
  took: duration
  limit: duration
]: nothing -> list<string> {
  let lines = ($run.stdout | lines)
  let mismatched = (
    ($lines | length) != ($expected | length)
    or ($lines | zip $expected | any {|pair| $pair.0 !~ $pair.1 })
  )
  let problems = [
    (if $run.exit_code != 0 { $"exited ($run.exit_code): ($run.stderr | str trim)" })
    (if $mismatched { $"printed ($lines | to nuon), expected ($expected | to nuon)" })
    (if $took > $limit { $"took ($took), limit ($limit)" })
  ] | compact
  print $"(if ($problems | is-empty) { 'ok  ' } else { 'FAIL' }) ($name)"
  $problems | each {|problem| print $"     ($problem)" } | ignore
  $problems | each {|problem| $"($name): ($problem)" }
}

def main [watch_job: path] {
  let tmp = (mktemp --directory)
  let store = ($tmp | path join store)
  $env.XS_ADDR = $store
  let server = (job spawn --description xs-serve { ^xs serve $store o+e> ($tmp | path join serve.log) })
  mut ready = false
  for _ in 1..100 {
    if (^xs version $store | complete).exit_code == 0 {
      $ready = true
      break
    }
    sleep 100ms
  }
  if not $ready { error make { msg: "xs serve did not start" } }
  # A watcher that never ends fails its check instead of hanging the build.
  let watch = {|log, interval|
    let started = (date now)
    let run = (^timeout 30 nu --no-config-file $watch_job $log --interval ($interval | into string) | complete)
    { run: $run, took: ((date now) - $started) }
  }
  mut failures = []

  # The job's done event wakes the watcher long before the next heartbeat.
  # The JOB line names what a job-log job runs, where, and since when.
  let log = ($tmp | path join job.log)
  job-log $log { ^sh -c 'echo "=== build"; sleep 1; echo "error: boom"; exit 3' } | ignore
  let result = (do $watch $log 10sec)
  $failures = ($failures | append (check "job-log job ends at its done event" $result.run [r#'^JOB: \^sh -c 'echo "=== build"; .*' · .+ · since \d\d:\d\d$'# '^=== build$' '^error: boom$' '^✗ DONE exit 3 after \dsec: '] $result.took 5sec))

  # A job that reports its status is followed by its reports, one line each:
  # its log lines, even ones the pattern matches, and its clear report print
  # nothing. A progress update shows its percentage and keeps the phase's
  # start, so a finished phase says how long it took since it first
  # reported, and its message only when that is new. A report without an id
  # prints its message after the glyph.
  let log = ($tmp | path join reported.log)
  job-log $log { ^sh -c r#'
    report() { printf '%s\n' "$1" >> "$PST_FILE"; }
    report '{"time":"2026-10-07T08:00:00-05:00","state":"working","id":"rebase","app":"ci","msg":"Rebasing"}'
    echo "=== a line the pattern matches"
    sleep 1
    report '{"time":"2026-10-07T08:00:30-05:00","state":"working","id":"rebase","app":"ci","msg":"Rebasing 3/4","progress":75}'
    report '{"time":"2026-10-07T08:00:40-05:00","state":"done","id":"rebase","app":"ci","msg":"Rebasing"}'
    report '{"time":"2026-10-07T08:00:41-05:00","state":"blocked","id":"land","app":"ci","msg":"Waiting for approval"}'
    report '{"time":"2026-10-07T08:00:42-05:00","state":"done","id":"land","app":"ci","msg":"Landed jj-x on main"}'
    report '{"time":"2026-10-07T08:00:42-05:00","state":"done","app":"ci","msg":"Landed the topic"}'
    report '{"time":"2026-10-07T08:00:42-05:00","state":"clear","app":"ci"}'
    echo "Landed jj-x on main."
  '# } | ignore
  let result = (do $watch $log 10sec)
  $failures = ($failures | append (check "reported job prints its reports alone" $result.run ['^JOB: ' '^▶ rebase: Rebasing$' '^▶ rebase 75%: Rebasing 3/4$' '^✓ rebase 40sec$' '^⏸ BLOCKED land: Waiting for approval$' '^✓ land: Landed jj-x on main$' '^✓ Landed the topic$' '^✓ DONE exit 0 after \dsec$'] $result.took 5sec))

  # Trouble a reporting job logs but does not report still reaches the
  # Monitor, as an alarm after the report it follows. An evaluator replacing
  # a worker that outgrew its memory budget is routine and prints nothing,
  # and so does a passing test whose name mentions what it checks for.
  let log = ($tmp | path join alarm.log)
  job-log $log { ^sh -c r#'
    report() { printf '%s\n' "$1" >> "$PST_FILE"; }
    report '{"time":"2026-10-07T08:00:00-05:00","state":"working","id":"clearance","app":"ci","msg":"Waiting for local flake checks"}'
    echo "=== a line only the pattern matches"
    echo "memory budget of 6144 MiB exceeded (6156 MiB in use), killing worker 411986 ('den-host-evaluation', 6118 MiB)"
    echo "ci-properties> ok local checks read as killed exactly when no check failed by itself (100 cases)"
    echo "test spec::error_when_killed ... ok"
    echo "error: evaluation worker 411987 was killed by signal 9"
  '# } | ignore
  let result = (do $watch $log 10sec)
  $failures = ($failures | append (check "reported job raises alarms" $result.run ['^JOB: ' '^▶ clearance: Waiting for local flake checks$' '^⚠ ALARM: error: evaluation worker 411987 was killed by signal 9$' '^✓ DONE exit 0 after \dsec$'] $result.took 5sec))

  # What a reporting job's phases log but do not report prints indented under
  # them: the facts that match --detail, shortened, and the hooks a preflight
  # ran as one tally that names each failure.
  let log = ($tmp | path join detail.log)
  job-log $log { ^sh -c r#'
    report() { printf '%s\n' "$1" >> "$PST_FILE"; }
    report '{"time":"2026-10-07T08:00:00-05:00","state":"working","id":"rebase","app":"ci","msg":"Rebasing onto trunk()"}'
    echo "Rebased 1 commits to destination."
    echo "Parent commit (@-)      : sorqnvok 4e1383cf main | Update the ci input"
    echo "Added 0 files, modified 1 files, removed 0 files"
    report '{"time":"2026-10-07T08:00:03-05:00","state":"done","id":"rebase","app":"ci","msg":"Rebasing onto trunk()"}'
    report '{"time":"2026-10-07T08:00:03-05:00","state":"working","id":"preflight","app":"ci","msg":"Running preflight"}'
    sleep 1
    echo "  nix fmt................................................................Passed"
    echo "  check whitespace.......................................................Failed"
    echo "  evaluate Home Manager..................................................Passed"
    sleep 1
    report '{"time":"2026-10-07T08:00:45-05:00","state":"failed","id":"preflight","app":"ci","msg":"Preflight failed"}'
  '# } | ignore
  let result = (do $watch $log 10sec)
  $failures = ($failures | append (check "reported job shows its phases' details" $result.run ['^JOB: ' '^▶ rebase: Rebasing onto trunk\(\)$' '^  · Rebased 1 commits to destination\.$' '^  · onto sorqnvok 4e1383cf main \| Update the ci input$' '^✓ rebase 3sec$' '^▶ preflight: Running preflight$' '^✗ preflight 42sec: Preflight failed$' '^  · hooks: 2 passed, failed: check whitespace$' '^✓ DONE exit 0 after \dsec$'] $result.took 5sec))

  # A job quiet for longer than --quiet-after gets a heartbeat naming its
  # phase and last log line, once per quiet period.
  let log = ($tmp | path join quiet.log)
  job-log $log { ^sh -c r#'
    printf '%s\n' "{\"time\":\"$(date -Iseconds)\",\"state\":\"working\",\"id\":\"build\",\"app\":\"ci\",\"msg\":\"Building\"}" >> "$PST_FILE"
    echo "building desktop-primary"
    sleep 1.6
  '# } | ignore
  let result = (do {
    let started = (date now)
    let run = (^timeout 30 nu --no-config-file $watch_job $log --interval 200ms --quiet-after 1sec | complete)
    { run: $run, took: ((date now) - $started) }
  })
  $failures = ($failures | append (check "quiet job gets a heartbeat" $result.run ['^JOB: ' '^▶ build: Building$' '^⋯ STILL build [12]sec, quiet 1sec: building desktop-primary$' '^✓ DONE exit 0 after \dsec$'] $result.took 5sec))

  # Without a store the watcher reads on a timer, and a line written in two
  # parts is read once it is whole.
  let log = ($tmp | path join offline.log)
  let result = (with-env { XS_ADDR: ($tmp | path join nowhere) } {
    job-log $log { ^sh -c 'printf "=== offline\nbuil"; sleep 1; printf "ding failed\n"' } | ignore
    do $watch $log 300ms
  })
  $failures = ($failures | append (check "job without a store polls" $result.run ['^JOB: ' '^=== offline$' '^building failed$' '^✓ DONE exit 0 after \dsec$'] $result.took 5sec))

  # A ci MCP job names its command, workspace, start, and topic in
  # meta.json and records its exit code.
  let dir = ($tmp | path join jobs 20261007T000000-land-0a1b2c)
  mkdir $dir
  { args: [land --clearance local], workspace: /home/u/dotfiles, pid: $nu.pid, started: (date now | format date '%Y-%m-%dT%H:%M:%S%z'), topic: job.ci-test } | to json | save ($dir | path join meta.json)
  "" | save ($dir | path join log)
  job spawn {
    sleep 500ms
    "=== ci land\n" | save --append ($dir | path join log)
    sleep 500ms
    "0\n" | save ($dir | path join exit)
    ^xs append $store job.ci-test.done --meta '{"outcome": {"exit_code": 0}}' | complete | ignore
  } | ignore
  let result = (do $watch ($dir | path join log) 10sec)
  $failures = ($failures | append (check "ci MCP job ends at its done event" $result.run ['^JOB: ci land --clearance local · dotfiles · since \d\d:\d\d$' '^=== ci land$' '^✓ DONE exit 0 after \dsec$'] $result.took 5sec))

  # A follow that fails as it starts still leaves the files read every
  # interval: this xs answers `version` and refuses everything else.
  let bin = ($tmp | path join bin)
  mkdir $bin
  "#!/bin/sh\n[ \"$1\" = version ]\n" | save ($bin | path join xs)
  ^chmod +x ($bin | path join xs)
  let log = ($tmp | path join refused.log)
  "=== refused follow\n" | save $log
  { pid: $nu.pid, topic: job.refused-test } | save $"($log).job.nuon"
  job spawn { sleep 1sec; { exit_code: 0 } | save $"($log).done.nuon" } | ignore
  let result = (with-env { PATH: ($env.PATH | prepend $bin) } { do $watch $log 300ms })
  $failures = ($failures | append (check "follow refused as it starts" $result.run ['^JOB: refused.log$' '^=== refused follow$' '^✓ DONE exit 0$'] $result.took 5sec))

  # An owner that is gone without a result means the job was lost.
  let log = ($tmp | path join lost.log)
  "" | save $log
  { pid: 4194305, topic: job.lost-test } | save $"($log).job.nuon"
  let result = (do $watch $log 300ms)
  $failures = ($failures | append (check "lost owner" $result.run ['^JOB: lost.log$' '^✗ DONE lost: owner 4194305 exited without a result$'] $result.took 5sec))

  job kill $server
  rm --recursive --force $tmp
  if ($failures | is-not-empty) {
    error make { msg: $"($failures | length) watch-job checks failed" }
  }
}
