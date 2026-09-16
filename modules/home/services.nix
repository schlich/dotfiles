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
}
