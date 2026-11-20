{
  config,
  den,
  lib,
  ...
}:
let
  # The hosts whose inventory runs a Rex server, and where each one answers
  # on the tailnet: modules/nixos/services/rex.nix publishes the server there
  # over HTTPS.
  port = 7297;
  socket = "rex/serve.sock";
  servers = lib.filterAttrs (_: host: host.services.rex) den.hosts.x86_64-linux;
  fleet = lib.mapAttrs (
    name: host: "https://${name}.${host.network.tailnet}:${toString port}"
  ) servers;
in
{
  # The system half: Tailscale Serve publishes the server to the tailnet, and
  # on a stationary host the owner lingers, so the server and its sessions
  # run from boot.
  den.aspects.rex = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.imports = [ ../../../modules/nixos/services/rex.nix ];
    includes = [
      (
        { host, ... }:
        let
          owners = lib.attrNames (lib.filterAttrs (_: user: user.home) host.users);
        in
        {
          nixos.dotfiles.rex = {
            inherit port socket;
            linger = !host.hardware.portable;
            user =
              assert lib.assertMsg (
                lib.length owners == 1
              ) "host ${host.name}: the Rex server needs exactly one user with a home, not ${toString owners}";
              lib.head owners;
          };
        }
      )
    ];
  };

  # The home half, which users on a host with the server include
  # (den/aspects/users/schlich.nix): the server itself, as a user unit, also
  # listening on the socket Serve forwards to. %t is the runtime directory.
  den.aspects.rex-home = {
    meta = config.myConfig.aspectPolicy.remote;
    homeManager = {
      imports = [ ../../../modules/tooling/terminals/rex.nix ];
      services.rex.extraListen = [ "tailnet-serve://%t/${socket}" ];
    };
  };

  # Every workstation reaches each server by its host name, as in
  # `rex -S homelab ls`.
  den.aspects.user-desktop.homeManager.dotfiles.rex.hosts = fleet;
}
