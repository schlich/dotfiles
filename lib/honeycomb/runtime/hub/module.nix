# The honeycomb hub: the phone's view of the seven areas
# (lib/honeycomb/README.md). An http-nu server on loopback holds the page and
# the last snapshot a host sent with `honeycomb hub sync`, and queues the
# actions taken on the phone until that host applies them. Tailscale Serve
# publishes it to the tailnet only; server.nu refuses requests that did not
# come through Serve.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkOption types;
  cfg = config.services.honeycomb-hub;
  servePort = config.dotfiles.tailscale.https.honeycomb-hub.port;
  stateDir = "/var/lib/honeycomb-hub";
  site =
    pkgs.runCommand "honeycomb-hub-site"
      {
        nativeBuildInputs = [ pkgs.librsvg ];
      }
      ''
        mkdir -p "$out"
        cp ${./index.html} "$out/index.html"
        cp ${./hub.js} "$out/hub.js"
        cp ${./sw.js} "$out/sw.js"
        cp ${./icon.svg} "$out/icon.svg"
        # Android installs a home-screen app only with a raster icon.
        rsvg-convert --width 512 --height 512 ${./icon.svg} > "$out/icon-512.png"
      '';
in
{
  imports = [ ../../../../modules/nixos/fleet/tailscale-https.nix ];

  options.services.honeycomb-hub = {
    enable = mkEnableOption "the honeycomb hub, the phone's view of the seven areas";

    port = mkOption {
      type = types.port;
      default = 8790;
      description = "Loopback port of the hub's http-nu server.";
    };
  };

  config = lib.mkIf cfg.enable {
    dotfiles.tailscale.https.honeycomb-hub.port = lib.mkDefault 7444;

    systemd.services.honeycomb-hub = {
      description = "Serve the honeycomb hub on loopback";
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOME = stateDir;
        HUB_STATE = stateDir;
        HUB_STATIC = "${site}";
      };
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "honeycomb-hub";
        ExecStart = "${lib.getExe pkgs.http-nu} --log-format jsonl 127.0.0.1:${toString cfg.port} ${./server.nu}";
        Restart = "on-failure";
        RestartSec = "5s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    # Tailscale Serve, not Funnel: only tailnet devices reach the hub.
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
