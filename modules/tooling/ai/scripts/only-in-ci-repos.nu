# Run a ci hook command, such as context-status, only where the ci workflow
# applies: the repository the hook acts on opted into ci, as `ci-enabled`
# reports from the `ci.enable` key in its jj config, and the session did not
# start inside a repository that takes writes through Git (luvus) instead, or
# one of its linked worktrees. An edit hook acts on the edited file's
# repository, any other hook on the session's directory. Elsewhere the hook
# stays silent: no ci context, no workspace claim, no refusal. Where it runs,
# it gets the payload on stdin and its output and exit code pass through
# unchanged.
# Usage: nu --stdin only-in-ci-repos.nu --enabled CI_ENABLED --repos '<JSON list>' COMMAND ARGS...

# Null outside Git, and when git cannot run.
def git-common-dir [dir: string] {
  if ($dir | is-empty) or not ($dir | path exists) { return null }
  let result = (try { ^git -C $dir rev-parse --path-format=absolute --git-common-dir | complete } catch { null })
  if $result != null and $result.exit_code == 0 { $result.stdout | str trim } else { null }
}

# The nearest existing directory at or above `path`, so that a file an edit is
# about to create, in a directory it creates too, still names its repository.
def existing-dir [path: string] {
  mut dir = ($path | path expand)
  while ($dir | path type) != "dir" {
    let parent = ($dir | path dirname)
    if $parent == $dir { return null }
    $dir = $parent
  }
  $dir
}

# --wrapped passes the hook's own flags, such as `context-status handoff
# --hook`, through to it instead of rejecting them as unknown.
def --wrapped main [--enabled: string, --repos: string = "[]", ...command: string] {
  let input = ($in | default "" | into string)
  let payload = (try { $input | from json } catch { {} })
  let payload = if ($payload | describe | str starts-with "record") { $payload } else { {} }
  let cwd = ($payload.cwd? | default "")
  let common = (git-common-dir $cwd)
  if $common != null and ($repos | from json | any {|repo| (git-common-dir ($repo | path expand)) == $common }) { return }
  let file = ($payload.tool_input?.file_path? | default ($payload.tool_input?.notebook_path? | default ""))
  let target = (existing-dir (if ($file | is-not-empty) { $file | path dirname } else if ($cwd | is-not-empty) { $cwd } else { $env.PWD }))
  if $target == null { return }
  let opted_in = (try { (do { cd $target; ^$enabled } | complete).exit_code == 0 } catch { false })
  if not $opted_in { return }
  let result = ($input | ^($command | first) ...($command | skip 1) | complete)
  print --no-newline $result.stdout
  print --stderr --no-newline $result.stderr
  exit $result.exit_code
}
