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
  xdg.configFile."niri/session.nu".source = ../../niri/session.nu;
  xdg.configFile."niri/workspace-overview.nu".source = ../../niri/workspace-overview.nu;
  xdg.configFile."niri/keymap.nu".source = ../../niri/keymap.nu;
  xdg.configFile."niri/keymap-emoji.nuon".source = ../../niri/keymap-emoji.nuon;
  xdg.dataFile."wallpapers/niri-navigation.svg".source = ../../wallpapers/niri-navigation.svg;
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
