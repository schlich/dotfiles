def project-directory [] {
  let code = $"($env.HOME)/code"
  if ($code | path exists) {
    $code
  } else {
    $"($env.HOME)/dotfiles"
  }
}

def workspace-route [workspace: string] {
  match $workspace {
    "snorkel" => {
      {
        session: "main"
        layout: "default"
        directory: $"($env.HOME)/starfish-projects"
      }
    }
    "vcs" => {
      {
        session: "vcs"
        layout: "default"
        directory: (project-directory)
      }
    }
    "overview" => {
      {
        session: "overview"
        layout: "overview"
        directory: $env.HOME
      }
    }
    "config" => {
      {
        session: "dotfiles"
        layout: "dotfiles"
        directory: $"($env.HOME)/dotfiles"
      }
    }
    "scratch" => {
      {
        session: "scratch"
        layout: "default"
        directory: (project-directory)
      }
    }
    _ => { error make { msg: $"no terminal route configured for Niri workspace '($workspace)'" } }
  }
}

def focused-workspace [] {
  let response = (^niri msg --json workspaces | complete)
  if $response.exit_code != 0 {
    error make { msg: ($response.stderr | str trim) }
  }

  let focused = ($response.stdout | from json | where is_focused | get 0?)
  if $focused == null {
    error make { msg: "Niri did not report a focused workspace" }
  }

  # Route unnamed workspaces to the explicitly reserved scratch session.
  $focused.name | default "scratch"
}

def focus-existing-terminal [app_id: string] {
  let response = (^niri msg --json windows | complete)
  if $response.exit_code != 0 {
    error make { msg: ($response.stderr | str trim) }
  }

  let window = ($response.stdout | from json | where app_id == $app_id | get 0?)
  if $window == null {
    false
  } else {
    let focused = (^niri msg action focus-window --id $window.id | complete)
    if $focused.exit_code != 0 {
      error make { msg: ($focused.stderr | str trim) }
    }
    true
  }
}

def main [workspace?: string] {
  let selected_workspace = if $workspace == null {
    focused-workspace
  } else {
    $workspace
  }
  let route = (workspace-route $selected_workspace)
  let app_id = $"niri-terminal-($selected_workspace)"

  if not (focus-existing-terminal $app_id) {
    ^terminal
      --class $app_id
      --directory $route.directory
      zellij attach --create $route.session options
        --default-layout $route.layout
        --default-cwd $route.directory
  }
}
