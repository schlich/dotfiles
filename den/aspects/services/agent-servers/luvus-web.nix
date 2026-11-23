{
  config,
  lib,
  ...
}:
let
  # Luvus Web's loopback port, and its HTTPS port on the tailnet:
  # modules/nixos/services/user-servers/luvus-web.nix publishes it there, as
  # for the T3 Code server.
  port = 4174;
in
{
  # The system half: Tailscale Serve publishes the bridge to the tailnet, and
  # on a stationary host the owner lingers, so the Luvus server and its
  # bridge run from boot.
  den.aspects.luvus-web = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.imports = [ ../../../../modules/nixos/services/user-servers/luvus-web.nix ];
    includes = [
      (
        { host, ... }:
        let
          owners = lib.attrNames (lib.filterAttrs (_: user: user.home) host.users);
        in
        {
          nixos.dotfiles.luvusWeb = {
            inherit port;
            linger = !host.hardware.portable;
            user =
              assert lib.assertMsg (
                lib.length owners == 1
              ) "host ${host.name}: Luvus Web needs exactly one user with a home, not ${toString owners}";
              lib.head owners;
          };
        }
      )
    ];
  };

  # The home half, which users on a host with the bridge include
  # (den/aspects/users/schlich.nix): the bridge as a user unit beside the
  # Luvus server's (modules/programs/multiplexers/luvus.nix), answering to the
  # host's tailnet name.
  den.aspects.luvus-web-home = {
    meta = config.myConfig.aspectPolicy.remote;
    homeManager =
      { osConfig, ... }:
      {
        dotfiles.luvus.web = {
          enable = true;
          inherit port;
          publicUrl = "https://${osConfig.dotfiles.fleet.fqdn}:${toString port}";
        };
      };
  };
}
