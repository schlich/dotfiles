{
  config,
  lib,
  pkgs,
  ...
}:

{
  programs.ghostty = lib.mkIf (config.dotfiles.primary.terminal == "ghostty") {
    enable = true;
    installBatSyntax = true;
    settings = {
      copy-on-select = true;
      font-family = "Monaspace Krypton";
      # Ghostty is the terminal container in the input stack. It deliberately
      # claims no global prefix: terminal and shell Alt/Ctrl input is forwarded
      # unless a future terminal-local action is explicitly added here.
    };
  };

  dotfiles.tooling.terminals.ghostty.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { [$"--class=($class)"] }
    let command_args = if ($args | is-empty) { [] } else { ["-e"] ++ $args }
    ^${pkgs.ghostty}/bin/ghostty ...$class_args $"--working-directory=($directory)" ...$command_args
  '';
}
