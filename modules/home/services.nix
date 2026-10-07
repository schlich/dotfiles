{
  config,
  inputs,
  pkgs,
  ...
}:

let
  xs = inputs.xs.packages.${pkgs.stdenv.hostPlatform.system}.default;
in

{
  services = {
    home-manager.autoUpgrade.useFlake = true;
    gpg-agent = {
      enable = true;
      enableNushellIntegration = true;
    };
    gnome-keyring.enable = true;
    udiskie = {
      enable = true;
      automount = true;
      notify = true;
      tray = "auto";
    };
  };

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
