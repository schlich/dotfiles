{
  config,
  inputs,
  pkgs,
  ...
}:

let
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJRdPuDm1hX5iOgHNl63aUVPIUvkMhAFlBaoxOiSPEA schlich@tangled";

  wallpaperMonitor = pkgs.writeShellApplication {
    name = "agent-wallpaper";
    runtimeInputs = [
      pkgs.python3
      pkgs.gh
      inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
    text = ''
      exec python3 ${../../agent-monitor/wallpaper.py}
    '';
  };

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
  users.users.schlich.openssh.authorizedKeys.keys = [ adminKey ];

  # sudo also accepts that key from a forwarded SSH agent and falls back to the
  # password without one. Its root-owned key list is separate from SSH logins,
  # so a new login key does not also grant sudo.
  security.pam = {
    sshAgentAuth = {
      enable = true;
      authorizedKeysFiles = [ "/etc/ssh/sudo_authorized_keys" ];
    };
    services.sudo.sshAgentAuth = true;
  };
  # A copy, not a store symlink: pam_ssh_agent_auth rejects a key file under
  # a group-writable directory, which /nix/store is.
  environment.etc."ssh/sudo_authorized_keys" = {
    mode = "0444";
    text = ''
      ${adminKey}
    '';
  };

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

  # Render live agent usage and CI status on the background layer. Windows tile
  # above it, and it takes no keyboard focus.
  systemd.user.services.desktop-monitor = {
    description = "Live agent usage and CI wallpaper";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.kitty}/bin/kitten panel --edge=background ${wallpaperMonitor}/bin/agent-wallpaper";
      Environment = [ "FIELDNOTES_CI_REPO=schlich/dotfiles" ];
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
