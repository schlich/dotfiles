# Private Tailscale-only Git HTTP remote for the personal knowledge base.
#
# Serves /home/schlich/Research/kb.git over loopback via git-http-backend,
# and Tailscale Serve publishes it to the tailnet over HTTPS. Requests without
# Tailscale-User-Login are refused with 403, so no SSH keys, keyring unlocks,
# or port-2222 plumbing are needed to sync ~/Research/kb across hosts.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkOption types;
  cfg = config.services.kb-git;
  servePort = config.dotfiles.tailscale.https.kb-git.port;
  remoteUrl = "https://${config.dotfiles.fleet.fqdn}:${toString servePort}/kb.git";
  kbSync = pkgs.writeShellApplication {
    name = "kb-sync";
    runtimeInputs = [
      pkgs.nushell
      pkgs.jujutsu
      pkgs.git
      pkgs.util-linux
      pkgs.coreutils
    ];
    text = ''
      exec ${lib.getExe pkgs.nushell} --no-config-file ${../kb-sync.nu} "$@"
    '';
  };
  ensureBareRepo = pkgs.writeShellScript "kb-git-init-bare" ''
    set -euo pipefail
    mkdir -p ${lib.escapeShellArg cfg.projectRoot}
    repo=${lib.escapeShellArg "${cfg.projectRoot}/kb.git"}
    if [ ! -f "$repo/HEAD" ]; then
      ${pkgs.git}/bin/git init --bare --initial-branch=main "$repo"
    fi
  '';
  onPushArgs = builtins.toJSON [
    "--root"
    cfg.kbRoot
    "--remote-url"
    remoteUrl
    "--fetch-only"
  ];
in
{
  imports = [ ../../../nixos/fleet/tailscale-https.nix ];

  options.services.kb-git = {
    enable = mkEnableOption "private Tailscale HTTPS Git remote for the personal knowledge base";

    port = mkOption {
      type = types.port;
      default = 8792;
      description = "Loopback port of the kb-git HTTP server.";
    };

    user = mkOption {
      type = types.str;
      default = "schlich";
      description = "User that owns the bare repository and local knowledge base checkout.";
    };

    group = mkOption {
      type = types.str;
      default = "users";
      description = "Group for the kb-git service.";
    };

    projectRoot = mkOption {
      type = types.str;
      default = "/home/schlich/Research";
      description = "Directory containing kb.git (only /kb.git endpoints are served).";
    };

    kbRoot = mkOption {
      type = types.str;
      default = "/home/schlich/Research/kb";
      description = "Local knowledge base working copy refreshed after each push.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "services.kb-git publishes the KB Git remote through Tailscale Serve; enable services.tailscale.";
      }
    ];

    dotfiles.tailscale.https.kb-git.port = lib.mkDefault 7445;

    systemd.services.kb-git = {
      description = "Serve the personal knowledge base Git remote on loopback";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.git
        pkgs.coreutils
      ];
      environment = {
        HOME = "/home/${cfg.user}";
        KB_GIT_HOST = "127.0.0.1";
        KB_GIT_PORT = toString cfg.port;
        KB_GIT_PROJECT_ROOT = cfg.projectRoot;
        KB_GIT_BACKEND = "${pkgs.git}/bin/git-http-backend";
        KB_GIT_ON_PUSH = lib.getExe kbSync;
        KB_GIT_ON_PUSH_ARGS = onPushArgs;
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = "${ensureBareRepo}";
        ExecStart = "${lib.getExe pkgs.nodejs} ${./server.mjs}";
        Restart = "on-failure";
        RestartSec = "5s";
        ProtectSystem = "strict";
        ReadWritePaths = lib.unique [
          cfg.projectRoot
          (builtins.dirOf cfg.kbRoot)
        ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    # Tailscale Serve, not Funnel: only tailnet devices reach the knowledge base.
    systemd.services.kb-git-serve = {
      description = "Publish the personal knowledge base Git remote privately on the tailnet";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "kb-git.service"
        "tailscaled.service"
      ];
      after = [
        "kb-git.service"
        "tailscaled.service"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = config.dotfiles.tailscale.waitForBackend;
        TimeoutStartSec = "2min";
        ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --https=${toString servePort} http://127.0.0.1:${toString cfg.port}";
        ExecStop = "${config.services.tailscale.package}/bin/tailscale serve --https=${toString servePort} off";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
