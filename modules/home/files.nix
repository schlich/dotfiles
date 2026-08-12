{
  config,
  homeDirectory,
  pkgs,
  ...
}:

{
  xdg.configFile."home-manager".source =
    config.lib.file.mkOutOfStoreSymlink "${homeDirectory}/dotfiles";
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
  xdg.configFile."autostart/superproductivity.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Super Productivity Task Widget
    Comment=Restore Super Productivity and its configured task widget at login
    Exec=${pkgs.super-productivity}/bin/superproductivity
    StartupNotify=false
  '';
  xdg.dataFile."wallpapers/niri-navigation.svg".source = ../../wallpapers/niri-navigation.svg;
  xdg.configFile."zellij/config.kdl".source = ../../zellij/config.kdl;
  xdg.configFile."zellij/layouts/default.kdl".source = ../../zellij/layouts/default.kdl;
}
