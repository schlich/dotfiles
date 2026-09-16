{ pkgs, ... }:

{
  environment.systemPackages = [ pkgs.google-chrome ];

  services = {
    udisks2.enable = true;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General.Experimental = true;
  };

  programs.immersed.enable = true;
  xdg = {
    portal = {
      enable = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-gtk
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-termfilechooser
      ];
      # Niri/Noctalia does not provide a portal configuration of its own. Without
      # an explicit choice, the GNOME backend wins FileChooser requests and then
      # fails while delegating them to a GNOME service that is not installed.
      config.common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
      };
    };
    autostart.enable = true;
  };
}
