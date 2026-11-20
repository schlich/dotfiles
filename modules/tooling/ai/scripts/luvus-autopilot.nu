# luvus-autopilot: start and merge opted-in luvus task chains when their
# upstream tasks are ready, Dagster-style.
#
# A task takes part when its newest `auto` / `auto off` note is `auto`
# (`luvus-auto ID`), or when it depends, through `deps`, on a task that takes
# part and carries no `auto off` itself. For those tasks the watcher:
#   - starts a `queued` task whose deps are all `merged`, oldest first, while
#     fewer than CAP tasks are `running` or `review` and its paths overlap no
#     other task's lease;
#   - merges a `done` task into luvus/integration with `luvus task merge`;
#   - reports, and never retries, a task in `review`, `blocked`, or `failed`.
# It never resolves a conflict, delivers, pushes `main`, or switches a host.
#
# Every pass rereads the board, so a duplicate event or a restart never starts
# or merges twice, and passes run one at a time under a lock.
#
# Usage:
#   luvus-autopilot run --module DIR   the service: wake on `luvus events`
#   luvus-autopilot once               one pass now
#   luvus-autopilot pause | resume | toggle | status
#   luvus-autopilot mark ID [--off]    what `luvus-auto` runs
#   luvus-autopilot plan TASKS.json [LEASES.json]   the decision, no actions

# Substituted at build time; the plan and the tests never run them.
const LUVUS = '@luvus@'
const TASK_START = '@taskStart@'
const NOTIFY_SEND = '@notifySend@'
const FLOCK = '@flock@'
const SELF = path self
const CAP = 6
const MODULE_ID = 'dotfiles.autopilot'
const WIDGET = 'autopilot'
const AGENT = 'claude'

# ── The plan: pure, so the tests can run it against fixtures ─────────────

# A board reply (`{result: {tasks}}`), its result, or a bare list.
def unwrap [key: string]: any -> list<any> {
  let v = $in
  if $v == null { return [] }
  if ($v | describe) =~ '^(list|table)' { return $v }
  if ($v.result? != null) { return ($v.result | get --optional $key | default []) }
  $v | get --optional $key | default []
}

# The task's newest opt-in marker: "on", "off", or null.
def marker [task: record]: nothing -> any {
  let marks = ($task.notes? | default [] | where {|n| ($n | describe) == 'string' }
    | each {|n| $n | str trim | str lowercase }
    | where {|n| $n in ['auto' 'auto off'] })
  if ($marks | is-empty) { null } else if ($marks | last) == 'auto' { 'on' } else { 'off' }
}

def dep-ids [task: record]: nothing -> list<string> {
  $task.deps? | default [] | each {|d| $d | into string }
}

# Tasks that take part: marked ones and, transitively, those downstream of
# one, except where a task says `auto off`.
def opted-ids [tasks: list<any>]: nothing -> list<string> {
  let marks = ($tasks | each {|t| { id: $t.id, mark: (marker $t) } })
  let off = ($marks | where mark == 'off' | get id)
  mut opted = ($marks | where mark == 'on' | get id)
  loop {
    let current = $opted
    let more = ($tasks | where {|t|
      $t.id not-in $current and $t.id not-in $off and (dep-ids $t | any {|d| $d in $current })
    } | get id)
    if ($more | is-empty) { break }
    $opted = ($current | append $more)
  }
  $opted
}

# luvus's own overlap rule (src/orch/mod.rs): reduce each pattern to the
# directory before its first glob character, then compare by path segment.
def glob-prefix [p: string]: nothing -> string {
  let path = ($p | str trim | str replace --all '\' '/' | str replace --regex '^(\./)+' '' | str replace --all --regex '/{2,}' '/')
  let first = (['*' '?' '[' '{'] | each {|c| $path | str index-of $c } | where {|i| $i >= 0 } | sort)
  if ($first | is-empty) { return ($path | str trim --right --char '/') }
  let literal = ($path | str substring 0..<($first | first))
  if ($literal | str ends-with '/') { return ($literal | str trim --right --char '/') }
  let parts = ($literal | split row '/')
  if ($parts | length) <= 1 { '' } else { $parts | drop 1 | str join '/' }
}

def paths-overlap [a: string, b: string]: nothing -> bool {
  let a = (glob-prefix $a)
  let b = (glob-prefix $b)
  ($a == '' or $b == '' or $a == $b or ($b | str starts-with $"($a)/") or ($a | str starts-with $"($b)/"))
}

def same-project [x: any, y: any]: nothing -> bool {
  if $x == null or $y == null { return true }
  ($x.workspace_id? == $y.workspace_id? and $x.workspace_id? != null) or ($x.root? == $y.root? and $x.root? != null)
}

# The lease another task holds over this task's paths, or null.
def lease-holder [task: record, leases: list<any>, tasks: list<any>]: nothing -> any {
  let paths = ($task.paths? | default [])
  let hit = ($leases | where {|l|
    let holder = ($tasks | where id == $l.task | get --optional 0.project)
    ($l.task != $task.id) and (same-project $task.project? $holder) and ($l.paths | any {|lp| $paths | any {|tp| paths-overlap $lp $tp } })
  })
  if ($hit | is-empty) { null } else { $hit | first | get task }
}

# Decide what one pass does. Pure: reads nothing but its arguments.
export def plan [tasks: list<any>, leases: list<any>, --cap: int = 6, --paused]: nothing -> record {
  let opted = (opted-ids $tasks)
  let mine = ($tasks | where id in $opted)
  let status_of = ($tasks | reduce --fold {} {|t, acc| $acc | insert $t.id $t.status })
  let active = ($tasks | where status in ['running' 'review'] | get id)
  let eligible = ($mine
    | where status == 'queued'
    | where {|t| dep-ids $t | all {|d| ($status_of | get --optional $d) == 'merged' } }
    | sort-by created id)
  mut room = ([($cap - ($active | length)) 0] | math max)
  mut held = $leases
  mut starts = []
  mut lease_blocked = []
  mut waiting_cap = []
  for t in $eligible {
    let holder = (lease-holder $t $held $tasks)
    if $holder != null {
      $lease_blocked = ($lease_blocked | append { id: $t.id, holder: $holder })
    } else if $room <= 0 {
      $waiting_cap = ($waiting_cap | append $t.id)
    } else {
      $starts = ($starts | append $t.id)
      $held = ($held | append { task: $t.id, paths: ($t.paths? | default []) })
      $room = $room - 1
    }
  }
  let stalled = ($mine | where status in ['review' 'blocked' 'failed']
    | each {|t| { id: $t.id, status: $t.status, title: ($t.title? | default ''), attempt: ($t.attempt? | default 1) } })
  {
    paused: $paused
    cap: $cap
    opted: $opted
    active: $active
    eligible: ($eligible | get id)
    starts: (if $paused { [] } else { $starts })
    merges: (if $paused { [] } else { $mine | where status == 'done' | sort-by created id | get id })
    waiting_cap: $waiting_cap
    lease_blocked: $lease_blocked
    stalled: $stalled
  }
}

# ── Live board and state ───────────────────────────────────────────────────

def state-dir [] {
  let base = ($env.XDG_STATE_HOME? | default ($env.HOME | path join .local state))
  let dir = ($base | path join luvus-autopilot)
  mkdir $dir
  $dir
}

def paused-file [] { state-dir | path join paused }
def is-paused [] { paused-file | path exists }

def log [msg: string] { print $"luvus-autopilot: ($msg)" }

# Run luvus and return its result, or raise its error.
def --wrapped luvus-json [...args: string] {
  let r = (^$LUVUS ...$args | complete)
  let reply = (try { $r.stdout | from json } catch { null })
  if $reply == null {
    error make { msg: $"luvus ($args | str join ' ') failed: ($r.stderr | str trim)" }
  }
  if ($reply.error? != null) {
    error make { msg: $"luvus ($args | str join ' '): ($reply.error.code? | default ''): ($reply.error.message? | default '')" }
  }
  $reply.result
}

def read-board [] {
  { tasks: (luvus-json task list | unwrap tasks), leases: (luvus-json lease list | unwrap leases) }
}

def notify [summary: string, body: string, --urgency: string = 'normal'] {
  log $"($summary): ($body)"
  ^$NOTIFY_SEND --app-name luvus-autopilot --urgency $urgency $summary $body | complete | ignore
}

# Notify once for each task's stall, again only if it stalls anew.
def report-stalls [stalled: list<any>] {
  let file = (state-dir | path join notified.nuon)
  let seen = (try { open $file } catch { [] })
  let keys = ($stalled | each {|s| $"($s.id):($s.status):($s.attempt)" })
  for s in $stalled {
    let key = $"($s.id):($s.status):($s.attempt)"
    if $key not-in $seen {
      let why = match $s.status {
        'review' => 'failed its gate'
        'blocked' => 'is blocked (merge conflict or a blocker)'
        _ => 'failed'
      }
      notify --urgency critical $"luvus chain stalled: ($s.id)" $"($s.title) ($why); the autopilot will not retry it."
    }
  }
  $keys | to nuon | save --force $file
}

def bar-content [p: record] {
  let mode = if $p.paused { 'paused' } else { 'auto' }
  let busy = ($p.active | length)
  let stalled = ($p.stalled | length)
  let full = ([
    { type: state, state: (if $p.paused { 'idle' } else { 'working' }), label: $mode, tone: (if $p.paused { 'warning' } else { 'accent' }), action: toggle }
    { type: separator }
    { type: text, text: $"($p.eligible | length) eligible", tone: normal }
    { type: separator }
    { type: text, text: $"($busy)/($p.cap) workers", tone: (if $busy >= $p.cap { 'warning' } else { 'normal' }) }
  ] | append (if $stalled > 0 { [{ type: separator } { type: badge, text: $"($stalled) stalled", tone: error }] } else { [] }))
  let compact = [
    { type: state, state: (if $p.paused { 'idle' } else { 'working' }), label: $mode, action: toggle }
    { type: text, text: $"($busy)/($p.cap)" }
  ]
  { full: $full, compact: $compact }
}

# Publish the mode widget, skipping an unchanged one so a push never wakes
# the watcher into another pass.
def push-bar [p: record, --force] {
  let c = (bar-content $p)
  let file = (state-dir | path join bar.json)
  let last = (try { open --raw $file } catch { '' })
  let now = ($c | to json --raw)
  if (not $force) and $now == $last { return }
  let r = (^$LUVUS bar push --id $WIDGET --content ($c.full | to json --raw) --compact-content ($c.compact | to json --raw) | complete)
  if $r.exit_code == 0 { $now | save --force $file } else { log $"bar push failed: ($r.stdout | str trim) ($r.stderr | str trim)" }
}

# Register the bar's module at DIR, relinking when a new generation moved it.
def ensure-module [dir: string] {
  let want = ($dir | path expand)
  let have = (luvus-json module list | unwrap modules | where id == $MODULE_ID)
  if ($have | is-not-empty) and (($have | first | get root) == $want) { return }
  if ($have | is-not-empty) { luvus-json module unlink $MODULE_ID | ignore }
  luvus-json module link $want | ignore
  log $"linked module ($MODULE_ID) at ($want)"
}

def act-start [id: string, task: record] {
  log $"starting ($id)"
  let args = ([$id --agent $AGENT] | append (if ($task.project?.workspace_id? != null) { [--workspace-id $task.project.workspace_id] } else { [] }))
  let r = (^$TASK_START ...$args | complete)
  if $r.exit_code != 0 { log $"start ($id) failed; will retry on a later event: ($r.stderr | str trim)" }
}

def act-merge [id: string, task: record] {
  log $"merging ($id)"
  let r = (^$LUVUS task merge $id | complete)
  let after = (try { luvus-json task get $id | get task.status } catch { 'unknown' })
  if $after == 'merged' {
    notify $"luvus merged ($id)" $"($task.title? | default '') is in luvus/integration."
  } else {
    log $"merge ($id) left it ($after): ($r.stdout | str trim) ($r.stderr | str trim)"
  }
}

# One pass, already holding the lock: act until the board stops changing.
def pass [--force-bar] {
  mut board = (read-board)
  mut p = (plan $board.tasks $board.leases --cap $CAP --paused=(is-paused))
  for round in 1..5 {
    if ($p.merges | is-empty) and ($p.starts | is-empty) { break }
    let b = $board
    for id in $p.merges { act-merge $id ($b.tasks | where id == $id | first) }
    for id in $p.starts { act-start $id ($b.tasks | where id == $id | first) }
    $board = (read-board)
    $p = (plan $board.tasks $board.leases --cap $CAP --paused=(is-paused))
  }
  report-stalls $p.stalled
  push-bar $p --force=$force_bar
  $p
}

# Run `once` under the lock, in a child so the lock ends with it.
def --wrapped locked [...args: string] {
  ^$FLOCK --wait 600 (state-dir | path join lock) $nu.current-exe --no-config-file $SELF ...$args
}

# ── Commands ──────────────────────────────────────────────────────────────

def main [] {
  print 'usage: luvus-autopilot run|once|pause|resume|toggle|status|mark|plan (see the header of this script)'
}

# One pass now. Without the lock held it takes the lock first.
def "main once" [--force-bar --locked] {
  if not $locked { locked once --locked ...(if $force_bar { [--force-bar] } else { [] }); return }
  let p = (pass --force-bar=$force_bar)
  log $"pass: ($p.starts | length) started, ($p.merges | length) merged, ($p.eligible | length) eligible, ($p.active | length)/($p.cap) workers, ($p.stalled | length) stalled(if $p.paused { ', paused' } else { '' })"
}

# Repaint the bar widget; the module's startup hook runs this.
def "main bar" [] { locked once --locked --force-bar }

def "main pause" [] { touch (paused-file); log 'paused'; main once }
def "main resume" [] { rm --force (paused-file); log 'resumed'; main once }
def "main toggle" [] { if (is-paused) { main resume } else { main pause } }

# The current plan, without acting on it.
def "main status" [] {
  let b = (read-board)
  plan $b.tasks $b.leases --cap $CAP --paused=(is-paused) | reject opted
}

# Mark task ID for the autopilot, or with --off unmark it.
def "main mark" [id: string, --off] {
  let note = if $off { 'auto off' } else { 'auto' }
  luvus-json task update $id --note $note | ignore
  print $"($id): ($note)"
}

# Print the plan for a `luvus task list` reply and an optional `luvus lease
# list` reply, as JSON.
def "main plan" [tasks: path, leases?: path, --cap: int = 6, --paused] {
  let t = (open $tasks | unwrap tasks)
  let l = if $leases == null { [] } else { open $leases | unwrap leases }
  plan $t $l --cap $cap --paused=$paused | to json
}

# The service: a pass at start, after each burst of `luvus events`, and
# every INTERVAL; the event stream is reopened whenever it closes.
def "main run" [--module: string, --interval: duration = 5min] {
  let luvus = $LUVUS
  job spawn {
    loop {
      try { ^$luvus events | lines | each {|_| 'event' | job send 0 } | ignore } catch {|e| print $"luvus-autopilot: events: ($e.msg)" }
      'closed' | job send 0
      sleep 5sec
    }
  } | ignore
  loop {
    if $module != null { try { ensure-module $module } catch {|e| log $"module: ($e.msg)" } }
    try { main once } catch {|e| log $"pass failed: ($e.msg)" }
    try { job recv --timeout $interval | ignore } catch { }
    # Let a burst of events settle, then take them all as one signal.
    sleep 2sec
    loop { try { job recv --timeout 0sec | ignore } catch { break } }
  }
}
