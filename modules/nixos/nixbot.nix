{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  app = import ../../hosts/homelab/nixbot.nix;
  # Tailscale Funnel terminates TLS; 443 stays free for the Tangled spindle.
  funnelPort = 8443;
  port = 8010;
  # Provisioned by hand on the host, never in the repository or the store:
  # the GitHub App private key, webhook secret, and OAuth client secret.
  secretsDir = "/var/lib/nixbot-secrets";
in
{
  imports = [ inputs.nixbot.nixosModules.nixbot ];

  services.nixbot = {
    enable = app.appId != null;
    domain = "${config.dotfiles.fleet.fqdn}:${toString funnelPort}";
    inherit port;
    useHTTPS = true;
    nginx.enable = false;
    admins = [ "github:schlich" ];
    buildSystems = [ "x86_64-linux" ];
    evalSystems = [ "x86_64-linux" ];
    # A Den host evaluation peaks near 6 GiB, the budget `ci land` gives its
    # local clearance; nix-eval-jobs restarts a worker past it. One worker
    # and two builds leave room for the spindle's guest on a 15 GiB host.
    evalWorkerCount = 1;
    evalMaxMemorySize = 6144;
    buildConcurrency = 2;
    # Keep what nixbot built for a topic until it lands: `ci land` then
    # substitutes it from Harmonia instead of rebuilding it on the client.
    branches.topics = {
      matchGlob = "jj-*";
      registerGCRoots = true;
    };
    github = {
      enable = true;
      appSecretKeyFile = "${secretsDir}/github-app.pem";
      webhookSecretFile = "${secretsDir}/github-webhook-secret";
      repoAllowlist = [ "schlich/dotfiles" ];
      topic = null;
    }
    // lib.optionalAttrs (app.appId != null) { inherit (app) appId; }
    // lib.optionalAttrs (app.oauthId != null) {
      inherit (app) oauthId;
      oauthSecretFile = "${secretsDir}/github-oauth-secret";
    };
  };

  systemd.tmpfiles.rules = [ "d ${secretsDir} 0700 root root -" ];

  # GitHub delivers the App's webhooks to https://${domain}/webhooks/github
  # only through this Funnel. Like the spindle's, it needs a one-time
  # `tailscale up` and the tailnet's funnel node attribute, and retries while
  # tailscaled's backend is not ready at boot.
  systemd.services.nixbot-funnel = lib.mkIf config.services.nixbot.enable {
    description = "Tailscale Funnel for nixbot";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStartSec = "30s";
      ExecStart = "${pkgs.tailscale}/bin/tailscale funnel --bg --https=${toString funnelPort} ${toString port}";
      ExecStop = "${pkgs.tailscale}/bin/tailscale funnel --https=${toString funnelPort} off";
    };
  };
}
