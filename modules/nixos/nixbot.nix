{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nixbot;
  app = import ../../hosts/homelab/nixbot.nix;
  # Tailscale Funnel terminates TLS on this port. 443 keeps a port out of the
  # App's URLs; ci-dashboard-serve holds 8443 on the tailnet.
  funnelPort = 443;
  port = 8010;
  domain =
    config.dotfiles.fleet.fqdn + lib.optionalString (funnelPort != 443) ":${toString funnelPort}";
  baseUrl = "https://${domain}";
  repository = "schlich/dotfiles";
  # On its first start, with an empty database, nixbot enables the
  # repositories that carry this topic; nixbot-register adds it.
  topic = "build-with-nixbot";

  # What GitHub returns when it creates the App, by the field of the manifest
  # conversion that holds each secret. nixbot-register encrypts them for the
  # recipients secrets/secrets.nix lists; agenix decrypts them here.
  secrets = {
    github-app = {
      field = "pem";
      file = "secrets/nixbot/github-app.pem.age";
    };
    github-webhook-secret = {
      field = "webhook_secret";
      file = "secrets/nixbot/github-webhook-secret.age";
    };
    github-oauth-secret = {
      field = "client_secret";
      file = "secrets/nixbot/github-oauth-secret.age";
    };
  };
  rules = import ../../secrets/secrets.nix;
  secretPath = name: config.age.secrets."nixbot-${name}".path;

  # The GitHub App nixbot runs as. docs/nixbot.md says why it may do each
  # thing, and the nixbot-app-manifest check holds the two together.
  # nixbot-register adds the redirect_url it listens on.
  manifest = {
    name = "nixbot-${lib.replaceStrings [ "/" ] [ "-" ] repository}";
    description = "Builds the flake checks of ${repository} with nixbot on ${config.networking.hostName}.";
    url = baseUrl;
    hook_attributes = {
      url = "${baseUrl}/webhooks/github";
      active = true;
    };
    callback_urls = [ "${baseUrl}/auth/github/callback" ];
    public = false;
    request_oauth_on_install = false;
    default_permissions = {
      contents = "read";
      checks = "write";
      metadata = "read";
      pull_requests = "read";
    };
    default_events = [
      "push"
      "pull_request"
      "check_run"
      "check_suite"
    ];
  };
in
{
  imports = [ inputs.nixbot.nixosModules.nixbot ];

  options.dotfiles.nixbot.registration = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = ''
      What nixbot-register registers and writes, as JSON: the App manifest,
      the repository to install it on, the topic nixbot imports, the file
      that names the App, and each secret's file and recipients.
    '';
  };

  config = {
    dotfiles.nixbot.registration = pkgs.writeText "nixbot-registration.json" (
      builtins.toJSON {
        inherit manifest repository topic;
        app = "hosts/homelab/nixbot.nix";
        secrets = lib.mapAttrsToList (_: secret: {
          inherit (secret) field file;
          recipients = rules.${lib.removePrefix "secrets/" secret.file}.publicKeys;
        }) secrets;
      }
    );

    services.nixbot = {
      enable = app.appId != null;
      inherit domain port;
      useHTTPS = true;
      nginx.enable = false;
      admins = [ "github:schlich" ];
      buildSystems = [ "x86_64-linux" ];
      evalSystems = [ "x86_64-linux" ];
      # A Den host evaluation peaks near 6 GiB, the budget `ci land` gives its
      # local clearance; nix-eval-jobs restarts a worker past it. One worker
      # and two builds leave room for offloaded builds on a 15 GiB host.
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
        appSecretKeyFile = secretPath "github-app";
        webhookSecretFile = secretPath "github-webhook-secret";
        oauthSecretFile = secretPath "github-oauth-secret";
        repoAllowlist = [ repository ];
        inherit topic;
      }
      // lib.optionalAttrs (app.appId != null) { inherit (app) appId oauthId; };
    };

    # Decrypted into /run/agenix, readable by root only; nixbot's unit loads
    # them as credentials.
    age.secrets = lib.mkIf cfg.enable (
      lib.mapAttrs' (
        name: secret: lib.nameValuePair "nixbot-${name}" { file = ../../. + "/${secret.file}"; }
      ) secrets
    );

    assertions = lib.mkIf cfg.enable (
      lib.mapAttrsToList (name: secret: {
        assertion = builtins.pathExists config.age.secrets."nixbot-${name}".file;
        message = "nixbot: ${secret.file} is missing; nixbot-register writes it beside the App's IDs (docs/nixbot.md).";
      }) secrets
    );

    # GitHub delivers the App's webhooks, and its logins return, only through
    # this Funnel. It needs a one-time `tailscale up` and the tailnet's funnel
    # node attribute, and retries while tailscaled's backend is not ready at
    # boot.
    systemd.services.nixbot-funnel = lib.mkIf cfg.enable {
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
  };
}
