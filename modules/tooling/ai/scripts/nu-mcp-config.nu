# Session config for the Nushell MCP server.

# Past the ~10kb default, a result is replaced by a bare "output truncated"
# note. The limit must be a filesize on the session stack; nu --mcp ignores it
# as a process environment string.
$env.NU_MCP_OUTPUT_LIMIT = 50kb

# Run a closure as a background job the harness can follow: both output
# streams of its external commands go to LOG, the outcome to `LOG.done.nuon`,
# its OSC 7501 reports (osc7501.nu's PST_FILE) to `LOG.status.jsonl`, and
# this Nushell's pid to `LOG.pid` so a watcher can tell a lost job from a slow
# one. Follow it with a Monitor running `watch-job LOG`.
def job-log [
  log: path # Log file, usually in the session scratchpad
  task: closure # Work to run; redirect nothing inside it
  --cwd: path # Directory to run in (default: the current one)
]: nothing -> record {
  let log = ($log | path expand)
  let cwd = ($cwd | default $env.PWD | path expand)
  mkdir ($log | path dirname)
  # A reused log path must not hand a watcher the previous run's state.
  for suffix in [done.nuon status.jsonl seen] { rm --force $"($log).($suffix)" }
  "" | save --force $log
  $nu.pid | save --force $"($log).pid"
  let id = (job spawn --description ($log | path basename) {
    let outcome = try {
      cd $cwd
      with-env { PST_FILE: $"($log).status.jsonl" } { do $task o+e>> $log }
      { exit_code: 0 }
    } catch {|err|
      { exit_code: ($env.LAST_EXIT_CODE? | default 1), error: $err.msg }
    }
    $outcome | save --force $"($log).done.nuon"
  })
  { job: $id, log: $log }
}
