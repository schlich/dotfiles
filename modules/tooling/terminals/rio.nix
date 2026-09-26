{
  config,
  lib,
  ...
}:

{
  programs.rio.enable = config.dotfiles.primary.terminal == "rio";

  dotfiles.tooling.terminals.rio.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { ["--app-id" $class] }
    let command_args = if ($args | is-empty) { [] } else { ["-e"] ++ $args }
    ^${lib.getExe config.programs.rio.package} ...$class_args --working-dir $directory ...$command_args
  '';
}
