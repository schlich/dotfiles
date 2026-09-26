{
  config,
  lib,
  pkgs,
  ...
}:

lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "opencode") {
  home.packages = [ pkgs.opencode-desktop ];

  xdg.configFile."autostart/opencode-desktop.desktop".source =
    "${pkgs.opencode-desktop}/share/applications/opencode-desktop.desktop";
}
