{
  config,
  lib,
  pkgs,
  ...
}:

{
  programs.kitty = lib.mkIf (config.dotfiles.primary.terminal == "kitty") {
    enable = true;
    enableGitIntegration = true;
    font.name = "Monaspace Krypton";
  };

  dotfiles.tooling.terminals.kitty.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { ["--class" $class] }
    ^${pkgs.kitty}/bin/kitty ...$class_args --directory $directory ...$args
  '';

  programs.nushell.extraConfig = lib.mkIf (config.dotfiles.primary.terminal == "kitty") ''
    $env.config.use_kitty_protocol = true
  '';
}
