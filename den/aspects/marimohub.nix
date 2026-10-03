{ config, ... }:
{
  # Not yet included by any host: add it to den.aspects.homelab.includes and
  # set services.marimohub.auth.allowedEmailDomains to enable the hub.
  den.aspects.marimohub = {
    meta = config.myConfig.aspectPolicy.server;
    nixos.imports = [ ../../modules/nixos/workbench-hub.nix ];
  };
}
