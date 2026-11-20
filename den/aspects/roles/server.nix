{ config, ... }:
{
  den.aspects.server = {
    meta = config.myConfig.aspectPolicy.server;
    nixos.imports = [ ../../../modules/nixos/base/core.nix ];
  };
}
