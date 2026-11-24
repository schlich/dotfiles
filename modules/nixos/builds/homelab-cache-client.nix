{
  config,
  inputs,
  lib,
  ...
}:

let
  cache = import ../../../hosts/homelab/cache.nix;
  homelabUrl = "http://${config.dotfiles.fleet.hosts.homelab.fqdn}:${toString cache.port}";
  nixosPublicKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
  devenvPublicKey = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
  ncroPort = 8085;
  ncroUrl = "http://127.0.0.1:${toString ncroPort}";
in
{
  imports = [ inputs.ncro.nixosModules.default ];

  # Route homelab, cache.nixos.org, and devenv.cachix.org through a local ncro
  # proxy that tracks live upstream latency and routes around slow or offline
  # caches. cache.flakehub.com stays direct on Nix so `fh login`'s rotating
  # netrc continues to work untouched. The host serving Harmonia does not query
  # itself.
  config = lib.mkIf (!config.services.harmonia.cache.enable) {
    services.ncro = {
      enable = true;
      settings = {
        server = {
          listen = "127.0.0.1:${toString ncroPort}";
          # Advertised lower than cache.nixos.org (40), so Nix always tries
          # local ncro first and only falls through if ncro is down.
          cache_priority = 30;
        };
        upstreams = [
          {
            url = homelabUrl;
            priority = 10;
            # Harmonia serves homelab's whole store, including paths originally
            # substituted from cache.nixos.org or devenv.cachix.org.
            public_keys = [
              cache.publicKey
              nixosPublicKey
              devenvPublicKey
            ];
          }
          {
            url = "https://cache.nixos.org";
            priority = 20;
            public_key = nixosPublicKey;
          }
          {
            url = "https://devenv.cachix.org";
            priority = 30;
            public_key = devenvPublicKey;
          }
        ];
        fallback_cache = {
          enabled = true;
          url = "https://cache.nixos.org";
          public_key = nixosPublicKey;
        };
        cache.negative_ttl = "2m";
        logging.timestamps = false;
      };
    };

    nix.settings = {
      # Keep cache.nixos.org as a lower-priority direct fallback so builds
      # still substitute if ncro is ever stopped or restarting.
      substituters = lib.mkForce [
        ncroUrl
        "https://cache.nixos.org"
      ];
      trusted-public-keys = [ cache.publicKey ];
      connect-timeout = 5;
      fallback = true;
    };
  };
}
