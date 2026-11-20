{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The niri session scripts as commands: the binds (niri/binds.nix) run
  # `niri-desk SUBCOMMAND` and `niri-keymap hints`, and the scripts find
  # their siblings with `path self`. niri reads config.kdl from
  # /etc/niri/config.kdl (modules/nixos/workstation/desktop.nix).
  niriBinds = import ../../niri/binds.nix { inherit lib; };
  # Where each area sits and which key points there, for the launcher and
  # the bar's navigation hints, and the areas themselves (`flower`) for the
  # session presets.
  niriAreas = pkgs.writeText "niri-areas.json" (
    builtins.toJSON {
      inherit (niriBinds)
        areas
        keys
        out
        down
        up
        ;
      flower = (import ../../lib/honeycomb { inherit lib; }).areas;
    }
  );
  niriDesk = pkgs.runCommandLocal "niri-desk" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    share="$out/share/niri-desk"
    mkdir -p "$share"
    cp ${niriAreas} "$share/areas.json"
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
  # The XDG dirs belong to the life area (~/Life), so `createDirectories`
  # never makes a seventh folder in ~. Videos join Pictures, and the unused
  # dirs fold into Downloads, the inbox.
  xdg.userDirs =
    let
      life = "${config.home.homeDirectory}/Life";
    in
    {
      enable = true;
      createDirectories = true;

      download = "${life}/Downloads";
      documents = "${life}/Documents";
      pictures = "${life}/Pictures";
      videos = "${life}/Pictures";
      music = "${life}/Downloads";
      desktop = "${life}/Downloads";
      publicShare = "${life}/Downloads";
      templates = "${life}/Downloads";
      # Projects live in the six area folders (~/AREA/NAME), which no single
      # XDG dir fits. Home Manager otherwise defaults this to ~/Projects and
      # recreates it on every activation.
      projects = null;
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
