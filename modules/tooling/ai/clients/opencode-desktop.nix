{
  config,
  lib,
  pkgs,
  ...
}:

lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "opencode") {
  home.packages = [ pkgs.opencode-desktop ];
}
