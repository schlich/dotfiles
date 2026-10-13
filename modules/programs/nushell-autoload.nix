{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.nushellAutoload;
in
{
  options.dotfiles.nushellAutoload = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = { };
    description = ''
      Nushell files loaded by every interactive session and the agent MCP
      server, keyed by file name without `.nu`. They ship in the user
      profile's share/nushell/vendor/autoload, which Nushell searches through
      XDG_DATA_DIRS, instead of ~/.config/nushell/autoload. Scripts and
      `nu -c` load neither directory.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    home.packages = [
      (pkgs.linkFarm "nushell-vendor-autoload" (
        lib.mapAttrsToList (name: path: {
          name = "share/nushell/vendor/autoload/${name}.nu";
          inherit path;
        }) cfg
      ))
    ];
    dotfiles.retiredHomeFiles = lib.mapAttrsToList (name: _: ".config/nushell/autoload/${name}.nu") cfg;
  };
}
