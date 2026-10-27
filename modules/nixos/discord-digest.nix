# discord-digest (tools/discord-digest): once a day, read the new messages
# in the owner's Discord channels, have Claude pick out what is worth their
# time, and render a static dashboard. A loopback static server holds the
# dashboard and Tailscale Serve publishes it, so only tailnet devices reach
# it.
#
# It reads Discord with the owner's user token, which makes it a self-bot;
# Discord's terms forbid that, and the account risks a ban. The client only
# reads, paces its requests, and honours rate limits.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkOption types;
  cfg = config.services.discord-digest;
  package = pkgs.callPackage ../../tools/discord-digest/package.nix { };
  stateDir = "/var/lib/discord-digest";
  toml = pkgs.formats.toml { };
  configFile = toml.generate "discord-digest.toml" (
    {
      data_dir = stateDir;
      interests_file = "${cfg.interestsFile}";
    }
    // cfg.settings
  );
  servePort = config.dotfiles.tailscale.https.discord-digest.port;
in
{
  imports = [ ./tailscale-https.nix ];

  options.services.discord-digest = {
    enable = mkEnableOption "the daily Discord digest";

    environmentFile = mkOption {
      type = types.path;
      description = ''
        File with DISCORD_TOKEN= and ANTHROPIC_API_KEY= lines, read by
        systemd before the run drops privileges. Keep it out of the store.
      '';
    };

    interestsFile = mkOption {
      type = types.path;
      default = ../../tools/discord-digest/interests.md;
      description = "What triage scores each message against.";
    };

    settings = mkOption {
      inherit (toml) type;
      default = { };
      description = "Keys of discord-digest's config.toml (tools/discord-digest/config.example.toml).";
    };

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 06:00:00";
      description = "When the digest runs, as a systemd OnCalendar expression.";
    };

    port = mkOption {
      type = types.port;
      default = 8765;
      description = "Loopback port of the dashboard's static server.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.discord-digest = {
      isSystemUser = true;
      group = "discord-digest";
      home = stateDir;
    };
    users.groups.discord-digest = { };

    systemd.services.discord-digest = {
      description = "Read new Discord messages and render the digest";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "discord-digest";
        Group = "discord-digest";
        StateDirectory = "discord-digest";
        StateDirectoryMode = "0750";
        EnvironmentFile = cfg.environmentFile;
        ExecStart = "${lib.getExe package} --config ${configFile} run";
        # Reading ~100 channels at a polite pace takes minutes, not hours.
        TimeoutStartSec = "2h";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    systemd.timers.discord-digest = {
      description = "Daily Discord digest";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        # A run missed while homelab was off happens at the next boot.
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 discord-digest discord-digest -"
      "d ${stateDir}/site 0750 discord-digest discord-digest -"
    ];

    systemd.services.discord-digest-site = {
      description = "Serve the Discord digest dashboard on loopback";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "discord-digest";
        Group = "discord-digest";
        ExecStart = "${lib.getExe pkgs.static-web-server} --host 127.0.0.1 --port ${toString cfg.port} --root ${stateDir}/site";
        Restart = "on-failure";
        RestartSec = "5s";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = [ stateDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # Tailscale Serve, not Funnel: only tailnet devices reach the dashboard.
    dotfiles.tailscale.https.discord-digest.port = lib.mkDefault 7443;

    systemd.services.discord-digest-serve = {
      description = "Publish the Discord digest dashboard privately on the tailnet";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "discord-digest-site.service"
        "tailscaled.service"
      ];
      after = [
        "discord-digest-site.service"
        "tailscaled.service"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.tailscale}/bin/tailscale serve --https=${toString servePort} http://127.0.0.1:${toString cfg.port}";
        ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=${toString servePort} off";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
