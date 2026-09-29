# Mark each recorded Claude Code background task running or finished, and
# copy the list to the host whose Fieldnotes wallpaper draws it.

# Finished tasks stay on the wallpaper this long.
const KEEP_FINISHED = 15min

def now-iso [] {
  date now | format date "%Y-%m-%dT%H:%M:%S%:z"
}

# IDs of tasks whose `tasks/<id>.output` file some process still holds open.
# A background task's shell keeps that file as stdout until the command
# exits, so a task nobody holds it for has finished.
def running-ids [] {
  ls /proc
  | where name =~ '^/proc/\d+$'
  | each {|proc| try { ls -l $"($proc.name)/fd" | get target } catch { [] } }
  | flatten
  | compact
  | where $it =~ '/tasks/[^/]+\.output$'
  | each {|path| $path | path parse | get stem }
  | uniq
}

def main [--target: string = "homelab"] {
  let dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join fieldnotes agent-tasks)
  mkdir $dir
  let running = (running-ids)
  let tasks = (
    glob ($dir | path join "*.json")
    | each {|file|
      mut task = (open $file)
      if $task.finished == null and ($task.id not-in $running) {
        $task.finished = (now-iso)
        $task | to json | save -f $file
      }
      if $task.finished != null and ((date now) - ($task.finished | into datetime)) > $KEEP_FINISHED {
        rm $file
        null
      } else {
        $task
      }
    }
    | compact
  )

  let host = (sys host | get hostname)
  let remote = "~/.local/state/fieldnotes/agent-tasks"
  let report = {
    host: $host
    updated: (now-iso)
    tasks: ($tasks | select id description cwd started finished)
  }
  # Write a temporary file and rename it so the wallpaper never reads a
  # partial report. The remote login shell is Nushell, so run Bash explicitly.
  let result = (
    $report | to json
    | ^ssh -o BatchMode=yes -o ForwardAgent=no -o ConnectTimeout=5 $target $"bash -c 'mkdir -p ($remote) && cat > ($remote)/($host).json.tmp && mv ($remote)/($host).json.tmp ($remote)/($host).json'"
    | complete
  )
  if $result.exit_code != 0 {
    print --stderr $"push to ($target) failed: ($result.stderr | str trim)"
    exit 1
  }
}
