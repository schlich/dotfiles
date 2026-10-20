# Run the Git write guard with an allowed repository, from inside it, from
# its linked worktree, and from elsewhere.
# Usage: nu guard-git-writes.nu <guard script>
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
  mkdir ($repo | path join sub)
  let payload = {|cwd, command| { session_id: test, hook_event_name: PreToolUse, tool_name: Bash, tool_input: { command: $command }, cwd: $cwd } | to json }
  let cases = [
    [name cwd command repos expect];
    ["allows a commit in the allowed repository" $repo "git commit -m x" [$repo] null]
    ["allows a commit in its subdirectory" ($repo | path join sub) "git commit -m x" [$repo] null]
    ["allows a commit in its linked worktree" $linked "git switch -c topic" [$repo] null]
    ["allows Nushell's caret form there" $repo "^git push origin main | complete" [$repo] null]
    ["denies a commit in another repository" $other "git commit -m x" [$repo] deny]
    ["denies outside any repository" $dir "git commit -m x" [$repo] deny]
    ["denies with no allowed repository" $repo "git commit -m x" [] deny]
    ["ignores a missing allowed repository" $repo "git commit -m x" [($dir | path join gone)] deny]
    ["stays silent on read-only git elsewhere" $other "git log --oneline" [$repo] null]
  ]
  let failures = ($cases | each {|c|
    let r = (do $payload $c.cwd $c.command | ^nu --stdin $script --claude ...$c.repos | complete)
    let out = ($r.stdout | str trim)
    let got = if $out == "" { null } else { $out | from json | get hookSpecificOutput.permissionDecision }
    let ok = $r.exit_code == 0 and $got == $c.expect
    print $"(if $ok { 'ok  ' } else { 'FAIL' }) guard-git-writes: ($c.name)"
    if not $ok { print $"     got: ($got | to json) stdout: ($r.stdout | to json) stderr: ($r.stderr | to json)" }
    $ok
  } | where {|ok| not $ok } | length)
  if $failures > 0 { exit 1 }
}
