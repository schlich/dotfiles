# Publishes the honeycomb hub (github:schlich/honeycomb's nixosModules.hub,
# on loopback) privately on the tailnet. Tailscale Serve, not Funnel: only
# tailnet devices reach it, and Serve sets the Tailscale-User-Login header the
# hub's server requires.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.honeycomb-hub;
  servePort = config.dotfiles.tailscale.https.honeycomb-hub.port;
in
{
  imports = [ ../fleet/tailscale-https.nix ];

  config = lib.mkIf cfg.enable {
    dotfiles.tailscale.https.honeycomb-hub.port = lib.mkDefault 7444;

    systemd.services.honeycomb-hub-serve = {
      description = "Publish the honeycomb hub privately on the tailnet";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "honeycomb-hub.service"
        "tailscaled.service"
      ];
      after = [
        "honeycomb-hub.service"
        "tailscaled.service"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = config.dotfiles.tailscale.waitForBackend;
        TimeoutStartSec = "2min";
        ExecStart = "${pkgs.tailscale}/bin/tailscale serve --https=${toString servePort} http://127.0.0.1:${toString cfg.port}";
        ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=${toString servePort} off";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
