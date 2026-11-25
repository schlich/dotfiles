{ config, ... }:
{
  den.aspects.executor = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.imports = [ ../../../../modules/nixos/services/agent-servers/executor.nix ];
  };
}
