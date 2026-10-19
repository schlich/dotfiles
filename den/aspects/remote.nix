{ config, ... }:
{
  den.aspects.remote = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos = {
      imports = [
        ../../modules/nixos/homelab-cache-client.nix
        ../../modules/nixos/homelab-builder-client.nix
        ../../modules/nixos/grpc-store-client.nix
      ];
      services.tailscale.enable = true;
    };
  };
}
