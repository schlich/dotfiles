let is_config_workspace = (
  niri msg --json workspaces
  | from json
  | any {|workspace| $workspace.is_focused and $workspace.name == "config" }
)

let directory = if $is_config_workspace {
  $"($env.HOME)/dotfiles"
} else if ($"($env.HOME)/code" | path exists) {
  $"($env.HOME)/code"
} else {
  $"($env.HOME)/dotfiles"
}

kitty --directory $directory
