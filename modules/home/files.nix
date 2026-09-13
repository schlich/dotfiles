{ config, pkgs, ... }:

{
  xdg.configFile."nushell/completions/niri.nu".source =
    pkgs.runCommandLocal "niri-nushell-completions.nu"
      {
        nativeBuildInputs = [ pkgs.niri ];
      }
      ''
        ${pkgs.niri}/bin/niri completions nushell > "$out"
      '';
  xdg.configFile."niri/config.kdl".source = ../../niri/config.kdl;
  xdg.configFile."niri/launch-terminal.nu".source = ../../niri/launch-terminal.nu;
  xdg.configFile."niri/workspace-guard.nu".source = ../../niri/workspace-guard.nu;
  xdg.dataFile."wallpapers/niri-navigation.svg".source = ../../wallpapers/niri-navigation.svg;
  xdg.configFile."zellij/config.kdl".source = ../../zellij/config.kdl;
  xdg.configFile."zellij/layouts/default.kdl".source = ../../zellij/layouts/default.kdl;
  xdg.userDirs = {
    enable = true;
    createDirectories = true;

    download = "${config.home.homeDirectory}/Downloads";
    documents = "${config.home.homeDirectory}/Documents";
    music = "${config.home.homeDirectory}/Music";
    pictures = "${config.home.homeDirectory}/Pictures";
    videos = "${config.home.homeDirectory}/Videos";
    desktop = "${config.home.homeDirectory}/Desktop";
    publicShare = "${config.home.homeDirectory}/Public";
    templates = "${config.home.homeDirectory}/Templates";
  };
}
