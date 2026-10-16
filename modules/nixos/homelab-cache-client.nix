{ config, lib, ... }:

let
  cache = import ../../hosts/homelab/cache.nix;
  url = "http://${config.dotfiles.fleet.hosts.homelab.fqdn}:${toString cache.port}";
in
{
  # Fetch what homelab already built before building it here. The host that
  # serves the cache does not query itself.
  config = lib.mkIf (!config.services.harmonia.cache.enable) {
    nix.settings = {
      substituters = [ url ];
      trusted-public-keys = [ cache.publicKey ];
      # Off the tailnet or with homelab down, give up on it quickly and fall
      # back to cache.nixos.org or a local build.
      connect-timeout = 5;
      fallback = true;
    };
  };
}
