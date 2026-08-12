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
    settings.font-family = "Monaspace Krypton";
  };

  dotfiles.tooling.terminals.ghostty.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { [$"--class=($class)"] }
    let command_args = if ($args | is-empty) { [] } else { ["-e"] ++ $args }
    ^${pkgs.ghostty}/bin/ghostty ...$class_args $"--working-directory=($directory)" ...$command_args
  '';
}
