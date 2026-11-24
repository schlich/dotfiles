# luvus-autopilot: start and merge opted-in luvus task chains when their
# upstream tasks are ready, Dagster-style, merge every gated task of the
# repositories it is given, and deliver luvus/integration once it settles.
#
# A task takes part when its newest `auto` / `auto off` note is `auto`
# (`luvus-auto ID`), or when it depends, through `deps`, on a task that takes
# part and carries no `auto off` itself. For those tasks the watcher:
#   - starts a `queued` task whose deps are all `merged`, oldest first, while
#     fewer than CAP tasks are `running` or `review` and its paths overlap no
#     other task's lease;
#   - merges a `done` task into luvus/integration with `luvus task merge`;
#   - reports, and never retries, a task in `review`, `blocked`, or `failed`.
#
# In a repository listed in MERGE_REPOS it also merges every `done` task
# that has a gate and a branch, unless it says `auto off`: `done` means its
# gate passed. Tasks that were already done when the autopilot first saw the
# repository stay a backlog it lists but never merges, so turning this on
# ships nothing old by surprise.
#
# With DELIVER_REPO set, a pass also starts DELIVER_UNIT, which runs
# `luvus-autopilot deliver`, once luvus/integration there has moved past
# main, no task is waiting to merge, and the branch has not moved for QUIET.
# The delivery is luvus-deliver itself, with its risk verdict and
# mitigations; this adds only the trigger, merging origin/main into the
# branch when it lacks it, a log, and removing the worktrees of the tasks it
# delivered. A delivery that fails is not retried until the branch moves.
#
# The autopilot never resolves a conflict, retries a failed gate, pushes main
# itself, or switches a host: the canary's own timer deploys what lands.
# Every action is appended to events.jsonl in its state directory
# (`luvus-autopilot log`), and each delivery's output to logs/.
#
# Every pass rereads the board, so a duplicate event or a restart never starts
# or merges twice, and passes run one at a time under a lock.
#
# Usage:
#   luvus-autopilot run --module DIR   the service: wake on `luvus events`
#   luvus-autopilot once               one pass now
#   luvus-autopilot pause | resume | toggle | status
#   luvus-autopilot mark ID [--off]    what `luvus-auto` runs
#   luvus-autopilot deliver [--force]  what DELIVER_UNIT runs
#   luvus-autopilot log [--last N]     the actions it took
#   luvus-autopilot plan TASKS.json [LEASES.json]   the decision, no actions
#   luvus-autopilot plan-deliver STATE.json         the delivery decision

# Substituted at build time; the plan and the tests never run them.
const LUVUS = '@luvus@'
const TASK_START = '@taskStart@'
const NOTIFY_SEND = '@notifySend@'
const FLOCK = '@flock@'
const GIT = '@git@'
const SYSTEMCTL = '@systemctl@'
const DELIVER = '@deliver@'
# Configuration, substituted at build time; '@…@' left unsubstituted means
# unset, as in the tests.
const MERGE_REPOS = '@mergeRepos@'   # colon-separated checkouts
const DELIVER_REPO = '@deliverRepo@'
const DELIVER_UNIT = '@deliverUnit@'
const QUIET = '@quiet@'
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

# A checkout or its .git directory, as luvus records a task's project root.
def repo-key [p: any]: nothing -> string {
  if $p == null { return '' }
  $p | into string | str trim --right --char '/' | str replace --regex '/\.git$' ''
}

# Done tasks in a listed repository that the autopilot merges without opt-in:
# gated, on a branch luvus can merge, finished at or after `since`, and not
# marked `auto off`. The rest of that repository's done tasks are a backlog.
def gated-done [tasks: list<any>, repos: list<string>, since: int]: nothing -> record {
  let keys = ($repos | each {|r| repo-key $r } | where $it != '')
  let done = ($tasks | where status == 'done' | where {|t| (repo-key $t.project?.root?) in $keys })
  let ready = {|t|
    (($t.gate? | default '' | str trim) != '') and ($t.branch? != null) and ((marker $t) != 'off')
  }
  let finished = {|t| $t.attempt_finished_at? | default ($t.updated? | default 0) }
  {
    merges: ($done | where {|t| (do $ready $t) and ((do $finished $t) >= $since) } | get id)
    backlog: ($done | where {|t| (do $ready $t) and ((do $finished $t) < $since) } | get id)
    unmergeable: ($done | where {|t| not (do $ready $t) and ((marker $t) != 'off') } | each {|t|
      { id: $t.id, why: (if ($t.gate? | default '' | str trim) == '' { 'no gate' } else if $t.branch? == null { 'no branch' } else { 'unknown' }) }
    })
  }
}

# Decide what one pass does. Pure: reads nothing but its arguments.
export def plan [tasks: list<any>, leases: list<any>, --cap: int = 6, --paused, --repos: list<string> = [], --since: int = 0]: nothing -> record {
  let opted = (opted-ids $tasks)
  let mine = ($tasks | where id in $opted)
  let gated = (gated-done $tasks $repos $since)
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
  # A merge the autopilot tried in a listed repository blocks the task on a
  # conflict, so those stall it too.
  let keys = ($repos | each {|r| repo-key $r } | where $it != '')
  let stalled = ($tasks
    | where {|t| ($t.id in $opted and $t.status in ['review' 'blocked' 'failed']) or ($t.status == 'blocked' and (repo-key $t.project?.root?) in $keys) }
    | each {|t| { id: $t.id, status: $t.status, title: ($t.title? | default ''), attempt: ($t.attempt? | default 1) } })
  {
    paused: $paused
    cap: $cap
    opted: $opted
    active: $active
    eligible: ($eligible | get id)
    starts: (if $paused { [] } else { $starts })
    merges: (if $paused { [] } else {
      $tasks | where status == 'done' | where {|t| $t.id in $opted or $t.id in $gated.merges } | sort-by created id | get id
    })
    waiting_cap: $waiting_cap
    lease_blocked: $lease_blocked
    stalled: $stalled
    backlog: $gated.backlog
    unmergeable: $gated.unmergeable
  }
}

# Decide whether to deliver. Pure. `s` holds:
#   integration, main   the branch's and origin/main's commits (null: none)
#   seen                { sha, since }: when the branch was first seen at sha
#   failed              the commit whose delivery last failed, or null
#   pending             tasks of the repository still to merge
#   running             whether a delivery is running now
#   now, quiet          a datetime and how long the branch must stay put
# It returns the action (idle, wait, busy, stalled, deliver), why, and the
# `seen` to keep for the next pass.
export def deliver-plan [s: record]: nothing -> record {
  let now = ($s.now | into datetime)
  let quiet = ($s.quiet | into duration)
  let seen = if $s.seen?.sha? == $s.integration and $s.integration != null {
    { sha: $s.seen.sha, since: ($s.seen.since | into datetime) }
  } else {
    { sha: $s.integration, since: $now }
  }
  let out = {|action: string, why: string| { action: $action, why: $why, seen: $seen } }
  if $s.integration == null { return (do $out idle 'no integration branch') }
  if $s.integration == $s.main { return (do $out idle 'main is current') }
  if $s.running { return (do $out busy 'a delivery is running') }
  if $s.failed? == $s.integration {
    return (do $out stalled $"delivering ($s.integration | str substring 0..11) failed; waiting for the branch to move")
  }
  if ($s.pending | is-not-empty) { return (do $out wait $"tasks still to merge: ($s.pending | str join ', ')") }
  let settled = $now - $seen.since
  if $settled < $quiet {
    return (do $out wait $"settling: ($quiet - $settled | format duration min | str replace --regex '\.\d+' '') to go")
  }
  do $out deliver $"($s.integration | str substring 0..11) has been quiet for ($settled | format duration min | str replace --regex '\.\d+' '')"
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

# A substituted setting, or null when the build left it unset.
def configured [v: string]: nothing -> any {
  if ($v | str starts-with '@') or ($v | str trim) == '' { null } else { $v }
}
def merge-repos [] { configured $MERGE_REPOS | default '' | split row ':' | where $it != '' }
def deliver-repo [] { configured $DELIVER_REPO }

# Append one action to events.jsonl. A log that cannot be written never
# stops the action.
def record-event [action: string, fields: record = {}] {
  try {
    let entry = ({ at: (date now | format date '%+'), action: $action } | merge $fields)
    $"($entry | to json --raw)\n" | save --append (state-dir | path join events.jsonl)
  }
}

# Report a phase to PST_FILE, as osc7501.nu's `pst report` would, so
# `watch-job LOG` follows a delivery.
def report [state: string, id: string, msg: string = ''] {
  if ($env.PST_FILE? | is-empty) { return }
  try {
    $"({ time: (date now | format date '%+'), state: $state, id: $id, app: luvus-autopilot, msg: $msg } | to json --raw)\n" | save --append $env.PST_FILE
  }
}

# When the autopilot first merged for MERGE_REPOS: tasks done before then
# are a backlog it leaves alone.
def merge-since [] {
  let file = (state-dir | path join merge-since)
  if not ($file | path exists) { date now | format date '%s' | save $file }
  open --raw $file | str trim | into int
}

def deliver-state-file [] { state-dir | path join deliver.nuon }
def deliver-state [] { try { open (deliver-state-file) } catch { {} } }
def save-deliver-state [s: record] { $s | to nuon | save --force (deliver-state-file) }

def rev [repo: string, ref: string] {
  let r = (^$GIT -C $repo rev-parse --verify --quiet $"($ref)^{commit}" | complete)
  if $r.exit_code == 0 { $r.stdout | str trim } else { null }
}

def is-ancestor [repo: string, a: string, b: string] {
  (^$GIT -C $repo merge-base --is-ancestor $a $b | complete).exit_code == 0
}

def delivery-running [] {
  let unit = (configured $DELIVER_UNIT)
  if $unit == null { return false }
  (^$SYSTEMCTL --user is-active $unit | complete | get stdout | str trim) in [active activating reloading]
}

# The worktree that has luvus/integration checked out: luvus merges there.
def integration-worktree [repo: string] {
  mut path: any = null
  for line in (^$GIT -C $repo worktree list --porcelain | lines) {
    if ($line | str starts-with 'worktree ') { $path = ($line | str substring 9..) }
    if $line == 'branch refs/heads/luvus/integration' { return $path }
  }
  null
}

# Merge `rev` into luvus/integration in its worktree, under the lock
# luvus-ship takes too, aborting on a conflict.
def merge-into-integration [repo: string, target: string, message: string] {
  let wt = (integration-worktree $repo)
  if $wt == null { return { ok: false, detail: 'no worktree has luvus/integration checked out' } }
  let dirty = (^$GIT -C $wt status --porcelain | complete | get stdout | str trim)
  if $dirty != '' { return { ok: false, detail: $"the integration worktree ($wt) has uncommitted changes" } }
  let script = '"$4" -C "$1" merge --no-ff --no-edit -m "$2" "$3" || { "$4" -C "$1" merge --abort; exit 1; }'
  let r = (^$FLOCK --wait 600 (state-dir | path join integration.lock) sh -c $script sh $wt $message $target $GIT | complete)
  { ok: ($r.exit_code == 0), detail: ([$r.stdout $r.stderr] | str join "\n" | str trim) }
}

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
  ] | append (if $stalled > 0 { [{ type: separator } { type: badge, text: $"($stalled) stalled", tone: error }] } else { [] })
  # Only the delivery's state, not its countdown, so the widget changes, and
  # wakes the watcher, only when the state does.
  | append (match ($p.delivery?.action? | default 'idle') {
      'wait' => [{ type: separator } { type: text, text: 'deliver: settling', tone: normal }]
      'deliver' | 'delivering' | 'busy' => [{ type: separator } { type: badge, text: 'delivering', tone: accent }]
      'stalled' => [{ type: separator } { type: badge, text: 'delivery failed', tone: error }]
      'paused' => [{ type: separator } { type: text, text: 'deliver: paused', tone: warning }]
      _ => []
    }))
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
  record-event start { task: $id, title: ($task.title? | default ''), ok: ($r.exit_code == 0), detail: ($r.stderr | str trim) }
  if $r.exit_code != 0 { log $"start ($id) failed; will retry on a later event: ($r.stderr | str trim)" }
}

def act-merge [id: string, task: record] {
  log $"merging ($id)"
  let repo = (repo-key $task.project?.root?)
  let before = if $repo == '' { null } else { rev $repo 'refs/heads/luvus/integration' }
  let r = (^$LUVUS task merge $id | complete)
  let after = (try { luvus-json task get $id | get task.status } catch { 'unknown' })
  let head = if $repo == '' { null } else { rev $repo 'refs/heads/luvus/integration' }
  record-event merge { task: $id, title: ($task.title? | default ''), branch: $task.branch?, status: $after, integration_before: $before, integration_after: $head }
  if $after == 'merged' {
    notify $"luvus merged ($id)" $"($task.title? | default '') is in luvus/integration."
  } else {
    log $"merge ($id) left it ($after): ($r.stdout | str trim) ($r.stderr | str trim)"
  }
}

# Start the delivery unit when deliver-plan says so; return its decision.
def consider-delivery [p: record, tasks: list<any>] {
  let repo = (deliver-repo)
  if $repo == null { return null }
  let state = (deliver-state)
  let integration = (rev $repo 'refs/heads/luvus/integration')
  mut main = (rev $repo 'refs/remotes/origin/main')
  # Fetch only when there may be something to deliver.
  if $integration != null and $integration != $main {
    ^$GIT -C $repo fetch --quiet origin main | complete | ignore
    $main = (rev $repo 'refs/remotes/origin/main')
  }
  let key = (repo-key $repo)
  let pending = ($tasks | where id in $p.merges | where {|t| (repo-key $t.project?.root?) == $key } | get id)
  let d = (deliver-plan {
    integration: $integration, main: $main, seen: $state.seen?, failed: $state.failed?.sha?
    pending: $pending, running: (delivery-running), now: (date now), quiet: (configured $QUIET | default '10min')
  })
  save-deliver-state ($state | upsert seen $d.seen)
  if $d.action != 'deliver' { return $d }
  if $p.paused { return ($d | update action paused) }
  let unit = (configured $DELIVER_UNIT)
  let r = (^$SYSTEMCTL --user start --no-block $unit | complete)
  record-event deliver-triggered { base: $main, head: $integration, why: $d.why, ok: ($r.exit_code == 0), detail: ($r.stderr | str trim) }
  if $r.exit_code != 0 { log $"could not start ($unit): ($r.stderr | str trim)" }
  $d | update action delivering
}

# Remove the worktrees and branches of the repository's merged tasks that
# main now holds. luvus refuses a worktree a task, lease, or live agent
# still uses; such a worktree is logged and left.
def prune-delivered [repo: string, main: string] {
  let key = (repo-key $repo)
  let tasks = (try { luvus-json task list | unwrap tasks } catch { [] }
    | where status == 'merged'
    | where {|t| (repo-key $t.project?.root?) == $key and $t.worktree? != null and $t.branch? != null }
    | where {|t| $t.worktree | path exists })
  for t in $tasks {
    if not (is-ancestor $repo $t.branch $main) { continue }
    let r = (^$LUVUS worktree remove $t.worktree | complete)
    let reply = (try { $r.stdout | from json } catch { null })
    if $r.exit_code != 0 or $reply == null or $reply.error? != null {
      let why = ($reply.error?.message? | default ($r.stderr | str trim))
      record-event prune-skipped { task: $t.id, worktree: $t.worktree, why: $why }
      log $"left ($t.worktree): ($why)"
      continue
    }
    let b = (^$GIT -C $repo branch -D $t.branch | complete)
    record-event pruned { task: $t.id, worktree: $t.worktree, branch: $t.branch, branch_deleted: ($b.exit_code == 0) }
    log $"removed ($t.id)'s worktree and branch ($t.branch)"
  }
}

# One pass, already holding the lock: act until the board stops changing.
def pass [--force-bar] {
  let repos = (merge-repos)
  let since = if ($repos | is-empty) { 0 } else { merge-since }
  mut board = (read-board)
  mut p = (plan $board.tasks $board.leases --cap $CAP --paused=(is-paused) --repos $repos --since $since)
  for round in 1..5 {
    if ($p.merges | is-empty) and ($p.starts | is-empty) { break }
    let b = $board
    for id in $p.merges { act-merge $id ($b.tasks | where id == $id | first) }
    for id in $p.starts { act-start $id ($b.tasks | where id == $id | first) }
    $board = (read-board)
    $p = (plan $board.tasks $board.leases --cap $CAP --paused=(is-paused) --repos $repos --since $since)
  }
  report-stalls $p.stalled
  let delivery = (try { consider-delivery $p $board.tasks } catch {|e| log $"delivery check failed: ($e.msg)"; null })
  let p = ($p | insert delivery $delivery)
  push-bar $p --force=$force_bar
  $p
}

# Merge origin/main into luvus/integration when the branch lacks it, as
# luvus-deliver requires; return the branch's new head, or raise.
def bring-in-main [repo: string, head: string, base: string] {
  if (is-ancestor $repo $base $head) { return $head }
  report working merge-main 'origin/main has commits luvus/integration lacks'
  let m = (merge-into-integration $repo $base "Merge remote-tracking branch 'origin/main' into luvus/integration")
  if not $m.ok {
    report failed merge-main $m.detail
    error make { msg: $"merging origin/main into luvus/integration failed: ($m.detail)" }
  }
  report done merge-main
  rev $repo 'refs/heads/luvus/integration'
}

# Run `once` under the lock, in a child so the lock ends with it.
def --wrapped locked [...args: string] {
  ^$FLOCK --wait 600 (state-dir | path join lock) $nu.current-exe --no-config-file $SELF ...$args
}

# ── Commands ──────────────────────────────────────────────────────────────

def main [] {
  print 'usage: luvus-autopilot run|once|pause|resume|toggle|status|mark|deliver|log|plan|plan-deliver (see the header of this script)'
}

# One pass now. Without the lock held it takes the lock first.
def "main once" [--force-bar --locked] {
  if not $locked { locked once --locked ...(if $force_bar { [--force-bar] } else { [] }); return }
  let p = (pass --force-bar=$force_bar)
  let delivery = if $p.delivery == null { '' } else { $", delivery ($p.delivery.action): ($p.delivery.why)" }
  log $"pass: ($p.starts | length) started, ($p.merges | length) merged, ($p.eligible | length) eligible, ($p.active | length)/($p.cap) workers, ($p.stalled | length) stalled(if $p.paused { ', paused' } else { '' })($delivery)"
}

# Deliver luvus/integration in DELIVER_REPO with luvus-deliver: what
# DELIVER_UNIT runs. Its output goes to logs/deliver-TIME-SHA.log, with
# LOG.status.jsonl and LOG.done.nuon beside it, so `watch-job LOG` follows it.
def "main deliver" [
  --force # deliver even while the autopilot is paused
] {
  let repo = (deliver-repo)
  if $repo == null { error make { msg: 'luvus-autopilot: no delivery repository is configured' } }
  if (is-paused) and not $force {
    log 'paused; not delivering'
    record-event deliver-skipped { why: paused }
    return
  }
  ^$GIT -C $repo fetch --quiet origin main
  let base = (rev $repo 'refs/remotes/origin/main')
  let head = (rev $repo 'refs/heads/luvus/integration')
  if $head == null or $head == $base {
    log 'main is current; nothing to deliver'
    return
  }
  let logs = (state-dir | path join logs)
  mkdir $logs
  let logfile = ($logs | path join $"deliver-(date now | format date '%Y%m%dT%H%M%S')-($head | str substring 0..11).log")
  $env.PST_FILE = $"($logfile).status.jsonl"
  record-event deliver-started { base: $base, head: $head, log: $logfile }
  log $"delivering ($head | str substring 0..11) over ($base | str substring 0..11); log: ($logfile)"
  let outcome = (try {
    let head = (bring-in-main $repo $head $base)
    report working deliver $"luvus-deliver ($head | str substring 0..11)"
    let r = (^$DELIVER --repo $repo o+e>| tee { save --append $logfile } | complete)
    print $r.stdout
    if $r.exit_code != 0 {
      let why = ($r.stdout | str trim | lines | last 3 | str join ' ')
      report failed deliver $why
      { exit_code: $r.exit_code, head: $head, error: $why }
    } else {
      report done deliver
      { exit_code: 0, head: $head, error: null }
    }
  } catch {|e| { exit_code: 1, head: $head, error: $e.msg } })
  $outcome | to nuon | save --force $"($logfile).done.nuon"
  let short = ($outcome.head | str substring 0..11)
  if $outcome.exit_code == 0 {
    save-deliver-state (deliver-state | upsert failed null)
    record-event delivered { base: $base, head: $outcome.head, log: $logfile }
    notify $"Delivered ($short) to main" $"The canary deploys it next. Log: ($logfile)"
    report working prune 'removing delivered task worktrees'
    try { prune-delivered $repo $outcome.head } catch {|e| log $"prune failed: ($e.msg)" }
    report done prune
  } else {
    save-deliver-state (deliver-state | upsert failed { sha: $outcome.head, at: (date now | format date '%+'), error: $outcome.error })
    record-event deliver-failed { base: $base, head: $outcome.head, log: $logfile, error: $outcome.error }
    notify --urgency critical $"Delivery of ($short) failed" $"($outcome.error) The autopilot waits for luvus/integration to move before trying again. Log: ($logfile)"
    exit 1
  }
}

# The actions the autopilot took, newest last.
def "main log" [--last: int = 20] {
  let file = (state-dir | path join events.jsonl)
  if not ($file | path exists) { return [] }
  open --raw $file | lines | where $it != '' | each {|l| try { $l | from json } catch { null } } | compact | last $last
}

# Repaint the bar widget; the module's startup hook runs this.
def "main bar" [] { locked once --locked --force-bar }

def "main pause" [] { touch (paused-file); log 'paused'; main once }
def "main resume" [] { rm --force (paused-file); log 'resumed'; main once }
def "main toggle" [] { if (is-paused) { main resume } else { main pause } }

# The current plan, without acting on it.
def "main status" [] {
  let b = (read-board)
  let repos = (merge-repos)
  let since = if ($repos | is-empty) { 0 } else { merge-since }
  let state = (deliver-state)
  plan $b.tasks $b.leases --cap $CAP --paused=(is-paused) --repos $repos --since $since | reject opted
  | insert delivery { repo: (deliver-repo), running: (delivery-running), seen: $state.seen?, failed: $state.failed? }
}

# Mark task ID for the autopilot, or with --off unmark it.
def "main mark" [id: string, --off] {
  let note = if $off { 'auto off' } else { 'auto' }
  luvus-json task update $id --note $note | ignore
  print $"($id): ($note)"
}

# Print the plan for a `luvus task list` reply and an optional `luvus lease
# list` reply, as JSON.
def "main plan" [tasks: path, leases?: path, --cap: int = 6, --paused, --repos: string = '' # colon-separated, as MERGE_REPOS
  --since: int = 0] {
  let t = (open $tasks | unwrap tasks)
  let l = if $leases == null { [] } else { open $leases | unwrap leases }
  plan $t $l --cap $cap --paused=$paused --repos ($repos | split row ':' | where $it != '') --since $since | to json
}

# Print deliver-plan's decision for the state in a JSON file, as JSON.
def "main plan-deliver" [state: path] {
  deliver-plan (open $state) | to json
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
