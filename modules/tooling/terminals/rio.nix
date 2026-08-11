{ pkgs, ... }:

{
  programs.rio.enable = true;

  dotfiles.tooling.terminals.rio.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { ["--app-id" $class] }
    let command_args = if ($args | is-empty) { [] } else { ["-e"] ++ $args }
    ^${pkgs.rio}/bin/rio ...$class_args --working-dir $directory ...$command_args
  '';
}
