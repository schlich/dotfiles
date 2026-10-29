# The system half of the T3 Code server, which runs as a systemd user unit
# of its owner (modules/tooling/ai/t3code-server.nix). Where the owner
# lingers, the server starts at boot and outlives logout; elsewhere it runs
# while the owner is logged in. Tailscale Serve publishes its loopback
# listener to the tailnet only, over HTTPS on the host's tailnet name, so
# phones, other hosts and linked environments reach it encrypted. Tailscale
# stays configured by root here: the server never needs operator rights, and
# agents running as the owner cannot republish ports.
{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.dotfiles.t3code;
  port = toString cfg.port;
  tailscale = "${config.services.tailscale.package}/bin/tailscale";
in
{
  imports = [ ./tailscale-https.nix ];

  options.dotfiles.t3code = {
    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "schlich";
      description = "The user whose Home Manager runs the T3 Code server on this host.";
    };
    port = mkOption {
      type = types.port;
      default = 3773;
      description = ''
        Port of the server's loopback listener, and its HTTPS port on the
        tailnet, so the server answers at https://HOST.TAILNET:PORT/.
      '';
    };
    linger = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the owner's user manager, and with it the server, starts at
        boot and outlives logout. Lingering starts every one of the owner's
        user services at boot, before a login unlocks the keyring.
      '';
    };
  };

  config = mkIf (cfg.user != null) {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "dotfiles.t3code publishes the T3 Code server through Tailscale Serve; enable services.tailscale.";
      }
    ];

    users.users.${cfg.user}.linger = mkIf cfg.linger true;

    # Serve, not Funnel: only tailnet devices reach the server.
    dotfiles.tailscale.https.t3code.port = cfg.port;

    systemd.services.t3code-tailscale-serve = {
      description = "Publish the T3 Code server privately on the tailnet";
      wantedBy = [ "multi-user.target" ];
      requires = [ "tailscaled.service" ];
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${tailscale} serve --https=${port} http://127.0.0.1:${port}";
        ExecStop = "${tailscale} serve --https=${port} off";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
