# luvus-task-start: start a luvus task worker from Nushell panes.
#
# luvus types each task worker's launch line in POSIX syntax on Unix, which a
# Nushell pane rejects, so `luvus task start` leaves a task marked running with
# no worker. The rejected line leaves the worker's briefing staged, so this
# command sends the same launch in Nushell syntax to finish it. It sends that
# only when the pane shows Nushell's parse error, so it does nothing once luvus
# launches workers in Nushell syntax itself.
#
# luvus also bases a task's worktree on this checkout's own `main`, which can
# lag `origin/main`; when it finishes the launch, this first moves a still
# empty worktree to `origin/main`.

const NU_LAUNCH = 'run-external $env.LUVUS_BIN_PATH __task-worker'
# The packaged luvus, substituted at build time.
const LUVUS = '@luvus@'

def --wrapped luvus-json [...args: string] {
  let r = (^$LUVUS ...$args | complete)
  let reply = (try { $r.stdout | from json } catch { null })
  if $reply == null {
    error make { msg: $"luvus ($args | str join ' ') failed: ($r.stderr | str trim)" }
  }
  if ($reply.error? != null) {
    error make { msg: $"luvus ($args | str join ' '): ($reply.error.code): ($reply.error.message)" }
  }
  $reply.result
}

# The luvus workspace whose directory is this repository's main checkout.
def workspace-for-repo [] {
  let common = (^git rev-parse --path-format=absolute --git-common-dir | str trim)
  let root = ($common | path dirname)
  let matches = (luvus-json workspace list | get workspaces | where cwd == $root)
  if ($matches | is-empty) {
    error make { msg: $"no luvus workspace is open at ($root); pass --workspace-id" }
  }
  $matches | first | get workspace_id
}

# Point an empty task worktree at origin/main.
def rebase-empty-worktree [worktree: string] {
  if not ($worktree | path exists) { return "no worktree" }
  ^git -C $worktree fetch -q origin main
  let dirty = (^git -C $worktree status --porcelain | lines | length)
  let own = (^git -C $worktree rev-list --count origin/main..HEAD | str trim | into int)
  let behind = (^git -C $worktree rev-list --count HEAD..origin/main | str trim | into int)
  if $dirty > 0 or $own > 0 { return "kept: the worktree already has work" }
  if $behind == 0 { return "already on origin/main" }
  ^git -C $worktree reset -q --hard origin/main
  $"moved to origin/main, ($behind) commits ahead of its base"
}

def pane-text [pane: string] {
  luvus-json pane read $pane | get text
}

# luvus stages a manual worker's briefing here and the worker deletes it when
# it starts (src/orch/worker.rs), for the default session.
def staged-launch [pane: string] {
  $"($env.HOME)/.luvus/task-launch-($pane).json"
}

# Panes already open in a directory: luvus reuses such a pane for the task.
def panes-in [dir: string] {
  if ($dir | is-empty) { return [] }
  luvus-json pane list | get panes | where cwd == $dir | get pane
}

# Start task ID with an agent, finishing the launch in Nushell panes.
def main [
  id: string                 # task to start, such as t68
  --agent: string = "claude" # agent command for the worker
  --workspace-id: string     # luvus workspace; defaults to this repository's
  --wait: duration = 10sec   # how long to wait for the pane's first launch
] {
  let workspace = ($workspace_id | default (workspace-for-repo))
  # A reused pane's shell may be in a state that ignores typed input, and its
  # scrollback may hold an earlier launch's error, so start only in a new pane.
  let existing = (panes-in (luvus-json task get $id | get task.worktree? | default ""))
  if not ($existing | is-empty) {
    error make { msg: $"($id)'s worktree is already open in pane ($existing | str join ', '); close it first: luvus pane close <id>" }
  }
  luvus-json task start $id --agent $agent --no-focus --workspace-id $workspace | ignore
  let task = (luvus-json task get $id | get task)
  let pane = ($task.assignee | into string)

  # Wait for the pane's shell to answer luvus's own launch line.
  let deadline = ((date now) + $wait)
  mut text = (pane-text $pane)
  while (not ($text =~ 'parse_mismatch|__task-worker')) and ((date now) < $deadline) {
    sleep 250ms
    $text = (pane-text $pane)
  }
  # Only a rejected launch leaves the worker unstarted, so only then is it
  # safe to move the worktree and send the Nushell launch.
  let rejected = ($text =~ 'nu::parser::parse_mismatch')
  let base = if $rejected {
    let moved = (rebase-empty-worktree ($task.worktree | default ""))
    luvus-json pane run $pane $NU_LAUNCH | ignore
    $moved
  } else {
    "left alone: the worker may already be running"
  }

  # The worker deletes its staged launch when it starts.
  let staged = (staged-launch $pane)
  let deadline = ((date now) + $wait)
  while ($staged | path exists) and ((date now) < $deadline) { sleep 250ms }
  let launched = not ($staged | path exists)
  if not $launched {
    error make { msg: $"($id)'s worker did not start in pane ($pane) within ($wait); it is still marked running: check the pane, then `luvus task release ($id)`" }
  }
  {
    task: $id
    pane: $pane
    worktree: $task.worktree
    base: $base
    launch: (if $rejected { "finished in Nushell syntax" } else { "started by luvus" })
  }
}
