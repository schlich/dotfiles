{ config, ... }:
{
  den.aspects.base = {
    meta = config.myConfig.aspectPolicy.base;
    nixos = {
      imports = [ ../../modules/nixos/base.nix ];
    };
  };
}
