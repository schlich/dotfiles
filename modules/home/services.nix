{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  xs = inputs.xs.packages.${pkgs.stdenv.hostPlatform.system}.default;
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
  pushBackgroundTasks = pkgs.writeNuScriptBin "push-background-tasks" (
    builtins.readFile ../../agent-monitor/push-background-tasks.nu
  );
  udiskie = wrapWithConfig {
    package = pkgs.udiskie;
    flags = [
      "--config"
      ((pkgs.formats.yaml { }).generate "udiskie-config.yml" {
        program_options = {
          automount = true;
          notify = true;
          tray = "auto";
        };
      })
    ];
  };
in

{
  services = {
    home-manager.autoUpgrade.useFlake = true;
    gpg-agent = {
      enable = true;
      enableNushellIntegration = true;
    };
    gnome-keyring.enable = true;
    # The module still writes the unit, whose tray.target dependency follows
    # `tray`; the wrapper carries the configuration it would link.
    udiskie = {
      enable = true;
      package = udiskie;
      tray = "auto";
    };
  };
  xdg.configFile."udiskie/config.yml".enable = lib.mkForce false;
  dotfiles.retiredHomeFiles = [ ".config/udiskie/config.yml" ];

  systemd.user.services.cross-stream = {
    Unit = {
      Description = "cross.stream event store";
    };
    Service = {
      ExecStart = "${xs}/bin/xs serve %h/.local/share/cross.stream/store";
      Environment = [
        "PATH=${config.home.profileDirectory}/bin:${pkgs.nushell}/bin:${pkgs.coreutils}/bin:/run/current-system/sw/bin"
      ];
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.cross-stream-bootstrap = {
    Unit = {
      Description = "Register terminal triage actor with cross.stream";
      After = [ "cross-stream.service" ];
      Requires = [ "cross-stream.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.nushell}/bin/nu ${../../mcp/xs-bootstrap.nu} %h/.local/share/cross.stream/store";
      RemainAfterExit = true;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.opencode-server = {
    Unit = {
      Description = "OpenCode HTTP server";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # Give up after five failed starts in five minutes instead of retrying
      # a persistent failure forever; `systemctl --user restart` clears it.
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    Service = {
      ExecStart = "${config.programs.opencode.package}/bin/opencode serve --hostname 127.0.0.1 --port 4096";
      Environment = [ "SECRETSPEC_REASON=OpenCode server service" ];
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Copies this workstation's Claude Code background tasks to the homelab
  # Fieldnotes wallpaper. The background-tasks hook (claude-code.nix) also
  # starts this unit, so a new task appears within seconds; the timer notices
  # finished tasks and keeps homelab's copy fresh.
  systemd.user.services.agent-tasks-push = {
    Unit.Description = "Copy Claude Code background tasks to the homelab wallpaper";
    Service = {
      Type = "oneshot";
      ExecStart = "${pushBackgroundTasks}/bin/push-background-tasks --target homelab";
      # A oneshot has no start timeout by default, and the timer schedules
      # the next run only after this one ends, so one hung run would stop
      # every later update. A run takes about 10s to scan /proc and gives up
      # on homelab within 25s.
      TimeoutStartSec = "2min";
      Environment = [
        "PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            # Its configuration carries the homelab host block.
            (import ../programs/ssh-client.nix { inherit lib pkgs; })
          ]
        }"
        "SSH_AUTH_SOCK=%t/gcr/ssh"
      ];
    };
  };
  systemd.user.timers.agent-tasks-push = {
    Unit.Description = "Refresh the homelab wallpaper's Claude Code background tasks";
    Timer = {
      OnStartupSec = "30s";
      OnUnitActiveSec = "20s";
      AccuracySec = "1s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Give the default speaker output a modest boost after PipeWire is ready.
  systemd.user.services.audio-output-boost = {
    Unit = {
      Description = "Set a slightly louder default audio output";
      After = [
        "pipewire.service"
        "pipewire-pulse.service"
        "wireplumber.service"
      ];
      Wants = [
        "pipewire.service"
        "pipewire-pulse.service"
        "wireplumber.service"
      ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.05";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
