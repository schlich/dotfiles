let is_config_workspace = (
  niri msg --json workspaces
  | from json
  | any {|workspace| $workspace.is_focused and $workspace.name == "config" }
)
let is_snorkel_workspace = (
  niri msg --json workspaces
  | from json
  | any {|workspace| $workspace.is_focused and $workspace.name == "snorkel" }
)

let directory = if $is_config_workspace {
  $"($env.HOME)/dotfiles"
} else if $is_snorkel_workspace {
  $"($env.HOME)/starfish-projects"
} else if ($"($env.HOME)/code" | path exists) {
  $"($env.HOME)/code"
} else {
  $"($env.HOME)/dotfiles"
}

terminal --directory $directory
