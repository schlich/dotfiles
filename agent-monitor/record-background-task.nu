# Claude Code PostToolUse hook: record each background Bash task so the
# Fieldnotes wallpaper can show it. `push-background-tasks` later decides
# whether it is still running and copies the list to the wallpaper host.
def main [] {
  let input = $in
  try {
    let payload = ($input | into string | from json)
    let tool_input = ($payload.tool_input? | default {})
    if ($payload.tool_name? != "Bash") or not ($tool_input.run_in_background? | default false) {
      return
    }
    # The structured response carries only the task ID; the task writes to
    # `.../tasks/<id>.output`, which `push-background-tasks` looks for.
    let id = ($payload.tool_response?.backgroundTaskId? | default null)
    if $id == null { return }
    let dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join fieldnotes agent-tasks)
    mkdir $dir
    {
      id: $id
      description: ($tool_input.description? | default ($tool_input.command? | default $id | str substring 0..80))
      cwd: ($payload.cwd? | default "")
      started: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
      finished: null
    } | to json | save -f ($dir | path join $"($id).json")
    ^systemctl --user start --no-block agent-tasks-push.service | complete | ignore
  }
}
