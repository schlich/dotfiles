{ ... }:

{
  services = {
    power-profiles-daemon.enable = true;
    upower.enable = true;
  };

  programs = {
    niri = {
      enable = true;
    };
    noctalia.enable = true;
  };

  services.displayManager.noctalia-greeter.enable = true;
}
