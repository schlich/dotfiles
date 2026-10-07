{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.jj-ci-webhook;
  homePath = config.home-manager.users.schlich.home.path;
  listener = pkgs.writeShellApplication {
    name = "jj-ci-webhook";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${../../scripts/jj-ci-webhook.py}
    '';
  };
in
{
  options.services.jj-ci-webhook = {
    enable = lib.mkEnableOption "a GitHub workflow webhook that syncs a local JJ checkout and runs read-only CI triage";
    projectDir = lib.mkOption {
      type = lib.types.path;
      default = "/home/schlich/dotfiles";
      description = "Checkout to synchronize after a successful main validation.";
    };
    repository = lib.mkOption {
      type = lib.types.str;
      default = "schlich/dotfiles";
      description = "GitHub repository full name accepted by the webhook.";
    };
    workflow = lib.mkOption {
      type = lib.types.str;
      default = "nix-ci";
      description = "GitHub Actions workflow name that must complete successfully.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Loopback address for the webhook listener.";
    };
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Local port for the webhook listener and Funnel backend.";
    };
    path = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/github/webhook";
      description = "HTTP path configured in the GitHub webhook.";
    };
    funnel.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Expose the loopback listener publicly through Tailscale Funnel.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale.enable = true;

    systemd.services.jj-ci-webhook = {
      description = "GitHub webhook listener for local JJ synchronization";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Give up after five failed starts in five minutes instead of retrying
      # a persistent failure forever; `systemctl restart` clears the limit.
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
      serviceConfig = {
        ExecStart = "${pkgs.secretspec}/bin/secretspec run --file ${../../modules/secretspec.toml} --provider keyring --profile default --scope jj-ci-webhook --reason=webhook-listener-startup -- ${listener}/bin/jj-ci-webhook";
        Environment = [
          "PATH=${homePath}/bin:${config.systemd.services.jj-ci-webhook.environment.PATH}"
        ];
        User = "schlich";
        Group = "users";
        WorkingDirectory = cfg.projectDir;
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        # The secretspec audit log records this unattended secret read; the
        # leading "-" keeps a missing state directory from failing the unit.
        ReadWritePaths = [
          cfg.projectDir
          "-/home/schlich/.local/state/secretspec"
        ];
      };
      environment = {
        HOME = "/home/schlich";
        XDG_RUNTIME_DIR = "/run/user/1001";
        DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1001/bus";
        JJ_CI_WEBHOOK_PROJECT_DIR = cfg.projectDir;
        JJ_CI_WEBHOOK_REPOSITORY = cfg.repository;
        JJ_CI_WEBHOOK_WORKFLOW = cfg.workflow;
        JJ_CI_WEBHOOK_LISTEN_ADDRESS = cfg.listenAddress;
        JJ_CI_WEBHOOK_LISTEN_PORT = toString cfg.listenPort;
        JJ_CI_WEBHOOK_PATH = cfg.path;
        JJ_CI_WEBHOOK_SYNC_COMMAND = "${homePath}/bin/ci sync";
        JJ_CI_WEBHOOK_REFRESH_COMMAND = "${homePath}/bin/ci sequence --apply";
        JJ_CI_WEBHOOK_AGENT_COMMAND = "${pkgs.codex}/bin/codex exec --sandbox read-only --ephemeral --ignore-user-config --color never -";
      };
    };

    systemd.services.jj-ci-webhook-funnel = lib.mkIf cfg.funnel.enable {
      description = "Tailscale Funnel for the local JJ synchronization webhook";
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
        ExecStart = "${pkgs.tailscale}/bin/tailscale funnel --bg ${toString cfg.listenPort}";
        ExecStop = "${pkgs.tailscale}/bin/tailscale funnel ${toString cfg.listenPort} off";
      };

      # Funnel requires one-time interactive Tailscale authentication and
      # approval. Start this unit manually after `tailscale up` so a logged
      # out client cannot make an otherwise successful system activation fail.
    };
  };
}
