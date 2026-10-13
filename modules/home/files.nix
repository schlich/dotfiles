{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The niri session scripts as commands: config.kdl's binds run
  # `niri-desk SUBCOMMAND` and `niri-keymap hints`, and the scripts find
  # their siblings with `path self`. niri reads config.kdl from
  # /etc/niri/config.kdl (modules/nixos/desktop.nix).
  niriDesk = pkgs.runCommandLocal "niri-desk" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    share="$out/share/niri-desk"
    mkdir -p "$share"
    cp ${../../niri/session.nu} "$share/session.nu"
    cp ${../../niri/workspace-overview.nu} "$share/workspace-overview.nu"
    cp ${../../niri/keymap.nu} "$share/keymap.nu"
    cp ${../../niri/keymap-emoji.nuon} "$share/keymap-emoji.nuon"
    makeWrapper ${lib.getExe pkgs.nushell} "$out/bin/niri-desk" --add-flags "$share/session.nu"
    makeWrapper ${lib.getExe pkgs.nushell} "$out/bin/niri-keymap" --add-flags "$share/keymap.nu"
  '';
in
{
  home.packages = [ niriDesk ];

  xdg.configFile."nushell/completions/niri.nu".source =
    pkgs.runCommandLocal "niri-nushell-completions.nu"
      {
        nativeBuildInputs = [ pkgs.niri ];
      }
      ''
        ${pkgs.niri}/bin/niri completions nushell > "$out"
      '';
  xdg.userDirs = {
    enable = true;
    createDirectories = true;

    download = "${config.home.homeDirectory}/Downloads";
    documents = "${config.home.homeDirectory}/Documents";
    pictures = "${config.home.homeDirectory}/Pictures";
    videos = "${config.home.homeDirectory}/Videos";
    # Unused XDG dirs fold into Johnny Decimal areas instead of cluttering ~.
    music = "${config.home.homeDirectory}/80-89 Personal";
    desktop = "${config.home.homeDirectory}/90-99 Inbox";
    publicShare = "${config.home.homeDirectory}/90-99 Inbox";
    templates = "${config.home.homeDirectory}/90-99 Inbox";
  };

  dotfiles.retiredHomeFiles = [
    ".config/niri/config.kdl"
    ".config/niri/session.nu"
    ".config/niri/workspace-overview.nu"
    ".config/niri/keymap.nu"
    ".config/niri/keymap-emoji.nuon"
    ".local/share/wallpapers/niri-navigation.svg"
  ];
}
