# Run the autopilot's plan against fixture `luvus task list` and `luvus lease
# list` replies, without a luvus server.
# Usage: nu luvus-autopilot.nu <autopilot script>

# A task as `luvus task list` reports it.
def task [id: string, status: string, --deps: list<string> = [], --notes: list<string> = [], --paths: list<string> = [], --created: int = 0, --ws: string = 'w1'] {
  {
    id: $id, title: $"task ($id)", status: $status, deps: $deps, notes: $notes
    paths: (if ($paths | is-empty) { [$"src/($id)/**"] } else { $paths })
    created: (if $created == 0 { ($id | str replace 't' '' | into int) } else { $created })
    attempt: 1, project: { root: $"/repo/($ws)", workspace_id: $ws }
  }
}

def lease [task: string, paths: list<string>] { { id: $"l-($task)", task: $task, pane: 1, paths: $paths } }

def main [script: string] {
  let dir = (mktemp --directory)
  let auto = ['auto']
  let busy = (1..6 | each {|i| task $"t(90 + $i)" running })
  let cases = [
    [name tasks leases flags expect];
    ["starts a marked task whose deps merged"
      [(task t1 merged) (task t2 queued --deps [t1] --notes $auto)] [] []
      { starts: [t2], merges: [], eligible: [t2] }]
    ["opts in tasks downstream of a marked one"
      [(task t1 running --notes $auto) (task t2 merged --deps [t1]) (task t3 queued --deps [t2]) (task t4 queued)] [] []
      { opted: [t1 t2 t3], starts: [t3] }]
    ["leaves unmarked tasks alone"
      [(task t1 merged) (task t2 queued --deps [t1]) (task t3 done)] [] []
      { opted: [], starts: [], merges: [] }]
    ["the newest marker wins: auto off unmarks a task and its chain"
      [(task t1 queued --notes [auto 'auto off']) (task t2 queued --deps [t1])] [] []
      { opted: [], starts: [] }]
    ["a task downstream of an unmarked one stays in when marked itself"
      [(task t1 merged --notes [auto 'auto off']) (task t2 queued --deps [t1] --notes $auto) (task t3 queued --deps [t1])] [] []
      { opted: [t2], starts: [t2] }]
    ["auto off on a downstream task stops the chain there"
      [(task t1 merged --notes $auto) (task t2 merged --deps [t1] --notes ['auto off']) (task t3 queued --deps [t2])] [] []
      { opted: [t1], starts: [] }]
    ["remarking after auto off opts back in"
      [(task t1 queued --notes [auto 'auto off' ' Auto '])] [] []
      { opted: [t1], starts: [t1] }]
    ["waits for every dep to be merged, not done"
      [(task t1 done) (task t2 merged) (task t3 queued --deps [t1 t2] --notes $auto)] [] []
      { eligible: [], starts: [] }]
    ["a missing dep is never merged"
      [(task t3 queued --deps [t9] --notes $auto)] [] []
      { eligible: [], starts: [] }]
    ["merges a done opted-in task"
      [(task t1 done --notes $auto) (task t2 done)] [] []
      { merges: [t1] }]
    ["running and review fill the cap of six"
      ($busy | append (task t1 queued --notes $auto)) [] []
      { starts: [], waiting_cap: [t1], eligible: [t1] }]
    ["review counts toward the cap"
      (($busy | drop 1) | append [(task t97 review) (task t1 queued --notes $auto)]) [] []
      { starts: [], waiting_cap: [t1] }]
    ["one free worker starts the oldest eligible task"
      (($busy | drop 1) | append [(task t2 queued --notes $auto --created 50) (task t3 queued --notes $auto --created 40)]) [] []
      { starts: [t3], waiting_cap: [t2] }]
    ["blocked, done, and merged tasks do not take a worker"
      [(task t1 blocked) (task t2 done) (task t3 merged) (task t4 failed) (task t5 queued --notes $auto)] [] []
      { active: [], starts: [t5] }]
    ["a lease conflict leaves the task queued and the next one starts"
      [(task t1 queued --notes $auto --paths [src/a/**]) (task t2 queued --notes $auto --paths [src/b.nix]) (task t9 running --paths [src/a/x.nix])]
      [(lease t9 [src/a/x.nix])] []
      { starts: [t2], lease_blocked: [{ id: t1, holder: t9 }] }]
    ["a glob lease covers its directory"
      [(task t1 queued --notes $auto --paths [modules/luvus.nix]) (task t9 running)]
      [(lease t9 ['modules/*.nix'])] []
      { starts: [], lease_blocked: [{ id: t1, holder: t9 }] }]
    ["sibling paths do not conflict"
      [(task t1 queued --notes $auto --paths [src/a]) (task t9 running)]
      [(lease t9 [src/ab])] []
      { starts: [t1] }]
    ["a lease in another project does not conflict"
      [(task t1 queued --notes $auto --paths [src/a/**]) (task t9 running --ws w2 --paths [src/a/**])]
      [(lease t9 [src/a/**])] []
      { starts: [t1] }]
    ["a task's own lease is not a conflict"
      [(task t1 queued --notes $auto --paths [src/a/**])] [(lease t1 [src/a/**])] []
      { starts: [t1] }]
    ["two eligible tasks with overlapping paths start one at a time"
      [(task t1 queued --notes $auto --paths [src/a/**]) (task t2 queued --notes $auto --paths [src/a/b.nix])] [] []
      { starts: [t1], lease_blocked: [{ id: t2, holder: t1 }] }]
    ["review, blocked, and failed opted-in tasks stall the chain"
      [(task t1 review --notes $auto) (task t2 blocked --notes $auto) (task t3 failed --notes $auto) (task t4 queued --deps [t2]) (task t5 failed)] [] []
      { starts: [], merges: [], stalled_ids: [t1 t2 t3] }]
    ["paused plans nothing but still counts"
      [(task t1 merged) (task t2 queued --deps [t1] --notes $auto) (task t3 done --notes $auto)] [] [--paused]
      { paused: true, starts: [], merges: [], eligible: [t2] }]
    ["a smaller cap from the command line"
      [(task t1 queued --notes $auto) (task t2 queued --notes $auto) (task t9 running)] [] [--cap 2]
      { starts: [t1], waiting_cap: [t2] }]
  ]
  mut failures = 0
  for c in ($cases | enumerate) {
    let tf = ($dir | path join $"tasks-($c.index).json")
    let lf = ($dir | path join $"leases-($c.index).json")
    # Alternate between full replies and bare lists, as both are accepted.
    if ($c.index mod 2) == 0 {
      { id: '1', result: { revision: 1, type: task_list, tasks: $c.item.tasks } } | to json | save $tf
      { id: '1', result: { revision: 1, type: lease_list, leases: $c.item.leases } } | to json | save $lf
    } else {
      $c.item.tasks | to json | save $tf
      $c.item.leases | to json | save $lf
    }
    let r = (^nu --no-config-file $script plan $tf $lf ...$c.item.flags | complete)
    let got = (try { $r.stdout | from json } catch { null })
    let view = if $got == null { null } else { $got | insert stalled_ids ($got.stalled | get id) }
    let bad = if $view == null { ['no plan'] } else {
      $c.item.expect | transpose key want | where {|e| ($view | get $e.key) != $e.want } | each {|e| $"($e.key): want ($e.want | to nuon) got ($view | get $e.key | to nuon)" }
    }
    let ok = ($r.exit_code == 0 and ($bad | is-empty))
    print $"(if $ok { 'ok  ' } else { 'FAIL' }) luvus-autopilot: ($c.item.name)"
    if not $ok {
      print $"     ($bad | str join '; ') stderr: ($r.stderr | str trim)"
      $failures += 1
    }
  }
  if $failures > 0 { exit 1 }
}
