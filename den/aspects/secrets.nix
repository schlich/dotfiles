{ config, ... }:
{
  den.aspects.secrets = {
    meta = config.myConfig.aspectPolicy.secrets;
    nixos.imports = [ ../../modules/nixos/secrets.nix ];
  };
}
