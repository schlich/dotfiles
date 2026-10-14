{ config, ... }:
{
  den.aspects.nix-observability = {
    meta = config.myConfig.aspectPolicy.nix-observability;
    nixos.imports = [ ../../modules/nixos/nix-observability.nix ];
  };
}
