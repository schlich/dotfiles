# Session config for the Nushell MCP server.

# Past the ~10kb default, a result is replaced by a bare "output truncated"
# note. The limit must be a filesize on the session stack; nu --mcp ignores it
# as a process environment string.
$env.NU_MCP_OUTPUT_LIMIT = 50kb

# Agents that T3 Code starts (modules/tooling/ai/t3code-server.nix sets
# T3_FLEET_DIRENV) inherit no shell's direnv hook, so load the environment of
# the directory this server starts in, the agent's project, as the hook
# would. direnv's allow list still decides, and a dev shell that takes longer
# than 20s to build loads nothing rather than stall the server's start.
# T3CODE_DIRENV_HOOK keeps the unit's bash hook out of direnv's own shells.
if ($env.T3_FLEET_DIRENV? == "1") {
  let loaded = (try { with-env { T3CODE_DIRENV_HOOK: "1" } { ^timeout 20 direnv export json | complete } } catch { null })
  if $loaded != null and $loaded.exit_code == 0 and ($loaded.stdout | str trim | is-not-empty) {
    let exports = ($loaded.stdout | from json)
    let unset = ($exports | transpose name value | where value == null | get name)
    let set = ($exports | reject ...$unset)
    load-env (if 'PATH' in $set { $set | update PATH { split row (char esep) } } else { $set })
    if ($unset | is-not-empty) { hide-env --ignore-errors ...$unset }
  }
}

# Run a closure as a background job the harness can follow: both output
# streams of its external commands go to LOG, the outcome to `LOG.done.nuon`,
# its OSC 7501 reports (osc7501.nu's PST_FILE) to `LOG.status.jsonl`, and
# this Nushell's pid, the job's cross.stream topic, and what it runs where
# since when to `LOG.job.nuon`, so a watcher can name the job, tell a lost
# job from a slow one, and wake the moment it ends.
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
  # The closure's source, on one line, is what the watcher's JOB line runs.
  let label = (view source $task | str trim --char '{' | str trim --char '}' | str replace --all --regex '\s+' ' ' | str trim | str substring 0..<120)
  { pid: $nu.pid, topic: $topic, task: $label, cwd: $cwd, started: (date now) } | save --force $"($log).job.nuon"
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
