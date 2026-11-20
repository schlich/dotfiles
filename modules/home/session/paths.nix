{
  config,
  lib,
  ...
}@args:

# The two repositories the configuration names by path. ~ holds six visible
# folders, one per honeycomb area (lib/honeycomb/default.nix): this
# repository sits in the nix area and the knowledge base in research. Every
# other reference derives from these options.
let
  home = config.home.homeDirectory;
  # The host's own checkout, a per-host fact (modules/nixos/base/files.nix);
  # a home evaluated without its system falls back to the area layout.
  hostCheckout = (args.osConfig or { }).dotfiles.checkout or null;
in
{
  options.dotfiles.paths = {
    dotfiles = lib.mkOption {
      type = lib.types.str;
      default = if hostCheckout != null then hostCheckout else "${home}/Nix/dotfiles";
      defaultText = lib.literalExpression ''osConfig.dotfiles.checkout or "''${config.home.homeDirectory}/Nix/dotfiles"'';
      description = "Absolute path of the dotfiles checkout in this home.";
    };
    kb = lib.mkOption {
      type = lib.types.str;
      default = "${home}/Research/kb";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/Research/kb"'';
      description = "Absolute path of the knowledge base, an IWE workspace.";
    };
  };

  # Scripts (niri's session launcher, `kb`, honeycomb) read these and fall
  # back to the same defaults.
  config.home.sessionVariables = {
    DOTFILES_ROOT = config.dotfiles.paths.dotfiles;
    KB_ROOT = config.dotfiles.paths.kb;
  };
}
