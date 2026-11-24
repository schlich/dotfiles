# OmniRoute AI gateway (nixpkgs services.omniroute), kept on loopback and
# published privately on the tailnet through Tailscale Serve.
#
# When secrets/omniroute/env.age exists, agenix decrypts it and passes it via
# services.omniroute.environmentFiles (JWT_SECRET, API_KEY_SECRET,
# OMNIROUTE_WS_BRIDGE_SECRET, etc.). While absent, OmniRoute auto-generates and
# persists JWT_SECRET and API_KEY_SECRET in /var/lib/omniroute/server.env on
# first start and uses its onboarding wizard to set the dashboard password.
{
  config,
  lib,
  ...
}:

let
  port = 20128;
  servePort = config.dotfiles.tailscale.https.omniroute.port;
  fqdn = config.dotfiles.fleet.fqdn;
  publicUrl = "https://${fqdn}:${toString servePort}";
  # Serializes serve-config updates with the other serve units
  # (modules/nixos/fleet/tailscale-https.nix).
  tailscaleServe = config.dotfiles.tailscale.serve;

  secretFile = ../../../../secrets/omniroute/env.age;
  secretReady = builtins.pathExists secretFile;
in
{
  imports = [ ../../fleet/tailscale-https.nix ];

  assertions = [
    {
      assertion = config.services.tailscale.enable;
      message = "services.omniroute publishes through Tailscale Serve; enable services.tailscale.";
    }
  ];

  # Serve, not Funnel: only tailnet devices reach OmniRoute.
  dotfiles.tailscale.https.omniroute.port = lib.mkDefault port;

  environment.systemPackages = [ config.services.omniroute.package ];

  services.omniroute = {
    enable = true;

    settings = {
      PORT = port;
      # Keep the HTTP listener on loopback; Tailscale Serve terminates HTTPS.
      OMNIROUTE_SERVER_HOST = "127.0.0.1";
      # Loopback origin for server-side internal calls even when proxied.
      BASE_URL = "http://127.0.0.1:${toString port}";
      # Canonical tailnet origin for OAuth redirect_uri and dashboard links.
      NEXT_PUBLIC_BASE_URL = publicUrl;
      # Tailscale Serve forwards from loopback on the same host.
      OMNIROUTE_TRUST_PROXY = "loopback";

      # Security defaults behind HTTPS Tailscale Serve.
      AUTH_COOKIE_SECURE = true;
      REQUIRE_API_KEY = true;
      ALLOW_API_KEY_REVEAL = false;
      CORS_ALLOWED_ORIGINS = publicUrl;

      # Live monitoring WebSocket stays loopback-bound; allow tailnet origins.
      LIVE_WS_HOST = "127.0.0.1";
      LIVE_WS_ALLOWED_HOSTS = fqdn;
      LIVE_WS_ALLOWED_ORIGINS = publicUrl;

      OMNIROUTE_SHOW_LOG = true;
    };

    environmentFiles = lib.optional secretReady config.age.secrets.omniroute-env.path;
  };

  systemd.services.omniroute-serve = {
    description = "Publish OmniRoute privately on the tailnet";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "omniroute.service"
      "tailscaled.service"
    ];
    after = [
      "omniroute.service"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStartPre = config.dotfiles.tailscale.waitForBackend;
      TimeoutStartSec = "2min";
      ExecStart = "${tailscaleServe} serve --https=${toString servePort} http://127.0.0.1:${toString port}";
      ExecStop = "${tailscaleServe} serve --https=${toString servePort} off";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
}
// lib.optionalAttrs secretReady {
  age.secrets.omniroute-env.file = secretFile;
}
