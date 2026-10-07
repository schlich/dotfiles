# Session config for the Nushell MCP server.

# Past the ~10kb default, a result is replaced by a bare "output truncated"
# note. The limit must be a filesize on the session stack; nu --mcp ignores it
# as a process environment string.
$env.NU_MCP_OUTPUT_LIMIT = 50kb

# Run a closure as a background job the harness can follow: both output
# streams of its external commands go to LOG, the outcome to `LOG.done.nuon`,
# its OSC 7501 reports (osc7501.nu's PST_FILE) to `LOG.status.jsonl`, and
# this Nushell's pid and the job's cross.stream topic to `LOG.job.nuon`, so a
# watcher can tell a lost job from a slow one and wake the moment it ends.
# Follow it with a Monitor running `watch-job LOG`.
#
# The log takes only text, written as the commands produce it, so the closure
# must end in an external command or text: a record, a list, or null cannot
# be written there, and the job fails after its work is done. Report anything
# typed with `pst report` instead, which reaches the watcher as a record.
# Capturing the closure's value would cost the streaming log and the exit
# code of its last external command.
def job-log [
  log: path # Log file, usually in the session scratchpad
  task: closure # Work to run, ending in an external command or text; redirect nothing inside it
  --cwd: path # Directory to run in (default: the current one)
]: nothing -> record {
  let log = ($log | path expand)
  let cwd = ($cwd | default $env.PWD | path expand)
  mkdir ($log | path dirname)
  # A reused log path must not hand a watcher the previous run's state.
  for suffix in [done.nuon status.jsonl seen] { rm --force $"($log).($suffix)" }
  "" | save --force $log
  let topic = $"job.(random uuid)"
  { pid: $nu.pid, topic: $topic } | save --force $"($log).job.nuon"
  job-event $"($topic).start" { log: $log, cwd: $cwd, pid: $nu.pid }
  let id = (job spawn --description ($log | path basename) {
    let outcome = try {
      cd $cwd
      with-env { PST_FILE: $"($log).status.jsonl" } { do $task o+e>> $log }
      { exit_code: 0 }
    } catch {|err|
      { exit_code: ($env.LAST_EXIT_CODE? | default 1), error: $err.msg }
    }
    $outcome | save --force $"($log).done.nuon"
    job-event $"($topic).done" { outcome: $outcome }
  })
  { job: $id, log: $log }
}

# Announce a job event on the local cross.stream store, where `watch-job` and
# other readers follow it. The files stay the record, so a store that is down
# costs a watcher only its prompt wake-up.
def job-event [topic: string, meta: record] {
  let store = ($env.XS_ADDR? | default ($env.HOME | path join .local/share/cross.stream/store))
  try { ^xs append $store $topic --meta ($meta | to json --raw) | complete | ignore }
}
