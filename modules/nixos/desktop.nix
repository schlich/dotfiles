{ config, pkgs, ... }:

{
  services = {
    greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --cmd ${config.programs.niri.package}/bin/niri-session";
        user = "greeter";
      };
    };
    power-profiles-daemon.enable = true;
    upower.enable = true;
  };

  programs = {
    niri.enable = true;
    noctalia.enable = true;
  };
  systemd.user.services.niri.enableDefaultPath = false;
}
