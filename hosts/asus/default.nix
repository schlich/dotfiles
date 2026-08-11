{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot.loader = {
    efi.canTouchEfiVariables = true;
    limine = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      maxGenerations = 10;
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
  services.kmonad = {
    enable = true;
    keyboards.myKMonadOutput = {
      device = "/dev/input/by-id/usb-ROYUAN_ROYALAXE_R100-event-kbd";
      config = builtins.readFile ../../system/kmonad.kbd;
    };
  };

  system.stateVersion = "26.05";
}
