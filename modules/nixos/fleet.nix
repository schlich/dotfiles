{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  # Where the rest of the fleet is, from den/inventory.nix. The
  # fleet-network aspect (den/aspects/fleet-network.nix) sets these, so
  # modules address other hosts by name instead of hardcoding the tailnet.
  options.dotfiles.fleet = {
    tailnet = mkOption {
      type = types.str;
      example = "tail0000.ts.net";
      description = "The Tailscale MagicDNS suffix every host shares.";
    };
    fqdn = mkOption {
      type = types.str;
      description = "This host's name on the tailnet.";
    };
    hosts = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.fqdn = mkOption {
            type = types.str;
            description = "The host's name on the tailnet.";
          };
        }
      );
      default = { };
      description = "Every host in the inventory, by name.";
    };
  };
}
