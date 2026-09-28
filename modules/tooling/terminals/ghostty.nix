{
  config,
  lib,
  ...
}:

{
  programs.ghostty = lib.mkIf (config.dotfiles.primary.terminal == "ghostty") {
    enable = true;
    installBatSyntax = true;
    settings = {
      copy-on-select = true;
      font-family = "Monaspace Krypton";
      # Splits and tabs replace Zellij panes and tabs, on the Alt keys Zellij
      # used; Niri columns and workspaces carry layouts and sessions. Alt+n/i/o
      # stay with Helix.
      keybind = [
        "alt+h=goto_split:left"
        "alt+left=goto_split:left"
        "alt+l=goto_split:right"
        "alt+right=goto_split:right"
        "alt+j=goto_split:down"
        "alt+down=goto_split:down"
        "alt+k=goto_split:up"
        "alt+up=goto_split:up"
        "alt+f=toggle_split_zoom"
        "alt+equal=equalize_splits"
        "alt+bracket_left=previous_tab"
        "alt+bracket_right=next_tab"
      ];
    };
  };

  dotfiles.tooling.terminals.ghostty.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { [$"--class=($class)"] }
    let command_args = if ($args | is-empty) { [] } else { ["-e"] ++ $args }
    ^${lib.getExe config.programs.ghostty.package} ...$class_args $"--working-directory=($directory)" ...$command_args
  '';
}
