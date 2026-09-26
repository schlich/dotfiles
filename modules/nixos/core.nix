{ pkgs, ... }:

{
  nix = {
    registry.templates.to = {
      type = "github";
      owner = "denful";
      repo = "den";
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
    settings = {
      # Allow two medium-sized builds to make use of the workstation without
      # letting a rebuild consume every available resource at once.
      max-jobs = 2;
      cores = 4;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "schlich" ];
      # Yazelix publishes builds of its pinned Rio, Helix, and Zellij forks.
      extra-substituters = [ "https://yazelix.cachix.org" ];
      extra-trusted-public-keys = [
        "yazelix.cachix.org-1:ZgxIjQvaP0VTWL8Racx27mpUNzDJ97xC2y7QWYjmGNM="
      ];
    };
  };
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = [ pkgs.git ];

  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  services.dbus.implementation = "broker";
  hardware.enableAllFirmware = true;
  programs.nix-ld.enable = true;
  security.polkit.enable = true;
}
