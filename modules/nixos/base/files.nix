{ config, lib, ... }:

{
  # Where this host keeps the dotfiles checkout: a per-host fact, since each
  # host has its own home. The asus homes file it under the nix area
  # (~/Nix/dotfiles); a host that keeps another checkout sets its own. The
  # standalone home reads it through osConfig (modules/home/session/paths.nix).
  options.dotfiles.checkout = lib.mkOption {
    type = lib.types.str;
    default = "/home/schlich/Nix/dotfiles";
    example = "/home/schlich/dotfiles";
    description = "Absolute path of this host's checkout of the dotfiles repository.";
  };

  config.environment.etc."nixos/flake.nix" = {
    source = "${config.dotfiles.checkout}/flake.nix";
    mode = "direct-symlink";
  };
}
