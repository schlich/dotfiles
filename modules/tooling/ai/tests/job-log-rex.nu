# Run `job-log --rex` against a Rex server of its own, the way an agent
# does, and check what a passing and a failing job leave behind: the log
# watch-job reads, the status records, the outcome, and the kept terminal.
#
#   nu --config nu-mcp-config.nu job-log-rex.nu
use std/assert

def wait-done [log: path] {
  for _ in 1..120 {
    if ($"($log).done.nuon" | path exists) { return (open $"($log).done.nuon") }
    sleep 250ms
  }
  error make { msg: $"no outcome for ($log)" }
}

def main [] {
  let root = (mktemp --directory --tmpdir job-log-rex.XXXXXX)
  # A private server: its socket, state, and config live under root, and it
  # stops when the test does.
  $env.REX_RUNTIME_DIR = ($root | path join run)
  $env.XDG_STATE_HOME = ($root | path join state)
  $env.XDG_CONFIG_HOME = ($root | path join config)
  $env.XS_ADDR = ($root | path join no-store)
  mkdir $env.REX_RUNTIME_DIR

  try {
    let pass = ($root | path join pass.log)
    let fail = ($root | path join fail.log)

    job-log $pass --rex { ^sh -c 'echo one; echo two' } | ignore
    let outcome = (wait-done $pass)
    assert equal $outcome.exit_code 0
    assert ('error' not-in $outcome)
    assert equal (open --raw $pass | lines) [one two]

    # pst reports on the terminal reach LOG.status.jsonl too.
    job-log $fail --rex { ^sh -c 'printf "\033]7501;state=error:id=build\033\\"; echo "error: missing symbol foo"; exit 3' } | ignore
    let outcome = (wait-done $fail)
    assert equal $outcome.exit_code 3
    assert str contains $outcome.error 'rex capture -s jobs -b job:fail.log'
    assert equal (open --raw $fail | lines) ['error: missing symbol foo']

    # The failed terminal stays, with its screen and Rex's own record.
    let screen = (^rex capture -s jobs -b job:fail.log --trim | lines)
    assert equal $screen ['error: missing symbol foo']
    let records = (^rex block call -s jobs -b job:fail.log program_status | from json | get records)
    assert equal ($records | get state) [error]

    # A rerun of the same log replaces its terminal rather than adding one.
    job-log $fail --rex { ^sh -c 'exit 0' } | ignore
    assert equal (wait-done $fail).exit_code 0
    let labels = (^rex block ls -s jobs --json | from json | get blocks | get label)
    assert equal ($labels | where $it == job:fail.log | length) 1
  } catch {|err|
    ^rex server stop | complete | ignore
    rm --recursive --force $root
    error make { msg: $err.msg }
  }
  ^rex server stop | complete | ignore
  rm --recursive --force $root
  print 'job-log --rex: ok'
}
