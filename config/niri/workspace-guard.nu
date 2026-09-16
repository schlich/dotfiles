const creation_grace = 10sec

def state-file [] {
  let state_home = ($env.XDG_STATE_HOME? | default $"($env.HOME)/.local/state")
  $"($state_home)/niri/workspace-creation-grace"
}

def workspaces [] {
  let response = (^niri msg --json workspaces | complete)

  if $response.exit_code != 0 {
    error make { msg: ($response.stderr | str trim) }
  }

  $response.stdout | from json
}

def usable-workspaces [all: table, output: string] {
  $all
  | where {|workspace|
      $workspace.output == $output
      and ($workspace.name != null or $workspace.active_window_id != null)
    }
  | sort-by idx
}

def target-in-direction [all: table, direction: string] {
  let focused = ($all | where is_focused | get 0?)
  if $focused == null {
    return null
  }

  let usable = (usable-workspaces $all $focused.output)
  if $direction == "down" {
    $usable | where idx > $focused.idx | get 0?
  } else {
    $usable | where idx < $focused.idx | reverse | get 0?
  }
}

def focus-direction [direction: string] {
  let all = (workspaces)
  let target = (target-in-direction $all $direction)
  if $target != null {
    ^niri msg action focus-workspace $target.idx
  }
}

def move-direction [direction: string] {
  let all = (workspaces)
  let target = (target-in-direction $all $direction)
  if $target != null {
    ^niri msg action move-column-to-workspace $target.idx
  }
}

def target-by-index [index: int] {
  let all = (workspaces)
  let focused = ($all | where is_focused | get 0?)
  if $focused == null {
    return null
  }

  usable-workspaces $all $focused.output
  | where idx == $index
  | get 0?
}

def focus-index [index: int] {
  let target = (target-by-index $index)
  if $target != null {
    ^niri msg action focus-workspace $target.idx
  }
}

def move-index [index: int] {
  let target = (target-by-index $index)
  if $target != null {
    ^niri msg action move-column-to-workspace $target.idx
  }
}

def create-workspace [] {
  let all = (workspaces)
  let focused = ($all | where is_focused | get 0?)
  if $focused == null {
    return
  }

  let empty = (
    $all
    | where {|workspace|
        $workspace.output == $focused.output
        and $workspace.name == null
        and $workspace.active_window_id == null
      }
    | sort-by idx --reverse
    | get 0?
  )

  if $empty != null {
    let marker = (state-file)
    $marker | path dirname | mkdir
    "" | save --force $marker
    ^niri msg action focus-workspace $empty.idx
  }
}

def creation-grace-active [] {
  let marker = (state-file)
  if not ($marker | path exists) {
    return false
  }

  let modified = (ls $marker | get 0.modified)
  if ((date now) - $modified) < $creation_grace {
    true
  } else {
    rm $marker
    false
  }
}

def cleanup-empty-workspace [] {
  if (creation-grace-active) {
    return
  }

  let all = (workspaces)
  let focused = ($all | where is_focused | get 0?)
  if (
    $focused == null
    or $focused.name != null
    or $focused.active_window_id != null
  ) {
    return
  }

  let fallback = (
    usable-workspaces $all $focused.output
    | sort-by idx --reverse
    | get 0?
  )
  if $fallback != null {
    ^niri msg action focus-workspace $fallback.idx
  }
}

def watch [] {
  loop {
    try {
      cleanup-empty-workspace
    }
    sleep 500ms
  }
}

def main [
  action: string
  value?: string
] {
  match $action {
    "focus" => { focus-direction $value }
    "move" => { move-direction $value }
    "focus-index" => { focus-index ($value | into int) }
    "move-index" => { move-index ($value | into int) }
    "create" => { create-workspace }
    "cleanup" => { cleanup-empty-workspace }
    "watch" => { watch }
    _ => { error make { msg: $"unknown workspace action: ($action)" } }
  }
}
