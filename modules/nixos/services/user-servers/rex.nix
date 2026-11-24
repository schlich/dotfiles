# The system half of a personal Rex server, which runs as its owner's
# systemd user unit (modules/tooling/terminals/rex.nix). Tailscale Serve
# publishes it to the tailnet only, over HTTPS on the host's tailnet name,
# and forwards each request to the server's `tailnet-serve://` Unix socket
# with the caller's tailnet identity, so Rex admits the host's owner without
# a login of its own and no port opens in the firewall. Root runs Serve, as
# for the T3 Code server: the owner never needs operator rights.
{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.dotfiles.rex;
  uid = config.users.users.${cfg.user}.uid;
  socket = "/run/user/${toString uid}/${cfg.socket}";
  tailscaleServe = config.dotfiles.tailscale.serve;
in
{
  imports = [ ../../fleet/tailscale-https.nix ];

  options.dotfiles.rex = {
    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "schlich";
      description = "The user whose Home Manager runs the Rex server on this host.";
    };
    port = mkOption {
      type = types.port;
      default = 7297;
      description = ''
        HTTPS port on the host's tailnet name. Rex's CLI tries 7297 after 443
        when given a bare host name.
      '';
    };
    socket = mkOption {
      type = types.str;
      default = "rex/serve.sock";
      description = ''
        The server's `tailnet-serve://` socket, relative to its owner's
        runtime directory, where the home half listens.
      '';
    };
    linger = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the owner's user manager, and with it the server and its
        sessions, starts at boot and outlives logout.
      '';
    };
  };

  config = mkIf (cfg.user != null) {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "dotfiles.rex publishes the Rex server through Tailscale Serve; enable services.tailscale.";
      }
      {
        assertion = uid != null;
        message = "dotfiles.rex: set users.users.${cfg.user}.uid, which names the runtime directory holding the Rex server's Serve socket.";
      }
    ];

    users.users.${cfg.user}.linger = mkIf cfg.linger true;

    # Serve, not Funnel: only tailnet devices reach the server.
    dotfiles.tailscale.https.rex.port = cfg.port;

    systemd.services.rex-tailscale-serve = {
      description = "Publish the Rex server privately on the tailnet";
      wantedBy = [ "multi-user.target" ];
      requires = [ "tailscaled.service" ];
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = config.dotfiles.tailscale.waitForBackend;
        TimeoutStartSec = "2min";
        ExecStart = "${tailscaleServe} serve --https=${toString cfg.port} unix:${socket}";
        ExecStop = "${tailscaleServe} serve --https=${toString cfg.port} off";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
