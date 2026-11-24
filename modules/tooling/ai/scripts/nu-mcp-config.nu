# Session config for the Nushell MCP server.

# Past the ~10kb default, a result is replaced by a bare "output truncated"
# note. The limit must be a filesize on the session stack; nu --mcp ignores it
# as a process environment string.
$env.NU_MCP_OUTPUT_LIMIT = 50kb

# Agents that T3 Code starts (modules/tooling/ai/clients/t3code/t3code-server.nix sets
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
# Follow it with a Monitor running `watch-job LOG`. A job an agent in T3 Code
# starts also names its thread (T3CODE_THREAD_ID), so t3code-jobs opens a
# terminal in that thread's drawer that streams the log.
#
# The log takes only text, written as the commands produce it, so the closure
# must end in an external command or text: a record, a list, or null cannot
# be written there, and the job fails after its work is done. Report anything
# typed with `pst report` instead, which reaches the watcher as a record.
# Capturing the closure's value would cost the streaming log and the exit
# code of its last external command.
#
# With --rex, the closure runs in a Rex terminal instead, labelled
# `job:LOG-NAME` in the Rex session `jobs`, which stays open after it exits:
# its screen, exit code, and OSC 7501 records stay readable with
# `rex capture -b job:LOG-NAME`, `rex wait`, and `nurx status` once the job
# is over. Only the closure's source travels, to a fresh `nu -n`: it sees no
# captured variables and none of this session's commands, so it suits
# external programs such as `ci land` or `nix build`. The terminal's screen is
# copied into LOG as it changes, and its reports still reach
# `LOG.status.jsonl`, so `watch-job` follows it the same way.
def job-log [
  log: path # Log file, usually in the session scratchpad
  task: closure # Work to run, ending in an external command or text; redirect nothing inside it
  --cwd: path # Directory to run in (default: the current one)
  --rex # Run in a kept-open Rex terminal, job:LOG-NAME, so a failure can be read later
]: nothing -> record {
  if $rex {
    return (job-log-rex $log $task ($cwd | default $env.PWD))
  }
  let log = ($log | path expand)
  let cwd = ($cwd | default $env.PWD | path expand)
  mkdir ($log | path dirname)
  # A reused log path must not hand a watcher the previous run's state.
  for suffix in [done.nuon status.jsonl seen] { rm --force $"($log).($suffix)" }
  "" | save --force $log
  let topic = $"job.(random uuid)"
  # The closure's source, on one line, is what the watcher's JOB line runs.
  let label = (view source $task | str trim --char '{' | str trim --char '}' | str replace --all --regex '\s+' ' ' | str trim | str substring 0..<120)
  { pid: $nu.pid, topic: $topic, task: $label, cwd: $cwd, started: (date now), thread: $env.T3CODE_THREAD_ID? } | save --force $"($log).job.nuon"
  job-event $"($topic).start" ({ log: $log, cwd: $cwd, pid: $nu.pid } | merge (job-thread))
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

# job-log --rex: the same files as job-log, from a job that runs in a Rex
# terminal. A Nushell job here creates the terminal, copies its screen into
# LOG every --interval until it exits, and writes the outcome from Rex's exit
# status. Lines go to LOG once the next line starts, so a progress line that
# keeps rewriting itself is copied in its final form.
def job-log-rex [log: path, task: closure, cwd: path, --interval: duration = 2sec]: nothing -> record {
  let log = ($log | path expand)
  let cwd = ($cwd | path expand)
  mkdir ($log | path dirname)
  for suffix in [done.nuon status.jsonl seen] { rm --force $"($log).($suffix)" }
  "" | save --force $log
  let topic = $"job.(random uuid)"
  # The closure's body: its source without the braces and an empty `||`.
  let source = (view source $task | str trim | str replace --regex '^\{\s*(\|\s*\|)?' '' | str replace --regex '\}$' '' | str trim)
  let name = $"job:($log | path basename)"
  let label = ($source | str replace --all --regex '\s+' ' ' | str substring 0..<120)
  { pid: $nu.pid, topic: $topic, task: $"rex ($name): ($label)", cwd: $cwd, started: (date now), thread: $env.T3CODE_THREAD_ID? } | save --force $"($log).job.nuon"

  # One Rex session holds every job's terminal; create it, empty, if needed.
  let sessions = (^rex ls --json | from json | get sessions)
  if ($sessions | where label == jobs | is-empty) {
    { label: jobs } | to json --raw | ^rex api call session.create - | ignore
  }
  # A rerun of the same log replaces its old terminal rather than leaving two
  # with one label.
  ^rex block ls -s jobs --json | from json | get blocks | where label? == $name | each {|b| ^rex block close -s jobs $b.block_id | complete } | ignore
  let created = (^rex run -s jobs --label $name --keep-open --focus=false --cwd $cwd --json -- env $"PST_FILE=($log).status.jsonl" $nu.current-exe -n -c $source | from json)
  let block = ($created.block_ids | first)

  job-event $"($topic).start" ({ log: $log, cwd: $cwd, pid: $nu.pid, rex_block: $block } | merge (job-thread))
  let id = (job spawn --description ($log | path basename) {
    let outcome = try {
      follow-rex-block $log $block $name $interval
    } catch {|err|
      { exit_code: 1, rex_block: $block, error: $"job-log --rex: ($err.msg)" }
    }
    $outcome | save --force $"($log).done.nuon"
    job-event $"($topic).done" { outcome: $outcome }
  })
  { job: $id, log: $log, rex: { session: jobs, block: $block, label: $name } }
}

# Copy a Rex job terminal's screen into LOG until its program exits, and
# return the outcome for `LOG.done.nuon`.
def follow-rex-block [log: path, block: string, name: string, interval: duration]: nothing -> record {
    mut copied = 0
    mut outcome: any = null
    while $outcome == null {
      # rex takes Go durations, such as 2000ms.
      let waited = (^rex wait -s jobs --for $"($interval // 1ms)ms" --json $block | complete)
      let ended = ($waited.stdout | str trim | is-not-empty)
      let screen = (^rex capture -s jobs -b $block --trim --unwrap | complete | get stdout | lines)
      # The last line may still change, until the terminal's program exits.
      let ready = (if $ended { $screen | length } else { [(($screen | length) - 1) 0] | math max })
      if $ready > $copied {
        $screen | slice $copied..<$ready | each {|l| $"($l)\n" } | str join | save --append $log
        $copied = $ready
      }
      if $ended {
        let payload = ($waited.stdout | from json)
        let code = ($payload.exit_code? | default $waited.exit_code)
        $outcome = (if $code == 0 {
          { exit_code: 0, rex_block: $block }
        } else {
          { exit_code: $code, rex_block: $block, error: $"kept in Rex: rex capture -s jobs -b ($name)" }
        })
      }
    }
    $outcome
}

# The T3 Code thread whose agent runs this session, for a job's start event.
def job-thread []: nothing -> record {
  let thread = ($env.T3CODE_THREAD_ID? | default '')
  if $thread == '' { {} } else { { thread: $thread } }
}

# Announce a job event on the local cross.stream store, where `watch-job` and
# other readers follow it. The files stay the record, so a store that is down
# costs a watcher only its prompt wake-up.
def job-event [topic: string, meta: record] {
  let store = ($env.XS_ADDR? | default ($env.HOME | path join .local/share/cross.stream/store))
  try { ^xs append $store $topic --meta ($meta | to json --raw) | complete | ignore }
}
