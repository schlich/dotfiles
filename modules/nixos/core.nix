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
    };
  };
  # Builds run in the daemon's cgroup. Cap it so a large build is killed
  # instead of thrashing the whole machine; zram swap is backed by RAM, so
  # bound swap too. `continue` fails only the killed build, not the daemon.
  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "60%";
    MemoryMax = "75%";
    MemorySwapMax = "4G";
    OOMPolicy = "continue";
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

  # One JSON line per activation, so `ci verify` can say when the running
  # toplevel was switched to and from which system profile generation. It
  # never leaves the host; only verifications are sent to homelab.
  system.activationScripts.record-activation.text = ''
    ${pkgs.coreutils}/bin/printf '{"time":"%s","toplevel":"%s","profile":"%s"}\n' \
      "$(${pkgs.coreutils}/bin/date --iso-8601=seconds)" \
      "$systemConfig" \
      "$(${pkgs.coreutils}/bin/readlink /nix/var/nix/profiles/system || true)" \
      >> /var/log/nixos-activations.jsonl
  '';

  services.dbus.implementation = "broker";
  hardware.enableAllFirmware = true;
  programs.nix-ld.enable = true;
  security.polkit.enable = true;
}
