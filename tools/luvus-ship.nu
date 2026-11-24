# luvus-ship: carry a finished task worktree into luvus/integration in one
# step, instead of running each check and the merge by hand.
#
# From the task's worktree it:
#   1. runs `prek run --all-files`, and stops if a hook fails or rewrote a
#      file, so the fix is committed before anything is gated;
#   2. points the task's branch at its latest change (`luvus-jj sync`, which
#      also refuses undescribed or conflicted changes);
#   3. runs the gate: the task's own with --task, otherwise the repository's
#      default, the same `gateChecks` build luvus runs;
#   4. merges exactly the commit the gate passed into luvus/integration, in
#      the worktree that has it checked out, under the lock the autopilot
#      takes, and aborts the merge on a conflict;
#   5. with --task, marks the task done on the board with a note naming both
#      commits.
# Every step is appended to the autopilot's events.jsonl, and reported to
# PST_FILE, so `job-log` and `watch-job` follow it. It is resumable: a branch
# integration already holds is not merged again.
#
# The autopilot delivers luvus/integration once it has been quiet for a
# while; --deliver starts that delivery now. Where no autopilot delivers,
# --deliver runs luvus-deliver itself.

const LUVUS = '@luvus@'
const LUVUS_JJ = '@luvusJj@'
const FLOCK = '@flock@'
const GIT = '@git@'
const SYSTEMCTL = '@systemctl@'
const DEFAULT_GATE = '@gate@'
const DELIVER_UNIT = '@deliverUnit@'

def configured [v: string]: nothing -> any {
  if ($v | str starts-with '@') or ($v | str trim) == '' { null } else { $v }
}

# The autopilot's state directory, shared so its log and lock are one.
def state-dir [] {
  let base = ($env.XDG_STATE_HOME? | default ($env.HOME | path join .local state))
  let dir = ($base | path join luvus-autopilot)
  mkdir $dir
  $dir
}

def record-event [action: string, fields: record = {}] {
  try {
    let entry = ({ at: (date now | format date '%+'), action: $action } | merge $fields)
    $"($entry | to json --raw)\n" | save --append (state-dir | path join events.jsonl)
  }
}

def report [state: string, id: string, msg: string = ''] {
  if ($env.PST_FILE? | is-empty) { return }
  try {
    $"({ time: (date now | format date '%+'), state: $state, id: $id, app: luvus-ship, msg: $msg } | to json --raw)\n" | save --append $env.PST_FILE
  }
}

def fail [id: string, msg: string, fields: record = {}] {
  report failed $id $msg
  record-event ship-failed ({ step: $id, error: $msg } | merge $fields)
  error make --unspanned { msg: $"luvus-ship: ($msg)" }
}

# Run a command line with sh, as luvus runs a gate, streaming its output;
# return its exit code. A failing external would otherwise end the script.
def run-sh [line: string] {
  try { ^sh -c $line; 0 } catch { $env.LAST_EXIT_CODE }
}

def rev [dir: string, ref: string] {
  let r = (^$GIT -C $dir rev-parse --verify --quiet $"($ref)^{commit}" | complete)
  if $r.exit_code == 0 { $r.stdout | str trim } else { null }
}

# The branch this worktree carries: luvus-jj's record in a jj workspace,
# otherwise Git's current branch.
def task-branch [root: string] {
  let jj = (do { cd $root; ^jj --ignore-working-copy config get luvus.branch } | complete)
  if $jj.exit_code == 0 and ($jj.stdout | str trim) != '' { return ($jj.stdout | str trim) }
  let git = (^$GIT -C $root branch --show-current | complete | get stdout | str trim)
  if $git == '' { null } else { $git }
}

def integration-worktree [repo: string] {
  mut path: any = null
  for line in (^$GIT -C $repo worktree list --porcelain | lines) {
    if ($line | str starts-with 'worktree ') { $path = ($line | str substring 9..) }
    if $line == 'branch refs/heads/luvus/integration' { return $path }
  }
  null
}

def --wrapped luvus-json [...args: string] {
  let r = (^$LUVUS ...$args | complete)
  let reply = (try { $r.stdout | from json } catch { null })
  if $reply == null { error make { msg: $"luvus ($args | str join ' ') failed: ($r.stderr | str trim)" } }
  if ($reply.error? != null) { error make { msg: $"luvus ($args | str join ' '): ($reply.error.message? | default '')" } }
  $reply.result
}

def main [
  --task: string     # the board task this worktree carries, such as t33
  --gate: string     # gate command; defaults to the task's, then the repository's
  --skip-prek        # skip `prek run --all-files`
  --deliver          # start the delivery now instead of after the quiet period
] {
  let root = (^$GIT rev-parse --show-toplevel | complete | get stdout | str trim)
  if $root == '' { error make --unspanned { msg: 'luvus-ship: run it from the task worktree' } }
  let repo = (^$GIT -C $root rev-parse --path-format=absolute --git-common-dir | str trim | path dirname)
  if $root == $repo { error make --unspanned { msg: $"luvus-ship: ($root) is the shared checkout; run it from the task's own worktree" } }
  let board = if $task == null { null } else { luvus-json task get $task | get task }
  let base = { task: $task, worktree: $root }

  if not $skip_prek {
    report working prek 'prek run --all-files'
    let code = (do { cd $root; run-sh 'prek run --all-files' })
    if $code != 0 { fail prek 'prek failed or rewrote files; commit its fixes and run luvus-ship again' $base }
    report done prek
  }

  report working sync 'luvus-jj sync'
  let synced = (do { cd $root; ^$LUVUS_JJ sync } | complete)
  if $synced.exit_code != 0 { fail sync ($synced.stderr | str trim) $base }
  let branch = (task-branch $root)
  if $branch == null { fail sync 'this worktree has no branch to ship' $base }
  let sha = (rev $repo $"refs/heads/($branch)")
  if $sha == null { fail sync $"branch ($branch) does not exist" $base }
  let short = ($sha | str substring 0..11)
  report done sync $"($branch) at ($short)"
  let base = ($base | merge { branch: $branch, sha: $sha })

  let integration = (rev $repo 'refs/heads/luvus/integration')
  let already = $integration != null and ((^$GIT -C $repo merge-base --is-ancestor $sha $integration | complete).exit_code == 0)
  if $already {
    print $"($branch) at ($short) is already in luvus/integration."
    record-event ship-skipped ($base | merge { why: 'already in luvus/integration' })
  } else {
    let gate_line = ([$gate ($board | get -o gate) (configured $DEFAULT_GATE)] | compact | where ($it | str trim) != '' | get -o 0)
    if $gate_line == null { fail gate 'no gate: pass --gate' $base }
    report working gate $gate_line
    print $"Gating ($branch) at ($short): ($gate_line)"
    let code = (do { cd $root; run-sh $gate_line })
    if $code != 0 { fail gate $"the gate failed \(exit ($code)\); fix it and run luvus-ship again" ($base | merge { gate: $gate_line }) }
    # The gate ran luvus-jj sync again; ship only what it checked.
    let after = (rev $repo $"refs/heads/($branch)")
    if $after != $sha { fail gate $"($branch) moved from ($short) during the gate; run luvus-ship again" $base }
    report done gate

    report working merge 'into luvus/integration'
    let wt = (integration-worktree $repo)
    if $wt == null { fail merge 'no worktree has luvus/integration checked out; merge one luvus task first, or check it out' $base }
    let dirty = (^$GIT -C $wt status --porcelain | complete | get stdout | str trim)
    if $dirty != '' { fail merge $"the integration worktree ($wt) has uncommitted changes" $base }
    let script = '"$4" -C "$1" merge --no-ff --no-edit -m "$2" "$3" || { "$4" -C "$1" merge --abort; exit 1; }'
    let m = (^$FLOCK --wait 600 (state-dir | path join integration.lock) sh -c $script sh $wt $"Merge branch '($branch)' into luvus/integration" $sha $GIT | complete)
    if $m.exit_code != 0 {
      fail merge $"merging ($branch) conflicts with luvus/integration; rebase onto it \(jj rebase -b @ -d luvus/integration\), resolve, and run luvus-ship again" ($base | merge { detail: ($m.stdout | str trim) })
    }
    let merged = (rev $repo 'refs/heads/luvus/integration')
    report done merge $"luvus/integration at ($merged | str substring 0..11)"
    record-event shipped ($base | merge { integration_before: $integration, integration_after: $merged })
    print $"Merged ($branch) at ($short) into luvus/integration at ($merged | str substring 0..11)."
    if $task != null {
      # luvus sets `merged` only from its own `task merge`, so the board
      # records `done` and the note says where the work went. A task with a
      # branch luvus knows then merges as a no-op, which marks it merged.
      let note = $"shipped ($branch) at ($short) into luvus/integration at ($merged | str substring 0..11)"
      try { luvus-json task update $task --status done --note $note | ignore } catch {|e|
        print $"Could not record ($task) on the board: ($e.msg)"
      }
    }
  }

  let unit = (configured $DELIVER_UNIT)
  let has_unit = $unit != null and ((^$SYSTEMCTL --user cat $unit | complete).exit_code == 0)
  if not $deliver {
    if $has_unit {
      print 'The autopilot delivers luvus/integration once it has been quiet for a while; `luvus-autopilot log` shows what it did.'
    } else {
      print 'No autopilot delivers here: run `luvus-deliver` as a job-log job when the user asks to deliver.'
    }
    return
  }
  if $has_unit {
    ^$SYSTEMCTL --user start --no-block $unit
    record-event deliver-triggered ($base | merge { by: luvus-ship })
    print $"Started ($unit); follow it with `journalctl --user -fu ($unit)`, or `luvus-autopilot log`."
  } else {
    report working deliver 'luvus-deliver'
    let code = (run-sh $"luvus-deliver --repo '($repo)'")
    if $code != 0 { fail deliver $"luvus-deliver failed \(exit ($code)\)" $base }
    report done deliver
  }
}
