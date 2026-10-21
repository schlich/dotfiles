# Run a ci hook command, such as context-status, except for sessions started
# inside a repository that takes writes through Git (luvus) instead of jj and
# ci, or one of its linked worktrees. There the hook stays silent: no ci
# context, no workspace claim, no refusal. Elsewhere it gets the payload on
# stdin and its output and exit code pass through unchanged.
# Usage: nu --stdin skip-in-git-repos.nu --repos '<JSON list>' COMMAND ARGS...

# Null outside Git, and when git cannot run, so the hook then runs as usual.
def git-common-dir [dir: string] {
  if ($dir | is-empty) or not ($dir | path exists) { return null }
  let result = (try { ^git -C $dir rev-parse --path-format=absolute --git-common-dir | complete } catch { null })
  if $result != null and $result.exit_code == 0 { $result.stdout | str trim } else { null }
}

# --wrapped passes the hook's own flags, such as `context-status handoff
# --hook`, through to it instead of rejecting them as unknown.
def --wrapped main [--repos: string = "[]", ...command: string] {
  let input = ($in | default "" | into string)
  let cwd = (try { $input | from json | get -o cwd | default "" } catch { "" })
  let common = (git-common-dir $cwd)
  let skip = $common != null and ($repos | from json | any {|repo| (git-common-dir ($repo | path expand)) == $common })
  if $skip { return }
  let result = ($input | ^($command | first) ...($command | skip 1) | complete)
  print --no-newline $result.stdout
  print --stderr --no-newline $result.stderr
  exit $result.exit_code
}
