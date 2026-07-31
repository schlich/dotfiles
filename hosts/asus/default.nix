{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot.loader = {
    efi.canTouchEfiVariables = false;
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

  networking.wireless = {
    enable = true;
    networks."EvilCorp HQ".pskRaw = "37660d09044c0b74085b1604031b4a8ac965ed1bb10b07a5a2f797402ea10bd7";
  };

  services.kmonad = {
    enable = true;
    keyboards.myKMonadOutput = {
      device = "/dev/input/by-id/usb-ROYUAN_ROYALAXE_R100-event-kbd";
      config = builtins.readFile ../../system/kmonad.kbd;
    };
  };

  system.stateVersion = "26.05";
}
