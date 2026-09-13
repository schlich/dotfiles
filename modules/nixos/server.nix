{ pkgs, ... }:

{
  boot = {
    kernelModules = [ "kvm-amd" ];
  };

  networking = {
    hostName = "homelab";
    networkmanager.enable = true;
    firewall = {
      enable = true;
      trustedInterfaces = [ "tailscale0" ];
    };
  };

  services = {
    dbus.implementation = "broker";
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ "schlich" ];
      };
    };
    tailscale.enable = true;
    smartd.enable = true;
    logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
      HandlePowerKey = "ignore";
      HandleSuspendKey = "ignore";
      HandleHibernateKey = "ignore";
    };
  };

  environment.systemPackages = with pkgs; [
    btop
    git
    helix
    jq
    nushell
    smartmontools
    tmux
  ];

  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
    settings = {
      auto-optimise-store = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "schlich" ];
    };
  };

  nixpkgs.config.allowUnfree = true;
  hardware.enableAllFirmware = true;
  security.polkit.enable = true;
  time.timeZone = "America/Chicago";
  system.stateVersion = "26.05";

  users.defaultUserShell = pkgs.nushell;
  users.users.schlich = {
    uid = 1001;
    shell = pkgs.nushell;
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };
  environment.shells = [ pkgs.nushell ];
}
