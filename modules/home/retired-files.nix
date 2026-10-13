{ config, lib, ... }:

let
  cfg = config.dotfiles.retiredHomeFiles;
  relinkedFiles = lib.filter (target: lib.elem target cfg) (
    map (file: file.target) (lib.filter (file: file.enable) (lib.attrValues config.home.file))
  );
in
{
  options.dotfiles.retiredHomeFiles = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    internal = true;
    description = ''
      Paths relative to $HOME whose configuration now ships on a wrapped
      package (lib/wrap-with-config.nix). Evaluation fails if Home Manager
      links one of them again.
    '';
  };

  config.assertions = [
    {
      assertion = relinkedFiles == [ ];
      message = "Home Manager links files whose configuration ships on a wrapped package: ${lib.concatStringsSep ", " relinkedFiles}";
    }
  ];
}
