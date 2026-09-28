{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The live system monitor drawn as the desktop wallpaper. Use
  # `lib.getExe pkgs.htop` to show htop instead.
  wallpaperMonitor = lib.getExe pkgs.bottom;

  # Niri's own default config, minus its waybar autostart: homelab has no
  # waybar, and the desktop session instead starts the monitor wallpaper.
  niriConfig = pkgs.runCommand "niri-homelab-config.kdl" { } ''
    substitute ${config.programs.niri.package.src}/resources/default-config.kdl $out \
      --replace-fail 'spawn-at-startup "waybar"' '// The monitor wallpaper starts as a systemd user service.'
  '';
in
{
  networking.hostName = "homelab";
  networking.networkmanager.enable = true;

  # Allow the administrator's existing client key to log in over the private
  # LAN or Tailscale address. Only the public key is stored in the repository.
  users.users.schlich.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJRdPuDm1hX5iOgHNl63aUVPIUvkMhAFlBaoxOiSPEA schlich@tangled"
  ];

  # Keep the machine running when its broken lid is closed or a power key is
  # pressed. A long hardware power-button hold remains an emergency shutdown.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
  };

  # Remote access should stay on the private LAN/Tailscale network; do not
  # expose SSH through the router.
  services.tailscale.enable = true;

  environment.systemPackages = with pkgs; [
    btop
    helix
    smartmontools
    tmux
    # homelab has no Home Manager Niri config, so Niri's built-in defaults
    # bind these as its terminal and launcher.
    alacritty
    fuzzel
  ];

  # homelab has no Home Manager, so Niri reads this system-wide config.
  environment.etc."niri/config.kdl".source = niriConfig;

  # Render a live system monitor on the background layer in place of a static
  # wallpaper. Windows tile above it, and it takes no keyboard focus.
  systemd.user.services.desktop-monitor = {
    description = "Live system monitor wallpaper";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.kitty}/bin/kitten panel --edge=background ${wallpaperMonitor}";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
