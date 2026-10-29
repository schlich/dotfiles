{
  config,
  den,
  lib,
  ...
}:
let
  # The hosts whose inventory runs the T3 Code server, and where each one
  # answers on the tailnet: modules/nixos/t3code.nix publishes the server's
  # port there over HTTPS.
  port = 3773;
  servers = lib.filterAttrs (_: host: host.services.t3code) den.hosts.x86_64-linux;
  fleet = lib.mapAttrs (
    name: host: "https://${name}.${host.network.tailnet}:${toString port}"
  ) servers;
in
{
  # The system half: Tailscale Serve publishes the server to the tailnet, and
  # on a stationary host the owner lingers, so the server runs from boot. A
  # portable one serves while its owner is logged in: lingering would start
  # every user service before a login unlocks the keyring.
  den.aspects.t3code = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.imports = [ ../../modules/nixos/t3code.nix ];
    includes = [
      (
        { host, ... }:
        let
          owners = lib.attrNames (lib.filterAttrs (_: user: user.home) host.users);
        in
        {
          nixos.dotfiles.t3code = {
            inherit port;
            linger = !host.profile.portable;
            user =
              assert lib.assertMsg (lib.length owners == 1)
                "host ${host.name}: the T3 Code server needs exactly one user with a home, not ${toString owners}";
              lib.head owners;
          };
        }
      )
    ];
  };

  # The home half, which users on a host with the server include
  # (den/aspects/users/schlich.nix): the server itself, as a user unit.
  den.aspects.t3code-home = {
    meta = config.myConfig.aspectPolicy.remote;
    homeManager = {
      imports = [ ../../modules/tooling/ai/t3code-server.nix ];
      dotfiles.t3code.server = {
        enable = true;
        inherit port fleet;
      };
    };
  };
}
