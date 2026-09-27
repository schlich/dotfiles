{
  inputs,
  lib,
  pkgs,
  ...
}:

let
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
    enable = true;
    domain = "homelab.tail338351.ts.net:${toString funnelPort}";
    inherit port;
    useHTTPS = true;
    nginx.enable = false;
    admins = [ "github:schlich" ];
    buildSystems = [ "x86_64-linux" ];
    # Den host evaluations are large; keep evaluation within a small server.
    evalWorkerCount = lib.mkDefault 2;
    evalMaxMemorySize = lib.mkDefault 4096;
    github = {
      enable = true;
      # The importing host sets appId and oauthId from the GitHub App.
      appSecretKeyFile = "${secretsDir}/github-app.pem";
      webhookSecretFile = "${secretsDir}/github-webhook-secret";
      oauthSecretFile = "${secretsDir}/github-oauth-secret";
      repoAllowlist = [ "schlich/dotfiles" ];
      topic = null;
    };
  };

  systemd.tmpfiles.rules = [ "d ${secretsDir} 0700 root root -" ];

  # Funnel requires one-time interactive Tailscale authentication and approval.
  # Start this unit manually after `tailscale up` on the homelab host.
  systemd.services.nixbot-funnel = {
    description = "Tailscale Funnel for nixbot";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale funnel --bg --https=${toString funnelPort} ${toString port}";
      ExecStop = "${pkgs.tailscale}/bin/tailscale funnel --https=${toString funnelPort} ${toString port} off";
    };
  };
}
