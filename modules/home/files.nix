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
  xdg.configFile."niri/launch-kitty.nu".source = ../../niri/launch-kitty.nu;
  xdg.configFile."zellij/config.kdl".source = ../../zellij/config.kdl;
  xdg.configFile."zellij/layouts/default.kdl".source = ../../zellij/layouts/default.kdl;
}
