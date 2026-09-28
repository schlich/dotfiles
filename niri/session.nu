# Niri workspaces as terminal sessions.
#
# A session is a named Niri workspace with a working directory and a layout:
# Ghostty windows arranged as Niri columns. Restoring a session focuses its
# workspace and, when none of its windows are open, rebuilds the layout.
# Ghostty tabs and splits cover ad-hoc subdivision inside a window.
#
# Window app IDs are `niri.ws-<session>.<role>`; GTK ignores a Ghostty class
# without a dot, so every ID keeps that shape.

const status_loop = "loop { clear; let st = (^jj --color always status | complete); if $st.exit_code == 0 { print $st.stdout; print (^jj --color always diff --stat | complete).stdout } else { print 'Not in a JJ repository.' }; sleep 5sec }"

# Columns from left to right. `stack` puts a window below the previous one in
# the same column, and `width` sizes its column.
const layouts = {
  default: [
    { role: main, width: "60%" }
    { role: jjui, command: [jjui] }
    { role: gh-dash, command: [gh dash] }
  ]
  overview: [
    { role: overview, width: "50%", command: [nu -e "source ~/.config/niri/workspace-overview.nu"] }
    { role: control }
  ]
  dotfiles: [
    { role: editor, width: "60%", command: [hx .] }
    { role: shell, stack: true }
    { role: jjui, command: [jjui] }
    { role: status, command: [nu -c $status_loop] }
    { role: gh-dash, command: [gh dash] }
  ]
}

def niri-json [query: string] {
  let response = (^niri msg --json $query | complete)
  if $response.exit_code != 0 {
    error make { msg: ($response.stderr | str trim) }
  }
  $response.stdout | from json
}

def --wrapped niri-action [...args] {
  let response = (^niri msg action ...$args | complete)
  if $response.exit_code != 0 {
    error make { msg: ($response.stderr | str trim) }
  }
}

def state-file [] {
  let state_home = ($env.XDG_STATE_HOME? | default $"($env.HOME)/.local/state")
  $"($state_home)/niri/sessions.nuon"
}

def project-sessions [] {
  let file = (state-file)
  if ($file | path exists) { open $file } else { {} }
}

def project-directory [] {
  let code = $"($env.HOME)/code"
  if ($code | path exists) {
    $code
  } else {
    $"($env.HOME)/dotfiles"
  }
}

# The workspaces pinned in niri/config.kdl, then sessions opened with `project`.
def session-route [session: string] {
  match $session {
    "snorkel" => { { layout: default, directory: $"($env.HOME)/starfish-projects" } }
    "vcs" => { { layout: default, directory: (project-directory) } }
    "overview" => { { layout: overview, directory: $env.HOME } }
    "config" => { { layout: dotfiles, directory: $"($env.HOME)/dotfiles" } }
    "scratch" => { { layout: default, directory: (project-directory) } }
    _ => {
      let route = (project-sessions | get --optional $session)
      if $route == null {
        error make { msg: $"no session configured for Niri workspace '($session)'" }
      }
      $route
    }
  }
}

# Stable, readable session name: project basename plus a short path hash so
# two checkouts with the same basename never share a workspace.
def session-name [directory: path] {
  let base = ($directory | path basename | str lowercase | str replace --all --regex '[^a-z0-9_-]+' '-')
  let digest = ($directory | hash sha256 | str substring 0..5)
  $"($base)-($digest)"
}

def focused-workspace [] {
  let focused = (niri-json workspaces | where is_focused | get 0?)
  if $focused == null {
    error make { msg: "Niri did not report a focused workspace" }
  }
  $focused
}

# Spawn a Ghostty window and wait until Niri maps it, so the next column
# opens to its right.
def open-window [app_id: string, directory: path, command: list] {
  let before = (niri-json windows | where app_id == $app_id | get id)
  niri-action spawn -- terminal --class $app_id --directory $directory ...$command
  for _ in 1..100 {
    let opened = (niri-json windows | where app_id == $app_id and id not-in $before | get 0?)
    if $opened != null {
      return $opened
    }
    sleep 100ms
  }
  error make { msg: $"($app_id) did not open a window" }
}

def restore [session: string] {
  let route = (session-route $session)
  let workspace = (niri-json workspaces | where name == $session | get 0?)
  if $workspace == null {
    error make { msg: $"Niri has no workspace named '($session)'" }
  }
  niri-action focus-workspace $session

  let prefix = $"niri.ws-($session)."
  let open = (niri-json windows | where {|window| $window.app_id? | default "" | str starts-with $prefix })
  if ($open | is-not-empty) {
    return
  }

  mut first: any = null
  for window in ($layouts | get $route.layout) {
    let opened = (open-window $"($prefix)($window.role)" $route.directory ($window.command? | default []))
    # Keep the layout together if focus moved while it was being built.
    if $opened.workspace_id != $workspace.id {
      niri-action move-window-to-workspace --window-id $opened.id --focus false $session
    }
    if ($window.stack? | default false) {
      niri-action consume-or-expel-window-left --id $opened.id
    }
    if $window.width? != null {
      niri-action set-window-width --id $opened.id $window.width
    }
    if $first == null {
      $first = $opened.id
    }
  }
  niri-action focus-window --id $first
}

# Focus a session's workspace, rebuilding its layout if it has no windows.
def "main restore" [session?: string] {
  restore (if $session == null { focused-workspace | get name | default "scratch" } else { $session })
}

# Open a shell window in the focused session's directory.
def "main open" [] {
  let session = (focused-workspace | get name)
  if $session == null {
    niri-action spawn -- terminal --class niri.terminal --directory (project-directory)
  } else {
    let directory = try { (session-route $session).directory } catch { project-directory }
    niri-action spawn -- terminal --class $"niri.ws-($session).shell" --directory $directory
  }
}

# Open a project as its own named workspace with the default layout, or focus
# it if it is already open.
def "main project" [directory?: path] {
  let root = ($directory | default $env.PWD | path expand)
  let session = (session-name $root)

  if (niri-json workspaces | where name == $session | is-empty) {
    let focused = (focused-workspace)
    # Niri keeps an empty workspace at the end of every output.
    let empty = (
      niri-json workspaces
      | where {|workspace|
          $workspace.output == $focused.output
          and $workspace.name == null
          and $workspace.active_window_id == null
        }
      | sort-by idx --reverse
      | get 0?
    )
    if $empty == null {
      error make { msg: $"no empty workspace on ($focused.output) to name" }
    }
    niri-action set-workspace-name --workspace $empty.idx $session

    let file = (state-file)
    $file | path dirname | mkdir $in
    project-sessions | upsert $session { layout: default, directory: $root } | save --force $file
  }

  restore $session
}

# Drop a project session: its workspace loses its name and Niri removes it
# once it is empty. Open windows are left alone.
def "main forget" [session?: string] {
  let session = if $session == null { focused-workspace | get name } else { $session }
  if $session == null {
    error make { msg: "the focused workspace is not a session" }
  }
  let file = (state-file)
  if not (project-sessions | columns | any {|name| $name == $session }) {
    error make { msg: $"'($session)' is not a project session" }
  }
  project-sessions | reject $session | save --force $file
  niri-action unset-workspace-name $session
}

def main [] {
  print "Usage: session.nu (restore [SESSION] | open | project [DIR] | forget [SESSION])"
}
