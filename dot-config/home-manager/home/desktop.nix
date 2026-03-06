{ pkgs, ... }: {
  imports = [ ./default.nix ];

  # Niri and GUI-related HM configuration
  home.packages = with pkgs; [
    waybar
    mako
    swaybg
    swaylock-effects
    foot
  ];

  # You can move niri settings here if you use the HM module
  # programs.niri.enable = true;
}
