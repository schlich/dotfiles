{ config, ... }:
{
  den.aspects.remote = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos = {
      imports = [ ../../modules/nixos/homelab-cache-client.nix ];
      services.tailscale.enable = true;
    };
  };
}
