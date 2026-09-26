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
    };
  };

  dotfiles.tooling.terminals.ghostty.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { [$"--class=($class)"] }
    let command_args = if ($args | is-empty) { [] } else { ["-e"] ++ $args }
    ^${lib.getExe config.programs.ghostty.package} ...$class_args $"--working-directory=($directory)" ...$command_args
  '';
}
