{ config, ... }:

{
  services = {
    greetd = {
      enable = true;
      settings.default_session = {
        user = "schlich";
        command = "${config.programs.niri.package}/bin/niri-session";
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
