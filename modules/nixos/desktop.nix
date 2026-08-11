{ ... }:

{
  services = {
    power-profiles-daemon.enable = true;
    upower.enable = true;
  };

  programs = {
    niri.enable = true;
    noctalia.enable = true;
    noctalia-greeter.enable = true;
  };
  systemd.user.services.niri.enableDefaultPath = false;
}
