{ config, ... }:
{
  den.aspects.omniroute = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.imports = [ ../../../../modules/nixos/services/agent-servers/omniroute.nix ];
  };
}
