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
# the same column, `tabbed` on a column's first window shows that column as
# tabs, and `width` sizes its column. A main column plus one tabbed tool column
# keeps the whole session on screen; Mod+J/K cycle the tabs.
const layouts = {
  default: [
    { role: main, width: "60%" }
    { role: jjui, width: "40%", tabbed: true, command: [jjui] }
    { role: gh-dash, stack: true, command: [gh dash] }
  ]
  area: [
    { role: shell }
  ]
  kb: [
    { role: editor, width: "60%", command: [hx index.md] }
    { role: files, width: "40%", tabbed: true, command: [yazi] }
    { role: shell, stack: true }
  ]
  dotfiles: [
    { role: files, width: "60%", command: [yazi] }
    { role: shell, width: "40%", tabbed: true }
    { role: status, stack: true, command: [nu -c $status_loop] }
    { role: jjui, stack: true, command: [jjui] }
    { role: gh-dash, stack: true, command: [gh dash] }
  ]
}

# Choices are alternatives for the same job, so they share one tabbed column
# on a workspace, while windows used together stay side by side. Windows of
# one app are choices; these groups also join different apps. `watch-choices`
# keeps each group tabbed automatically, and `stack-choices` (Mod+Alt+W)
# gathers the focused window's choices on demand.
const choice_groups = {
  agents: '^(ai\.opencode\.desktop|codex-desktop)$'
  # JJ and GitHub views of the workspace's repository; see `main vcs`.
  vcs: '^(jj-dashboard|niri\..+\.(jjui|gh-dash))$'
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

# The knowledge base: an IWE workspace whose `<range>-<session>.md` notes are
# the hubs of the Johnny Decimal areas below, and whose index is 00-09 System.
def kb-root [] {
  $env.KB_ROOT? | default $"($env.HOME)/kb"
}

# Sessions with a fixed name and layout: the Johnny Decimal areas, which
# niri/config.kdl pins to workspaces 1-9. 00-09 System is the overview, not a
# session. Research maintains the knowledge base; other areas without a single
# repository open a plain shell in the home directory.
def presets [] {
  let area = { layout: area, directory: $env.HOME }
  {
    snorkel: { layout: default, directory: $"($env.HOME)/starfish-projects" }
    research: { layout: kb, directory: (kb-root) }
    xr: $area
    nix: { layout: dotfiles, directory: $"($env.HOME)/dotfiles" }
    ai: $area
    shell: $area
    career: $area
    personal: $area
    inbox: $area
  }
}

# Presets whose layouts `startup` builds at login, focusing the first.
const startup_sessions = [snorkel nix]

# A preset, else a session opened with `project`.
def session-route [session: string] {
  let route = (presets | get --optional $session | default (project-sessions | get --optional $session))
  if $route == null {
    error make { msg: $"no session configured for Niri workspace '($session)'" }
  }
  $route
}

# Give a session a workspace: name the empty workspace Niri keeps at the end
# of the focused output, so sessions number in the order they were opened.
def ensure-workspace [session: string] {
  if (niri-json workspaces | where name == $session | is-not-empty) {
    return
  }
  let focused = (focused-workspace)
  let empty = (
    niri-json workspaces
    | where {|workspace|
        (
          $workspace.output == $focused.output
          and $workspace.name == null
          and $workspace.active_window_id == null
        )
      }
    | sort-by idx --reverse
    | get 0?
  )
  if $empty == null {
    error make { msg: $"no empty workspace on ($focused.output) to name" }
  }
  niri-action set-workspace-name --workspace $empty.idx $session
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

# Move between occupied workspaces on the focused output, skipping empty named
# workspaces and Niri's trailing empty workspace.
def "main workspace" [direction: string] {
  let focused = (focused-workspace)
  let workspaces = (niri-json workspaces | where output == $focused.output)
  let candidates = match $direction {
    "down" => {
      $workspaces
      | where {|workspace| $workspace.idx > $focused.idx and $workspace.active_window_id != null }
      | sort-by idx
    }
    "up" => {
      $workspaces
      | where {|workspace| $workspace.idx < $focused.idx and $workspace.active_window_id != null }
      | sort-by idx --reverse
    }
    _ => { error make { msg: $"unknown workspace direction '($direction)'" } }
  }
  let destination = ($candidates | get 0?)
  if $destination != null {
    niri-action focus-workspace $destination.idx
  }
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
  ensure-workspace $session
  let workspace = (niri-json workspaces | where name == $session | get 0)
  niri-action focus-workspace $session

  let prefix = $"niri.ws-($session)."
  let open = (niri-json windows | where {|window| $window.app_id? | default "" | str starts-with $prefix })
  if ($open | is-not-empty) {
    return
  }

  mut first: any = null
  mut tabbed: list<int> = []
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
    if ($window.tabbed? | default false) {
      $tabbed = ($tabbed | append $opened.id)
    }
    if $first == null {
      $first = $opened.id
    }
  }
  # Display mode applies to the focused column, so tab each one once it is full.
  for id in $tabbed {
    niri-action focus-window --id $id
    niri-action set-column-display tabbed
  }
  niri-action focus-window --id $first
}

# Focus a session's workspace, opening it and rebuilding its layout if it has
# no windows. Without a name, rebuild the focused session.
def "main restore" [session?: string] {
  let session = ($session | default (focused-workspace | get name))
  if $session == null {
    error make { msg: "the focused workspace is not a session" }
  }
  restore $session
}

# Build the startup sessions' layouts in order, then focus the first.
def "main startup" [] {
  for session in $startup_sessions {
    restore $session
  }
  niri-action focus-workspace ($startup_sessions | first)
}

# Step to the neighbouring session on the numpad grid (Mod+Alt+H/J/K/L):
# 7 8 9 on top, 1 2 3 at the bottom, so up is +3 and right is +1. At an edge,
# or outside the grid, stay put.
def "main grid" [direction: string] {
  let index = (focused-workspace | get idx)
  if $index < 1 or $index > 9 {
    return
  }
  let row = (($index - 1) // 3)
  let column = (($index - 1) mod 3)
  let target = match $direction {
    "left" => { if $column > 0 { $index - 1 } }
    "right" => { if $column < 2 { $index + 1 } }
    "up" => { if $row < 2 { $index + 3 } }
    "down" => { if $row > 0 { $index - 3 } }
    _ => { error make { msg: $"unknown direction '($direction)'; use left, right, up or down" } }
  }
  if $target != null {
    niri-action focus-workspace $target
  }
}

# Toggle the session launcher (Mod+0): a floating shell over the focused
# workspace that lists sessions by number and projects, where `project DIR`
# opens one. It closes when dismissed and is rebuilt fresh each time.
def "main overview" [] {
  let workspace = (focused-workspace)
  let open = (niri-json windows | where app_id == "niri.overview" | get 0?)
  if $open != null {
    niri-action close-window --id $open.id
    if $open.workspace_id == $workspace.id {
      return
    }
  }
  let opened = (open-window niri.overview $env.HOME [nu -e "source ~/.config/niri/workspace-overview.nu"])
  niri-action center-window --id $opened.id
}

# Working directory of a session, or the project directory outside one.
def session-directory [session: any] {
  if $session == null {
    project-directory
  } else {
    try { (session-route $session).directory } catch { project-directory }
  }
}

# Open a shell window in the focused session's directory, or with `--stack`,
# as the last window of the focused column.
def "main open" [--stack] {
  let session = (focused-workspace | get name)
  let app_id = if $session == null { "niri.terminal" } else { $"niri.ws-($session).shell" }
  let directory = (session-directory $session)
  if not $stack {
    niri-action spawn -- terminal --class $app_id --directory $directory
    return
  }
  # A new window opens as the column right of the focused one; consume it back.
  let column = (niri-json focused-window)
  let opened = (open-window $app_id $directory [])
  if $column != null and $opened.workspace_id == $column.workspace_id {
    niri-action consume-or-expel-window-left --id $opened.id
  }
}

# Open a project as its own named workspace with the default layout, or focus
# it if it is already open.
def "main project" [directory?: path] {
  let root = ($directory | default $env.PWD | path expand)
  let session = (session-name $root)

  if (project-sessions | get --optional $session) == null {
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

# Column of a tiled window, waiting briefly for Niri to lay out a new one.
def window-column [id: int] {
  for _ in 1..20 {
    let window = (niri-json windows | where id == $id | get 0?)
    if $window == null or $window.is_floating {
      return null
    }
    let position = ($window.layout.pos_in_scrolling_layout? | default [])
    if ($position | is-not-empty) {
      return ($position | get 0)
    }
    sleep 100ms
  }
  null
}

# The named choice group of an app, or null.
def named-group [app_id: any] {
  let app_id = ($app_id | default "")
  let group = ($choice_groups | transpose name pattern | where {|group| $app_id =~ $group.pattern } | get 0?)
  if $group == null { null } else { $group.name }
}

# The named group the watcher manages for an app. Windows this script opens
# (`niri.*`) are arranged by their layout, so the watcher leaves them alone.
def watched-group [app_id: any] {
  if ($app_id | default "" | str starts-with "niri.") { null } else { named-group $app_id }
}

# What a window is a choice among: its named group, else its app.
def choice-key [window: record] {
  named-group $window.app_id? | default ($window.app_id? | default "")
}

def column-of [window: record] {
  $window.layout?.pos_in_scrolling_layout? | default [] | get 0?
}

# Move a window that is alone in its column into the host window's column,
# as its last window. Windows already stacked elsewhere are left alone.
def join-column [id: int, host_id: int] {
  let windows = (niri-json windows)
  let window = ($windows | where id == $id | get 0?)
  let host = ($windows | where id == $host_id | get 0?)
  if $window == null or $host == null or $window.workspace_id != $host.workspace_id {
    return
  }
  let column = (column-of $window)
  let target = (column-of $host)
  if $column == null or $target == null or $column == $target {
    return
  }
  let neighbours = ($windows | where {|other| $other.workspace_id == $window.workspace_id and (column-of $other) == $column })
  if ($neighbours | length) > 1 {
    return
  }
  # Already beside the host: consume it without moving focus, which also
  # works on a workspace in the background.
  if $column == $target + 1 {
    niri-action consume-or-expel-window-left --id $id
    return
  }
  # Place the column directly right of the host, then consume it left.
  niri-action focus-window --id $id
  niri-action move-column-to-index (if $column > $target { $target + 1 } else { $target })
  niri-action consume-or-expel-window-left --id $id
}

# Gather the tiled choices of a window on its workspace into its column and
# show that column as tabs.
def gather-choices [id: int] {
  let windows = (niri-json windows)
  let host = ($windows | where id == $id | get 0?)
  if $host == null or $host.is_floating {
    return
  }
  let key = (choice-key $host)
  let members = (
    $windows
    | where {|other|
        (
          $other.id != $id
          and $other.workspace_id == $host.workspace_id
          and not $other.is_floating
          and (choice-key $other) == $key
        )
      }
  )
  for member in $members {
    join-column $member.id $id
  }
  niri-action focus-window --id $id
  niri-action set-column-display tabbed
}

# Tab the focused window's choices together (Mod+Alt+W).
def "main stack-choices" [] {
  let focused = (niri-json focused-window)
  if $focused == null {
    error make { msg: "no window is focused" }
  }
  gather-choices $focused.id
}

# Gather every named group already open, one tabbed column per workspace.
def gather-named-groups [] {
  let focused = (niri-json focused-window)
  let hosts = (
    niri-json windows
    | where {|window| not $window.is_floating and (watched-group $window.app_id?) != null }
    | group-by --to-table {|window| $"(watched-group $window.app_id?)@($window.workspace_id)" }
    | each {|group| $group.items | sort-by id | get 0.id }
  )
  for host in $hosts {
    gather-choices $host
  }
  if $focused != null {
    niri-action focus-window --id $focused.id
  }
}

# Tab a newly opened window into the column of an earlier member of its named
# group on the same workspace.
def join-named-group [id: int] {
  if (window-column $id) == null {
    return
  }
  let windows = (niri-json windows)
  let window = ($windows | where id == $id | get 0)
  let group = (named-group $window.app_id?)
  let host = (
    $windows
    | where {|other|
        (
          $other.id != $id
          and $other.workspace_id == $window.workspace_id
          and not $other.is_floating
          and (named-group $other.app_id?) == $group
        )
      }
    | get 0?
  )
  if $host == null {
    return
  }
  join-column $id $host.id
  niri-action focus-window --id $id
  niri-action set-column-display tabbed
}

# Gather the named groups already open, then follow Niri's event stream and
# tab each new member into its group's column. A window expelled later stays
# where it is.
def "main watch-choices" [] {
  try { gather-named-groups } catch {|err| print --stderr $err.msg }
  ^niri msg --json event-stream
  | lines
  | reduce --fold [] {|line, seen|
      let event = ($line | from json)
      let kind = ($event | columns | get 0?)
      if $kind == "WindowsChanged" {
        $event.WindowsChanged.windows | get id
      } else if $kind == "WindowOpenedOrChanged" {
        let window = $event.WindowOpenedOrChanged.window
        if $window.id not-in $seen and (watched-group $window.app_id?) != null {
          try { join-named-group $window.id } catch {|err| print --stderr $err.msg }
        }
        $seen | append $window.id | uniq
      } else if $kind == "WindowClosed" {
        $seen | where $it != $event.WindowClosed.id
      } else {
        $seen
      }
    }
  | ignore
}

# When the focused window belongs to a named group, focus the next window of
# its column and report true.
def next-tab-in-group [windows: list, group: string] {
  let focused = ($windows | where is_focused | get 0?)
  if $focused == null or (named-group $focused.app_id?) != $group {
    return false
  }
  let column = (column-of $focused)
  let count = ($windows | where {|window| (column-of $window) == $column } | length)
  let row = ($focused.layout.pos_in_scrolling_layout | get 1)
  niri-action focus-window-in-column ($row mod $count + 1)
  true
}

# Bring the coding agents' stack to the focused workspace (Mod+A). The desktop
# agents are single-window apps, so the stack is not per workspace: it follows
# focus, gathered into one tabbed column here, docking any peek. When the
# stack already has focus, switch to its next tab, or while peeking, float the
# next agent instead; with no agent open, start OpenCode.
def "main agents" [] {
  let workspace = (focused-workspace)
  let all = (niri-json windows)
  let focused = ($all | where is_focused | get 0?)
  if $focused != null and $focused.is_floating and (named-group $focused.app_id?) == "agents" {
    main peek agents --next
    return
  }
  let windows = ($all | where {|window| not $window.is_floating })
  if (next-tab-in-group ($windows | where workspace_id == $workspace.id) agents) {
    return
  }
  let agents = ($all | where {|window| (named-group $window.app_id?) == "agents" } | sort-by id)
  if ($agents | is-empty) {
    niri-action spawn -- opencode-desktop
    return
  }
  let target = (workspace-ref $workspace)
  for agent in $agents {
    if $agent.workspace_id != $workspace.id {
      niri-action move-window-to-workspace --window-id $agent.id --focus false $target
    }
    if $agent.is_floating {
      niri-action move-window-to-tiling --id $agent.id
    }
  }
  gather-choices ($agents | get 0.id)
}

# A workspace's name, or its index when it has none.
def workspace-ref [workspace: record] {
  if $workspace.name == null { $workspace.idx } else { $workspace.name }
}

# Group members, oldest first.
def group-members [windows: list, group: string] {
  $windows | where {|window| (named-group $window.app_id?) == $group } | sort-by id
}

# Return a peeking window to its group's docked column: the one on the
# workspace where the rest of the group is tiled, else a new column here.
# Focus stays on the focused workspace's tiled windows.
def dock [id: int, group: string] {
  let here = (focused-workspace)
  let windows = (niri-json windows)
  let docked = (group-members $windows $group | where {|window| $window.id != $id and not $window.is_floating })
  let origin = if ($docked | is-empty) {
    $here
  } else {
    niri-json workspaces | where id == ($docked | get 0.workspace_id) | get 0
  }
  let window = ($windows | where id == $id | get 0)
  if $window.workspace_id != $origin.id {
    niri-action move-window-to-workspace --window-id $id --focus false (workspace-ref $origin)
  }
  niri-action move-window-to-tiling --id $id
  if ($docked | is-not-empty) {
    if (window-column $id) != null {
      join-column $id ($docked | get 0.id)
    }
  }
  # Joining a column elsewhere may have had to focus it; come back.
  niri-action focus-workspace (workspace-ref $here)
  niri-action focus-tiling
}

# Float one member of a group over the focused workspace, centred.
def float-over [window: record, workspace: record] {
  # Float before moving, so the window never tiles into this workspace.
  if not $window.is_floating {
    niri-action move-window-to-floating --id $window.id
  }
  if $window.workspace_id != $workspace.id {
    niri-action move-window-to-workspace --window-id $window.id --focus false (workspace-ref $workspace)
  }
  niri-action set-window-width --id $window.id "60%"
  niri-action set-window-height --id $window.id "75%"
  niri-action focus-window --id $window.id
  niri-action center-window --id $window.id
}

# Peek at a group (Mod+Shift+A for the agents): float its most recently used
# member over the focused workspace without reflowing the columns. Again, when
# the peek has focus, docks it back; otherwise refocuses it. `--next` swaps
# the peek for the group's next member (Mod+A while peeking). Only one member
# floats at a time, since floating windows cannot be tabbed.
def "main peek" [group: string = "agents", --next] {
  let workspace = (focused-workspace)
  let members = (group-members (niri-json windows) $group)
  if ($members | is-empty) {
    if $group == "agents" {
      niri-action spawn -- opencode-desktop
    }
    return
  }
  let peeking = ($members | where {|window| $window.is_floating and $window.workspace_id == $workspace.id } | get 0?)
  if $peeking != null and not $next {
    if $peeking.is_focused {
      dock $peeking.id $group
    } else {
      niri-action focus-window --id $peeking.id
    }
    return
  }
  let chosen = if $peeking == null {
    let stamp = {|window| $window.focus_timestamp? | default { secs: 0, nanos: 0 } | $in.secs * 1_000_000_000 + $in.nanos }
    $members | sort-by $stamp --reverse | get 0
  } else {
    let position = ($members | enumerate | where item.id == $peeking.id | get 0.index)
    $members | get (($position + 1) mod ($members | length))
  }
  if $peeking != null {
    if $chosen.id == $peeking.id {
      return
    }
    dock $peeking.id $group
  }
  float-over (niri-json windows | where id == $chosen.id | get 0) $workspace
}

# Focus the focused workspace's VCS stack: JJ and GitHub dashboards as tabs
# of one column, opened in the session's directory when missing. When the
# stack already has focus, switch to its next tab (Mod+G).
def "main vcs" [] {
  let workspace = (focused-workspace)
  let windows = (niri-json windows | where {|window| $window.workspace_id == $workspace.id and not $window.is_floating })
  if (next-tab-in-group $windows vcs) {
    return
  }
  let existing = ($windows | where {|window| (named-group $window.app_id?) == "vcs" } | get 0?)
  if $existing != null {
    niri-action focus-window --id $existing.id
    return
  }

  let prefix = if $workspace.name == null { "niri.vcs." } else { $"niri.ws-($workspace.name)." }
  let directory = (session-directory $workspace.name)
  let jj = (open-window $"($prefix)jjui" $directory [jjui])
  let github = (open-window $"($prefix)gh-dash" $directory [gh dash])
  join-column $github.id $jj.id
  niri-action focus-window --id $jj.id
  niri-action set-column-display tabbed
  niri-action set-window-width --id $jj.id "40%"
}

# A session's area hub in the knowledge base, `<range>-<session>.md` (e.g.
# 80-89-personal.md for `personal`); other workspaces get the index.
def area-hub [session: any] {
  let root = (kb-root)
  let hubs = if $session == null { [] } else { glob $"($root)/[0-9][0-9]-[0-9][0-9]-($session).md" }
  $hubs | get 0? | default ($root | path join index.md)
}

# Focus the focused workspace's notes (Mod+N): its area's hub in Helix,
# started in the knowledge base so IWE's language server follows its links.
def "main notes" [] {
  let workspace = (focused-workspace)
  let app_id = if $workspace.name == null { "niri.notes" } else { $"niri.ws-($workspace.name).notes" }
  let existing = (niri-json windows | where {|window| $window.workspace_id == $workspace.id and $window.app_id? == $app_id } | get 0?)
  if $existing != null {
    niri-action focus-window --id $existing.id
    return
  }
  let opened = (open-window $app_id (kb-root) [hx (area-hub $workspace.name)])
  niri-action set-window-width --id $opened.id "40%"
}

# Capture a new note into today's daily note, the 90-99 Inbox of the
# knowledge base, floating over the focused workspace (Mod+Shift+N). An open
# capture moves here instead of closing, so unsaved text is never lost; quit
# Helix to dismiss it.
def "main capture" [] {
  let workspace = (focused-workspace)
  let open = (niri-json windows | where app_id == "niri.capture" | get 0?)
  if $open != null {
    if $open.workspace_id != $workspace.id {
      niri-action move-window-to-workspace --window-id $open.id --focus false (workspace-ref $workspace)
    }
    niri-action focus-window --id $open.id
    return
  }
  let opened = (open-window niri.capture (kb-root) [nu -e "kb today; exit"])
  niri-action center-window --id $opened.id
}

# Toggle the emoji keyboard of the niri binds (Mod+Slash), floating over the
# focused workspace like the overview; keymap.nu draws it and q closes it.
def "main keymap" [] {
  let workspace = (focused-workspace)
  let open = (niri-json windows | where app_id == "niri.keymap" | get 0?)
  if $open != null {
    niri-action close-window --id $open.id
    if $open.workspace_id == $workspace.id {
      return
    }
  }
  let script = ($env.XDG_CONFIG_HOME? | default $"($env.HOME)/.config" | path join niri keymap.nu)
  let opened = (open-window niri.keymap $env.HOME [nu $script])
  niri-action center-window --id $opened.id
}

def main [] {
  print "Usage: session.nu (startup | restore [SESSION] | overview | keymap | grid DIRECTION | open [--stack] | project [DIR] | forget [SESSION] | vcs | agents | peek [GROUP] [--next] | notes | capture | stack-choices | watch-choices | workspace (up | down))"
}
