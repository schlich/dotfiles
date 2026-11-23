# luvus-jj's worktree provider, sync, and prune, on throwaway repositories
# with a bare origin, checked the way luvus checks a provider's worktree:
#   nu --no-config-file tests/luvus-jj.nu tools/luvus-jj.nu

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

def --wrapped run-in [dir: string, ...cmd: string] {
  do { cd $dir; ^($cmd | first) ...($cmd | skip 1) } | complete
}

def --wrapped out [dir: string, ...cmd: string] {
  let r = (run-in $dir ...$cmd)
  if $r.exit_code != 0 { error make { msg: $"($cmd | str join ' ') in ($dir): ($r.stderr)" } }
  $r.stdout | str trim
}

def main [script: path] {
  let script = ($script | path expand)
  let nu_bin = $nu.current-exe
  let tmp = (mktemp --directory | path expand)
  # Task worktrees go under $HOME/.luvus/worktrees.
  $env.HOME = $tmp
  hide-env --ignore-errors LUVUS_HOME
  $env.GIT_AUTHOR_NAME = "check"
  $env.GIT_AUTHOR_EMAIL = "check@localhost"
  $env.GIT_COMMITTER_NAME = "check"
  $env.GIT_COMMITTER_EMAIL = "check@localhost"
  $env.JJ_USER = "check"
  $env.JJ_EMAIL = "check@localhost"
  mut failures = []

  let provide = {|request: record|
    $request | merge { version: 1 } | to json | ^$nu_bin --stdin --no-config-file $script provider | complete
  }
  let sync = {|dir: string| run-in $dir $nu_bin --no-config-file $script sync }
  let worktrees = {|repo: string|
    ^git -C $repo worktree list --porcelain | lines | where $it starts-with 'worktree ' | each { str substring 9.. }
  }
  let jj_workspaces = {|repo: string| out $repo jj workspace list -T 'name ++ "\n"' | lines }

  # A clone of an origin whose main has one commit, colocated with jj.
  let origin = ($tmp | path join origin.git)
  let repo = ($tmp | path join repo)
  ^git init --quiet --bare -b main $origin
  ^git clone --quiet $origin $repo o+e>| ignore
  "a\n" | save ($repo | path join a.txt)
  ^git -C $repo add a.txt
  ^git -C $repo commit --quiet -m base
  ^git -C $repo push --quiet origin main o+e>| ignore
  out $repo jj git init --colocate | ignore
  out $repo jj bookmark track main --remote origin | ignore
  let trunk = (out $repo git rev-parse main)

  # Creation: a jj workspace that is also a Git worktree on the task branch.
  let r = (do $provide { operation: create, repository: $repo, branch: "luvus/t1", branch_exists: false })
  $failures ++= (expect "create succeeds" $r.exit_code 0)
  let t1 = ($r.stdout | from json | get path)
  $failures ++= (expect "create prints only the path" ($r.stdout | from json | columns) [path])
  $failures ++= (expect "the path follows luvus's layout" $t1 ($tmp | path join .luvus worktrees repo luvus-t1))
  $failures ++= (expect "the worktree is registered with Git" ($t1 in (do $worktrees $repo)) true)
  $failures ++= (expect "HEAD is on the task branch" (out $t1 git rev-parse --abbrev-ref HEAD) "luvus/t1")
  $failures ++= (expect "it shares the repository's Git directory" (out $t1 git rev-parse --path-format=absolute --git-common-dir) (out $repo git rev-parse --path-format=absolute --git-common-dir))
  $failures ++= (expect "it is a jj workspace" ("luvus-t1" in (do $jj_workspaces $repo)) true)
  $failures ++= (expect "it records its branch" (out $t1 jj config get luvus.branch) "luvus/t1")
  $failures ++= (expect "a new task starts on trunk" (out $t1 git rev-parse HEAD) $trunk)

  # A task starts on luvus/integration when it holds trunk. luvus makes that
  # branch with Git, behind jj's back.
  "i\n" | save ($repo | path join i.txt)
  out $repo jj commit -m integrated | ignore
  let integration = (out $repo jj log --no-graph -r '@-' -T commit_id)
  out $repo git branch luvus/integration $integration | ignore
  let r = (do $provide { operation: create, repository: $repo, branch: "luvus/t2", branch_exists: false })
  let t2 = ($r.stdout | from json | get path)
  $failures ++= (expect "a task starts on luvus/integration" (out $t2 git rev-parse HEAD) $integration)

  # Sync: the branch follows the latest described change.
  "b\n" | save ($t1 | path join b.txt)
  let r = (do $sync $t1)
  $failures ++= (expect "sync refuses an undescribed change" [($r.exit_code != 0) ($r.stderr =~ 'undescribed')] [true true])
  out $t1 jj describe -m "add b" | ignore
  let r = (do $sync $t1)
  $failures ++= (expect "sync finishes a described change" $r.exit_code 0)
  $failures ++= (expect "the branch holds it" (out $repo git log -1 --format=%s luvus/t1) "add b")
  $failures ++= (expect "HEAD is reattached" (out $t1 git rev-parse --abbrev-ref HEAD) "luvus/t1")
  "c\n" | save ($t1 | path join c.txt)
  out $t1 jj commit -m "add c" | ignore
  $failures ++= (expect "jj detaches HEAD as it works" (out $t1 git rev-parse --abbrev-ref HEAD) "HEAD")
  let r = (do $sync $t1)
  $failures ++= (expect "sync reports the task's changes" ($r.stdout =~ '^luvus/t1 at \w+: 2 changes, HEAD attached') true)
  $failures ++= (expect "the branch moves on" (out $repo git log -1 --format=%s luvus/t1) "add c")
  $failures ++= (expect "Git merges what jj made" ((run-in $repo git merge-base --is-ancestor $trunk luvus/t1).exit_code) 0)
  let r = (do $sync $repo)
  $failures ++= (expect "sync is a no-op outside a task workspace" [$r.exit_code ($r.stderr =~ 'nothing to sync')] [0 true])

  # Removal keeps an unfinished change and leaves no workspace or worktree.
  "wip\n" | save ($t1 | path join wip.txt)
  let r = (do $provide { operation: remove, repository: $repo, path: $t1, branch: "luvus/t1", force: false, expected_identity: { volume: 0, file: 0 } })
  $failures ++= (expect "a changed directory is not removed" [($r.exit_code != 0) ($t1 | path exists)] [true true])
  let id = (^stat -L -c '%d %i' $t1 | str trim | split row ' ' | each { into int })
  let r = (do $provide { operation: remove, repository: $repo, path: $t1, branch: "luvus/t1", force: false, expected_identity: { volume: $id.0, file: $id.1 } })
  $failures ++= (expect "removal succeeds silently" [$r.exit_code $r.stdout] [0 ""])
  $failures ++= (expect "the directory is gone" ($t1 | path exists) false)
  $failures ++= (expect "Git forgot the worktree" ($t1 in (do $worktrees $repo)) false)
  $failures ++= (expect "jj forgot the workspace" ("luvus-t1" in (do $jj_workspaces $repo)) false)
  $failures ++= (expect "the unfinished change survives" (out $repo jj log --no-graph -r 'files("wip.txt")' -T 'change_id.short()' | is-not-empty) true)
  $failures ++= (expect "the branch is kept" (out $repo git log -1 --format=%s luvus/t1) "add c")

  # Recreating a task's worktree resumes its branch.
  let r = (do $provide { operation: create, repository: $repo, branch: "luvus/t1", branch_exists: true })
  let t1b = ($r.stdout | from json | get path)
  $failures ++= (expect "an existing branch is checked out again" [(out $t1b git rev-parse --abbrev-ref HEAD) (out $t1b git log -1 --format=%s)] ["luvus/t1" "add c"])

  # Prune forgets workspaces whose directories luvus removed with Git alone.
  ^git -C $repo worktree remove --force $t2
  let pruned = (out $repo $nu_bin --no-config-file $script prune | lines)
  $failures ++= (expect "prune forgets the stale workspace" $pruned ["luvus-t2"])
  $failures ++= (expect "and only it" ((do $jj_workspaces $repo) | sort) ["default" "luvus-t1"])

  # Without jj, a plain Git worktree, as luvus's own provider makes.
  let plain = ($tmp | path join plain)
  ^git init --quiet -b main $plain
  ^git -C $plain commit --quiet --allow-empty -m base
  let r = (do $provide { operation: create, repository: $plain, branch: "luvus/t9", branch_exists: false })
  let t9 = ($r.stdout | from json | get path)
  $failures ++= (expect "a Git repository gets a Git worktree" [(out $t9 git rev-parse --abbrev-ref HEAD) ($t9 | path join .jj | path exists)] ["luvus/t9" false])
  let r = (do $provide { operation: remove, repository: $plain, path: $t9, branch: "luvus/t9", force: false })
  $failures ++= (expect "and Git removes it" [$r.exit_code ($t9 | path exists)] [0 false])

  let r = ({ version: 2, operation: create } | to json | ^$nu_bin --stdin --no-config-file $script provider | complete)
  $failures ++= (expect "an unknown request version is refused" ($r.exit_code != 0) true)

  rm -rf $tmp
  if ($failures | is-not-empty) {
    error make { msg: $"($failures | length) luvus-jj checks failed: ($failures | str join ', ')" }
  }
}
