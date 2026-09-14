{ config, pkgs, ... }:

{
  boot.loader = {
    efi.canTouchEfiVariables = true;
    limine = {
      enable = true;
      efiSupport = true;
      maxGenerations = 3;
      biosSupport = false;
      extraEntries = ''
        /Windows
          comment: Boot the existing Windows Boot Manager EFI entry
          protocol: efi_boot_entry
          entry: Windows Boot Manager
      '';
    };
  };

  networking.hostName = "asus";
  networking.networkmanager = {
    enable = true;
  };
  networking.firewall.allowedTCPPorts = [ 8080 ];
  system.stateVersion = "26.05";
}
