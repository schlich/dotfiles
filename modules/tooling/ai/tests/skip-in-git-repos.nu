# Run the skip-in-git-repos wrapper around a stub hook that echoes its stdin,
# inside a Git-workflow repository, its linked worktree, and elsewhere.
# Usage: nu skip-in-git-repos.nu <wrapper script>
def main [script: string] {
  let dir = (mktemp --directory)
  let repo = ($dir | path join allowed)
  let linked = ($dir | path join linked)
  let other = ($dir | path join other)
  for r in [$repo $other] {
    ^git init --quiet $r
    ^git -C $r -c user.name=t -c user.email=t commit --quiet --allow-empty -m init
  }
  ^git -C $repo worktree add --quiet --detach $linked
  let stub = ($dir | path join hook)
  "#!/bin/sh\nprintf 'hook %s: ' \"$*\"\ncat\necho oops >&2\nexit 3\n" | save $stub
  chmod +x $stub
  let repos = ([$repo] | to json --raw)
  let cases = [
    [name cwd expect];
    ["skips the allowed repository" $repo null]
    ["skips its linked worktree" $linked null]
    ["runs the hook in another repository" $other "hook guard --hook: "]
    ["runs the hook outside any repository" $dir "hook guard --hook: "]
  ]
  let failures = ($cases | each {|c|
    let payload = ({ hook_event_name: PreToolUse, cwd: $c.cwd } | to json --raw)
    # --hook checks that the hook's own flags reach it, as context-status's do.
    let r = ($payload | ^nu --stdin $script --repos $repos $stub guard --hook | complete)
    let ok = if $c.expect == null {
      $r.exit_code == 0 and $r.stdout == "" and $r.stderr == ""
    } else {
      $r.exit_code == 3 and $r.stdout == $"($c.expect)($payload)" and ($r.stderr | str trim) == "oops"
    }
    print $"(if $ok { 'ok  ' } else { 'FAIL' }) skip-in-git-repos: ($c.name)"
    if not $ok { print $"     exit: ($r.exit_code) stdout: ($r.stdout | to json) stderr: ($r.stderr | to json)" }
    $ok
  } | where {|ok| not $ok } | length)
  if $failures > 0 { exit 1 }
}
