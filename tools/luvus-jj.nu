# luvus-jj: luvus task worktrees as colocated jj workspaces.
#
# luvus gives each task a Git worktree on its own branch (`luvus/tID`), gates
# it there, and merges that branch into luvus/integration. In a repository
# colocated with jj, this provider makes the worktree a jj workspace as well:
# `jj workspace add --colocate` registers the Git worktree, the task branch
# becomes a jj bookmark, and Git's HEAD is attached to it, which is what luvus
# checks before it opens the worktree. Agents then use jj there. jj detaches
# Git's HEAD whenever the working copy moves, so `luvus-jj sync` points the
# branch at the latest change, and reattaches HEAD, before `luvus task done`.
# In a repository without jj, the provider does what luvus's own Git provider
# does.
#
#   luvus-jj provider        luvus's create or remove request, as JSON on stdin;
#                            run as `nu --stdin luvus-jj.nu provider`
#   luvus-jj sync            in a task workspace: move its branch to the latest
#                            change; a no-op anywhere else
#   luvus-jj prune [REPO]    forget task workspaces whose directories are gone
#   luvus-jj register DIR    link the provider module at DIR into the server

# Substituted at build time; the tests run the script as it is, with the
# tools from PATH.
const JJ_BIN = '@jj@'
const GIT_BIN = '@git@'
const STAT_BIN = '@stat@'
const LUVUS_BIN = '@luvus@'

const MODULE_ID = 'dotfiles.jj-worktrees'
# Records the task branch in a workspace's own jj config.
const BRANCH_KEY = 'luvus.branch'
# The commits a task's own changes start from.
const TASK_BASES = 'trunk() | present("luvus/integration")'

def tool [fixed: string, name: string] {
  if ($fixed | str starts-with '@') { $name } else { $fixed }
}

# Run an external tool and return its stdout; a failure stops with its stderr.
def call [exe: string, args: list<string>] {
  let r = (^$exe ...$args | complete)
  if $r.exit_code != 0 {
    error make --unspanned { msg: $"($exe | path basename) ($args | str join ' ') failed: ($r.stderr | str trim)" }
  }
  $r.stdout
}

def --wrapped jj [...args: string] { call (tool $JJ_BIN 'jj') $args }
def --wrapped git [...args: string] { call (tool $GIT_BIN 'git') $args }

# jj in `dir`, which must be a workspace root, without snapshotting it.
def --wrapped jj-read [dir: string, ...args: string] {
  do { cd $dir; jj --ignore-working-copy ...$args }
}

# jj's revset for a bookmark name, quoted so `/` stays part of the name.
def symbol [name: string] { $'"($name)"' }

def same-path [a: string, b: string] {
  ($a | path expand) == ($b | path expand)
}

# The directory luvus keeps task worktrees under; the server's environment,
# which the provider inherits, may move its state with LUVUS_HOME.
def worktrees-root [] {
  $env.LUVUS_HOME? | default ($env.HOME | path join .luvus) | path join worktrees
}

# Whether the Git repository at `top` is a jj repository colocated with it.
def colocated [top: string] {
  if not ($top | path join .jj | path exists) { return false }
  let jj_git = (try { jj-read $top git root | str trim } catch { return false })
  let common = (git -C $top rev-parse --path-format=absolute --git-common-dir | str trim)
  same-path $jj_git $common
}

# Every jj workspace of the repository at `dir`, with its root.
def workspaces [dir: string] {
  jj-read $dir workspace list -T 'name ++ "\t" ++ root ++ "\n"'
  | lines
  | parse "{name}\t{root}"
}

# The name of the jj workspace whose root is `path`, or null.
def workspace-at [path: string] {
  if not ($path | path join .jj | path exists) { return null }
  let root = (try { jj-read $path workspace root | str trim } catch { return null })
  if not (same-path $root $path) { return null }
  workspaces $path | where {|w| same-path $w.root $path } | get -o 0.name
}

# Forget the task workspaces of the repository at `dir` whose directories are
# gone, as after luvus removes a worktree with Git alone. Only workspaces under
# luvus's worktree folder qualify; their changes stay in the repository.
def prune-in [dir: string] {
  let root = (worktrees-root)
  let stale = (workspaces $dir | where {|w|
    $w.name != 'default' and ($w.root | is-not-empty) and ($w.root | str starts-with $root) and not ($w.root | path exists)
  })
  for w in $stale { jj-read $dir workspace forget $w.name | ignore }
  $stale | get name
}

def slug [branch: string] { $branch | str replace --all --regex '[/\s]' '-' }

# Where luvus's own provider would put the worktree: under the main
# worktree's name, at the first free `<branch>`, `<branch>-2`, ...
def free-path [top: string, branch: string] {
  let main = (git -C $top worktree list --porcelain | lines | where $it starts-with 'worktree ' | first | str substring 9..)
  let parent = ((worktrees-root) | path join ($main | path basename))
  let base = ($parent | path join (slug $branch))
  mut path = $base
  mut n = 2
  while ($path | path exists) {
    $path = $"($base)-($n)"
    $n += 1
  }
  $path
}

def free-name [top: string, wanted: string] {
  let taken = (workspaces $top | get name)
  mut name = $wanted
  mut n = 2
  while ($name in $taken) {
    $name = $"($wanted)-($n)"
    $n += 1
  }
  $name
}

def exists [dir: string, revset: string] {
  jj-read $dir log --no-graph -r $revset -T 'commit_id ++ "\n"' | str trim | is-not-empty
}

# Where a new task starts: luvus/integration when it holds trunk, so a task
# sees the tasks merged before it; otherwise trunk; and in a repository with
# no trunk, the main checkout's commit, as luvus's own provider does.
def task-base [top: string] {
  let trunk = not (exists $top 'trunk() & root()')
  if (exists $top 'present("luvus/integration")') and ((not $trunk) or (exists $top 'trunk() & ::present("luvus/integration")')) {
    return (symbol 'luvus/integration')
  }
  if $trunk { return 'trunk()' }
  git -C $top rev-parse HEAD | str trim
}

# Attach Git's HEAD in the workspace at `path` to `branch` when both name the
# same commit; jj detaches it again when the working copy moves.
def attach-head [path: string, branch: string] {
  let head = (git -C $path rev-parse HEAD | str trim)
  let tip = (try { git -C $path rev-parse --verify $"refs/heads/($branch)^{commit}" | str trim } catch { return false })
  if $head != $tip { return false }
  git -C $path symbolic-ref HEAD $"refs/heads/($branch)" | ignore
  true
}

def create-git [top: string, branch: string, branch_exists: bool] {
  let path = (free-path $top $branch)
  mkdir ($path | path dirname)
  if $branch_exists {
    git -C $top worktree add $path $branch | ignore
  } else {
    git -C $top worktree add -b $branch $path | ignore
  }
  { path: $path }
}

def create [request: record] {
  let branch = $request.branch
  let top = (git -C $request.repository rev-parse --show-toplevel | str trim)
  if not (colocated $top) { return (create-git $top $branch $request.branch_exists) }
  # Reads below skip the working copy, and with it jj's import of Git's
  # refs, so take in what luvus did with Git first (luvus/integration).
  do { cd $top; jj git import } | ignore
  prune-in $top | ignore
  let path = (free-path $top $branch)
  let name = (free-name $top (slug $branch))
  let base = if $request.branch_exists { symbol $branch } else { task-base $top }
  mkdir ($path | path dirname)
  do { cd $top; jj workspace add --colocate --name $name --revision $base $path } | ignore
  try {
    if not $request.branch_exists {
      do { cd $path; jj bookmark create $branch --revision '@-' } | ignore
    }
    if not (attach-head $path $branch) {
      error make --unspanned { msg: $"the workspace's parent is not ($branch)" }
    }
    do { cd $path; jj config set --workspace $BRANCH_KEY $branch } | ignore
  } catch {|e|
    try { jj-read $top workspace forget $name | ignore }
    rm -rf $path
    if not $request.branch_exists { try { jj-read $top bookmark forget $branch | ignore } }
    error make --unspanned { msg: $"luvus-jj: could not make ($path) a jj workspace: ($e.msg)" }
  }
  { path: $path }
}

# Refuse to remove a directory other than the one the user confirmed.
def check-identity [path: string, expected: record] {
  let r = (^(tool $STAT_BIN 'stat') -L -c '%d %i' $path | complete)
  let actual = if $r.exit_code == 0 { $r.stdout | str trim | split row ' ' | each { into int } } else { [] }
  if $actual != [$expected.volume $expected.file] {
    error make --unspanned { msg: "worktree changed since deletion was confirmed" }
  }
}

# Remove a task worktree. A jj workspace is snapshotted first, so its edits
# stay in its working-copy change, which outlives the workspace.
def remove [request: record] {
  let path = $request.path
  if ($request.expected_identity? != null) { check-identity $path $request.expected_identity }
  let name = (workspace-at $path)
  if $name == null {
    git -C $request.repository worktree remove ...(if $request.force { [--force] } else { [] }) $path | ignore
    return
  }
  # A workspace another one rewrote is stale and must catch up to snapshot;
  # a forced removal goes ahead without the snapshot.
  let snapshot = {||
    try { do { cd $path; jj status } | ignore } catch {
      do { cd $path; jj workspace update-stale } | ignore
      do { cd $path; jj status } | ignore
    }
  }
  try { do $snapshot } catch {|e| if not $request.force { error make --unspanned { msg: $"luvus-jj: ($e.msg)" } } }
  let kept = (jj-read $path log --no-graph -r '@ ~ empty()' -T 'change_id.short()' | str trim)
  jj-read $path workspace forget $name | ignore
  rm -rf $path
  if ($kept | is-not-empty) {
    print --stderr $"luvus-jj: kept ($name)'s unfinished change ($kept)"
  }
}

# Answer one worktree request from luvus. Creation prints only the path's
# JSON; removal prints nothing.
def "main provider" [] {
  let request = ($in | from json)
  if ($request.version? | default 0) != 1 {
    error make --unspanned { msg: $"luvus-jj: unsupported request version ($request.version?)" }
  }
  match $request.operation {
    'create' => { create $request | to json --raw | print }
    'remove' => { remove $request }
    $other => { error make --unspanned { msg: $"luvus-jj: unknown operation ($other)" } }
  }
}

# Point this task workspace's branch at its latest change, which luvus's gate
# and merge read. A described working-copy change is finished first; an
# undescribed or conflicted change stops it. Outside a task workspace, it
# does nothing, so a gate may run it anywhere.
def "main sync" [] {
  let root = (try { jj --ignore-working-copy workspace root | str trim } catch { null })
  let branch = if $root == null { null } else {
    try { jj --ignore-working-copy config get $BRANCH_KEY | str trim } catch { null }
  }
  if $branch == null {
    print --stderr "luvus-jj sync: not a luvus task workspace; nothing to sync"
    return
  }
  # Record edits made since jj last ran.
  jj status | ignore
  let wc = (jj --ignore-working-copy log --no-graph -r '@' -T 'if(empty, "empty", if(description, "described", "undescribed"))')
  if $wc == 'undescribed' {
    error make --unspanned { msg: "luvus-jj sync: the working copy has undescribed changes; finish them with `jj commit -m MESSAGE`" }
  }
  if $wc == 'described' { jj new | ignore }
  let work = $"::@- ~ ::\(($TASK_BASES)\)"
  let ids = {|revset| jj --ignore-working-copy log --no-graph -r $revset -T 'change_id.short() ++ "\n"' | lines }
  let undescribed = (do $ids $"\(($work)\) & description\(exact:\"\"\)")
  if ($undescribed | is-not-empty) {
    error make --unspanned { msg: $"luvus-jj sync: describe these changes first \(`jj describe -r ID -m MESSAGE`\): ($undescribed | str join ', ')" }
  }
  let conflicted = (do $ids $"\(($work)\) & conflicts\(\)")
  if ($conflicted | is-not-empty) {
    error make --unspanned { msg: $"luvus-jj sync: resolve the conflicts in ($conflicted | str join ', ') first" }
  }
  jj --ignore-working-copy bookmark set $branch --revision '@-' --allow-backwards | ignore
  let commit = (jj --ignore-working-copy log --no-graph -r '@-' -T 'commit_id.short()')
  let changes = (do $ids $work | length)
  let head = if (attach-head $root $branch) { 'HEAD attached' } else { 'HEAD detached' }
  print $"($branch) at ($commit): ($changes) changes, ($head)"
}

# Forget the task workspaces of the repository at REPO, or here, whose
# directories are gone, and print their names.
def "main prune" [repo?: string] {
  prune-in ($repo | default (pwd)) | each {|name| print $name } | ignore
}

# Link the provider module at DIR into the running server, relinking when a
# new generation moved it, and enable it.
def "main register" [dir: string, --wait: duration = 1min] {
  let luvus = (tool $LUVUS_BIN 'luvus')
  let rpc = {|args: list<string>|
    let r = (^$luvus ...$args | complete)
    let reply = (try { $r.stdout | from json } catch { null })
    if $reply == null or ($reply.error? != null) {
      error make --unspanned { msg: $"luvus ($args | str join ' ') failed: ($reply.error?.message? | default ($r.stderr | str trim))" }
    }
    $reply.result
  }
  let deadline = ((date now) + $wait)
  while ((^$luvus --session default ping | complete).exit_code != 0) {
    if (date now) > $deadline { error make --unspanned { msg: $"the Luvus server did not answer within ($wait)" } }
    sleep 500ms
  }
  let want = ($dir | path expand)
  let have = (do $rpc [module list] | get -o modules | default [] | where id == $MODULE_ID)
  if ($have | is-empty) or not (same-path ($have | first | get -o root | default '') $want) {
    if ($have | is-not-empty) { do $rpc [module unlink $MODULE_ID] | ignore }
    do $rpc [module link $want] | ignore
  }
  let linked = (do $rpc [module list] | get -o modules | default [] | where id == $MODULE_ID)
  if ($linked | is-empty) { error make --unspanned { msg: $"($MODULE_ID) is not linked" } }
  if not ($linked | first | get -o enabled | default true) { do $rpc [module enable $MODULE_ID] | ignore }
  print $"($MODULE_ID) linked at ($want)"
}

def main [] {
  print "luvus-jj: provider | sync | prune [REPO] | register DIR"
}
