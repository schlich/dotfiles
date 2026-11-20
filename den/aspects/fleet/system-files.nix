{ config, ... }:
{
  den.aspects.system-files = {
    meta = config.myConfig.aspectPolicy.base;
    nixos.imports = [ ../../../modules/nixos/base/files.nix ];
  };
}
