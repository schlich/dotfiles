# Run the only-in-ci-repos wrapper around a stub hook that echoes its stdin:
# in JJ repositories that opted into ci and ones that did not, in a
# Git-workflow repository and its linked worktree, and outside any repository.
# A third argument names a path from dotfiles.ci.repositories, which jj's
# generated configuration opts in without any setting of its own.
# Usage: nu only-in-ci-repos.nu <wrapper script> <ci-enabled> [<listed path>]
def main [script: string, enabled: string, listed?: string] {
  let dir = (mktemp --directory)
  let allowed = ($dir | path join allowed)
  let linked = ($dir | path join linked)
  let opted = ($dir | path join opted)
  let plain = ($dir | path join plain)
  let outside = ($dir | path join outside)
  ^git init --quiet $allowed
  ^git -C $allowed -c user.name=t -c user.email=t commit --quiet --allow-empty -m init
  ^git -C $allowed worktree add --quiet --detach $linked
  mkdir $opted $plain $outside ($opted | path join sub)
  # The Git-workflow repository opts in too, to show that its exclusion wins.
  for r in [[path flags]; [$allowed ["--colocate"]] [$opted []] [$plain []]] {
    do { cd $r.path; ^jj git init ...$r.flags | complete | ignore }
  }
  for r in [$allowed $opted] {
    do { cd $r; ^jj config set --repo ci.enable true }
  }
  let listed_dir = if ($listed | is-empty) { null } else { $listed | path expand }
  if $listed_dir != null {
    mkdir $listed_dir
    do { cd $listed_dir; ^jj git init | complete | ignore }
  }
  let stub = ($dir | path join hook)
  "#!/bin/sh\nprintf 'hook %s: ' \"$*\"\ncat\necho oops >&2\nexit 3\n" | save $stub
  chmod +x $stub
  let repos = ([$allowed] | to json --raw)
  let cases = [
    [name cwd file runs];
    ["skips the Git-workflow repository, opted in or not" $allowed null false]
    ["skips its linked worktree" $linked null false]
    ["runs the hook in a repository that opted in" $opted null true]
    ["runs it from a subdirectory there" ($opted | path join sub) null true]
    ["skips a repository that did not opt in" $plain null false]
    ["skips outside any repository" $outside null false]
    ["runs an edit hook for a new file in an opted-in repository" $plain ($opted | path join new dir file.txt) true]
    ["skips an edit hook for a file in a repository that did not opt in" $opted ($plain | path join file.txt) false]
  ] | append (if $listed_dir == null { [] } else {
    [[name cwd file runs]; ["runs the hook in a repository dotfiles.ci.repositories lists" $listed_dir null true]]
  })
  let failures = ($cases | each {|c|
    let payload = ({ hook_event_name: PreToolUse, cwd: $c.cwd }
      | merge (if $c.file == null { {} } else { { tool_input: { file_path: $c.file } } })
      | to json --raw)
    # --hook checks that the hook's own flags reach it, as context-status's do.
    let r = ($payload | ^nu --stdin $script --enabled $enabled --repos $repos $stub guard --hook | complete)
    let ok = if $c.runs {
      $r.exit_code == 3 and $r.stdout == $"hook guard --hook: ($payload)" and ($r.stderr | str trim) == "oops"
    } else {
      $r.exit_code == 0 and $r.stdout == "" and $r.stderr == ""
    }
    print $"(if $ok { 'ok  ' } else { 'FAIL' }) only-in-ci-repos: ($c.name)"
    if not $ok { print $"     exit: ($r.exit_code) stdout: ($r.stdout | to json) stderr: ($r.stderr | to json)" }
    $ok
  } | where {|ok| not $ok } | length)
  # ci-enabled itself: a status without a command, and a guarded run with one.
  let direct = [
    [name dir args code stdout];
    ["ci-enabled succeeds in an opted-in repository" $opted [] 0 ""]
    ["ci-enabled fails elsewhere" $plain [] 1 ""]
    ["ci-enabled runs a command in an opted-in repository" $opted [echo shown] 0 "shown\n"]
    ["ci-enabled skips the command elsewhere, quietly" $outside [echo shown] 0 ""]
  ]
  let direct_failures = ($direct | each {|c|
    let r = (do { cd $c.dir; ^$enabled ...$c.args } | complete)
    let ok = $r.exit_code == $c.code and $r.stdout == $c.stdout
    print $"(if $ok { 'ok  ' } else { 'FAIL' }) ($c.name)"
    if not $ok { print $"     exit: ($r.exit_code) stdout: ($r.stdout | to json) stderr: ($r.stderr | to json)" }
    $ok
  } | where {|ok| not $ok } | length)
  if $failures + $direct_failures > 0 { exit 1 }
}
