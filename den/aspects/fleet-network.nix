{
  config,
  den,
  lib,
  ...
}:
let
  fqdn = name: host: "${name}.${host.network.tailnet}";
in
{
  # The inventory's network facts, handed to modules/nixos/fleet.nix: every
  # host learns the tailnet and how to reach each other host on it.
  den.aspects.fleet-network = {
    meta = config.myConfig.aspectPolicy.remote;
    nixos.imports = [ ../../modules/nixos/fleet.nix ];
    includes = [
      (
        { host, ... }:
        {
          nixos.dotfiles.fleet = {
            inherit (host.network) tailnet;
            fqdn = fqdn host.name host;
            hosts = lib.mapAttrs (name: other: { fqdn = fqdn name other; }) den.hosts.x86_64-linux;
          };
        }
      )
    ];
  };
}
