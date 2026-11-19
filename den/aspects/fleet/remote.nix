{ config, ... }:
{
  den.aspects.remote = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos = {
      imports = [
        ../../../modules/nixos/builds/homelab-cache-client.nix
        ../../../modules/nixos/builds/homelab-builder-client.nix
        ../../../modules/nixos/builds/grpc-store-client.nix
      ];
      services.tailscale.enable = true;
    };
  };
}
