# The system half of Luvus Web, the browser client of a Luvus server, which
# runs as its owner's systemd user unit beside that server
# (modules/programs/multiplexers/luvus.nix). Where the owner lingers, both
# start at boot and outlive logout. Tailscale Serve publishes the bridge's
# loopback listener to the tailnet only, over HTTPS on the host's tailnet
# name: the bridge needs that TLS in front of it, and its own one-use
# pairing admits each browser. Root runs Serve, as for the T3 Code server.
{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.dotfiles.luvusWeb;
  port = toString cfg.port;
  tailscale = "${config.services.tailscale.package}/bin/tailscale";
in
{
  imports = [ ../../fleet/tailscale-https.nix ];

  options.dotfiles.luvusWeb = {
    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "schlich";
      description = "The user whose Home Manager runs Luvus and its web bridge on this host.";
    };
    port = mkOption {
      type = types.port;
      default = 4174;
      description = ''
        Port of the bridge's loopback listener, and its HTTPS port on the
        tailnet, so it answers at https://HOST.TAILNET:PORT/.
      '';
    };
    linger = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the owner's user manager, and with it the Luvus server and
        its bridge, starts at boot and outlives logout.
      '';
    };
  };

  config = mkIf (cfg.user != null) {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "dotfiles.luvusWeb publishes Luvus Web through Tailscale Serve; enable services.tailscale.";
      }
    ];

    users.users.${cfg.user}.linger = mkIf cfg.linger true;

    # Serve, not Funnel: only tailnet devices reach the bridge.
    dotfiles.tailscale.https.luvus-web.port = cfg.port;

    systemd.services.luvus-web-tailscale-serve = {
      description = "Publish Luvus Web privately on the tailnet";
      wantedBy = [ "multi-user.target" ];
      requires = [ "tailscaled.service" ];
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = config.dotfiles.tailscale.waitForBackend;
        TimeoutStartSec = "2min";
        ExecStart = "${tailscale} serve --https=${port} http://127.0.0.1:${port}";
        ExecStop = "${tailscale} serve --https=${port} off";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
