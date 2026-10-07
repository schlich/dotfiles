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
  let log = ($tmp | path join job.log)
  job-log $log { ^sh -c 'echo "=== build"; sleep 1; echo "error: boom"; exit 3' } | ignore
  let result = (do $watch $log 10sec)
  $failures = ($failures | append (check "job-log job ends at its done event" $result.run ['^=== build$' '^error: boom$' '^DONE: \{exit_code: 3, error: '] $result.took 5sec))

  # Without a store the watcher reads on a timer, and a line written in two
  # parts is read once it is whole.
  let log = ($tmp | path join offline.log)
  let result = (with-env { XS_ADDR: ($tmp | path join nowhere) } {
    job-log $log { ^sh -c 'printf "=== offline\nbuil"; sleep 1; printf "ding failed\n"' } | ignore
    do $watch $log 300ms
  })
  $failures = ($failures | append (check "job without a store polls" $result.run ['^=== offline$' '^building failed$' '^DONE: \{exit_code: 0\}$'] $result.took 5sec))

  # A ci MCP job names its topic in meta.json and records its exit code.
  let dir = ($tmp | path join jobs 20261007T000000-land-0a1b2c)
  mkdir $dir
  { pid: $nu.pid, topic: job.ci-test } | to json | save ($dir | path join meta.json)
  "" | save ($dir | path join log)
  job spawn {
    sleep 500ms
    "=== ci land\n" | save --append ($dir | path join log)
    sleep 500ms
    "0\n" | save ($dir | path join exit)
    ^xs append $store job.ci-test.done --meta '{"outcome": {"exit_code": 0}}' | complete | ignore
  } | ignore
  let result = (do $watch ($dir | path join log) 10sec)
  $failures = ($failures | append (check "ci MCP job ends at its done event" $result.run ['^=== ci land$' '^DONE: \{exit_code: 0\}$'] $result.took 5sec))

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
  $failures = ($failures | append (check "follow refused as it starts" $result.run ['^=== refused follow$' '^DONE: \{exit_code: 0\}$'] $result.took 5sec))

  # An owner that is gone without a result means the job was lost.
  let log = ($tmp | path join lost.log)
  "" | save $log
  { pid: 4194305, topic: job.lost-test } | save $"($log).job.nuon"
  let result = (do $watch $log 300ms)
  $failures = ($failures | append (check "lost owner" $result.run ['^DONE: \{state: lost, owner: 4194305\}$'] $result.took 5sec))

  job kill $server
  rm --recursive --force $tmp
  if ($failures | is-not-empty) {
    error make { msg: $"($failures | length) watch-job checks failed" }
  }
}
