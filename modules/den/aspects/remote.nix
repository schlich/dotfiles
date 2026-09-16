{ config, ... }:
{
  den.aspects.remote = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.services.tailscale.enable = true;
  };
}
