{ config, ... }:

{
  den.aspects.homelab = {
    meta = config.myConfig.aspectPolicy.server;

    nixos.imports = [

      ../../modules/nixos/homelab.nix
      ../../modules/nixos/tangled-spindle.nix
    ];
  };
}
