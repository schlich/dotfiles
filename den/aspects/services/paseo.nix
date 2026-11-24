{ config, inputs, ... }:

{
  den.aspects.paseo = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.imports = [
      inputs.paseo.nixosModules.default
      ../../../modules/nixos/services/agent-servers/paseo.nix
    ];
  };

  den.aspects.opencode-server = {
    meta = config.myConfig.aspectPolicy.server;
    nixos.imports = [ ../../../modules/nixos/services/agent-servers/opencode-server.nix ];
  };
}
