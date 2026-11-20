{ ... }:

{
  system.nixos.tags = [ "asus" ];

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

  # HEX's Wayland hotkeys read every /dev/input/event* node, which exposes all
  # keyboard input to processes running as this user (modules/programs/desktop/hex.nix).
  users.users.schlich.extraGroups = [ "input" ];

  # The Realtek Bluetooth controller (USB 13d3:3556) gets reset by xHCI
  # ("invalid context state") while autosuspended, and the MX Master 3S then
  # fails to reconnect until it is paired again under a new address.
  boot.extraModprobeConfig = ''
    options btusb enable_autosuspend=n
  '';

  networking.hostName = "asus";
  networking.networkmanager = {
    enable = true;
  };
  networking.firewall.allowedTCPPorts = [ 8080 ];
  system.stateVersion = "26.05";
}
