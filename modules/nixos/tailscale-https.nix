# The HTTPS ports this host's Tailscale node publishes. Serve and Funnel
# share one port space per node, and Funnel only accepts 443, 8443 and
# 10000, so a module that publishes through either claims its port here and
# reads it back; evaluation fails when two claims collide. Each module that
# claims a port imports this one. A service that runs its own tailscaled,
# like the Tangled knot, is a separate node and claims nothing here.
#
# A unit that runs `tailscale serve` at start puts waitForBackend in its
# ExecStartPre. An activation that changes the tailscale package restarts
# tailscaled, and a serve started before the daemon is back exits 1, which
# fails the switch even though Restart= recovers it seconds later.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  funnelPorts = [
    443
    8443
    10000
  ];
  claims = config.dotfiles.tailscale.https;
  claimantsByPort = lib.groupBy (name: toString claims.${name}.port) (lib.attrNames claims);
in
{
  options.dotfiles.tailscale.waitForBackend = mkOption {
    type = types.path;
    readOnly = true;
    default = pkgs.writeShellScript "tailscale-wait-for-backend" ''
      until ${config.services.tailscale.package}/bin/tailscale status --json 2>/dev/null \
        | ${pkgs.jq}/bin/jq --exit-status '.BackendState == "Running"' >/dev/null; do
        sleep 1
      done
    '';
    description = "Script that waits until tailscaled is up and logged in, for a Serve unit's ExecStartPre; pair it with a TimeoutStartSec.";
  };

  options.dotfiles.tailscale.https = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          port = mkOption {
            type = types.port;
            description = "HTTPS port on this host's tailnet name.";
          };
          funnel = mkOption {
            type = types.bool;
            default = false;
            description = "Whether Funnel publishes the port to the internet rather than only to the tailnet.";
          };
        };
      }
    );
    default = { };
    description = "HTTPS ports published through Tailscale Serve or Funnel, by the service that claims each.";
  };

  config.assertions =
    lib.mapAttrsToList (port: names: {
      assertion = lib.length names == 1;
      message = "Tailscale HTTPS port ${port} is claimed by ${lib.concatStringsSep " and " names}; Serve and Funnel share one port space per node.";
    }) claimantsByPort
    ++ lib.mapAttrsToList (name: claim: {
      assertion = !claim.funnel || lib.elem claim.port funnelPorts;
      message = "dotfiles.tailscale.https.${name}: Funnel publishes only ports 443, 8443 and 10000, not ${toString claim.port}.";
    }) claims;
}
