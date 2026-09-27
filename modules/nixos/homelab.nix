{ pkgs, ... }:

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
}
