{ config, pkgs, lib, ... }:

{
  # Niri wayland compositor configuration
  # This module should only be imported on native Linux systems (not WSL)

  home.packages = with pkgs; [
    niri
    waybar
    fuzzel  # Application launcher
    mako    # Notification daemon
    swaylock
    swayidle
    grim    # Screenshot
    slurp   # Screen area selection
    wl-clipboard
    xwayland-satellite  # For X11 apps
  ];

  # XDG portal configuration for niri
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gnome pkgs.xdg-desktop-portal-gtk ];
    config.common.default = "*";
  };

  # Niri configuration will go in ~/.config/niri/config.kdl
  # You can manage it via home.file if needed
  # home.file.".config/niri/config.kdl".source = ./niri/config.kdl;

  # Session variables for Wayland
  home.sessionVariables = {
    NIXOS_OZONE_WL = "1";  # Enable Wayland for Electron apps
    MOZ_ENABLE_WAYLAND = "1";  # Enable Wayland for Firefox
  };

  # Services that should run with niri
  services = {
    mako.enable = true;  # Notification daemon
  };
}
