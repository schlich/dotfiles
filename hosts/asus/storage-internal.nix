{ ... }:

let
  btrfsUuid = "27a94ece-bfea-4870-ac2e-6723e07db334";
  btrfsDevice = "/dev/disk/by-uuid/${btrfsUuid}";
  btrfsOptions = [
    "compress=zstd:3"
    "discard=async"
    "noatime"
  ];
in
{
  imports = [ ./hardware-common.nix ];

  boot.loader.limine.efiInstallAsRemovable = false;

  boot.initrd = {
    systemd.enable = true;
    luks.devices.nixos-root = {
      allowDiscards = true;
      crypttabExtraOpts = [ "tpm2-device=auto" ];
      device = "/dev/disk/by-uuid/fcad07cd-274e-4cc6-99a5-b285bf647626";
    };
  };

  fileSystems = {
    "/" = {
      device = btrfsDevice;
      fsType = "btrfs";
      options = btrfsOptions ++ [ "subvol=@root" ];
    };
    "/home" = {
      device = btrfsDevice;
      fsType = "btrfs";
      options = btrfsOptions ++ [ "subvol=@home" ];
    };
    "/nix" = {
      device = btrfsDevice;
      fsType = "btrfs";
      options = btrfsOptions ++ [ "subvol=@nix" ];
    };
    "/var/log" = {
      device = btrfsDevice;
      fsType = "btrfs";
      options = btrfsOptions ++ [ "subvol=@log" ];
    };
    "/.snapshots" = {
      device = btrfsDevice;
      fsType = "btrfs";
      options = btrfsOptions ++ [ "subvol=@snapshots" ];
    };
    "/boot" = {
      device = "/dev/disk/by-uuid/A0C1-2EDF";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
    "/mnt/usb-root" = {
      device = "/dev/disk/by-uuid/b1409dcc-54c2-4f90-8712-3c52aff50c20";
      fsType = "ext4";
      options = [
        "ro"
        "noauto"
        "nofail"
        "x-systemd.automount"
        "x-systemd.device-timeout=1s"
      ];
    };
    "/mnt/seagate" = {
      device = "/dev/disk/by-uuid/53aa40c5-dd3c-4372-8280-8c0c61b15b02";
      fsType = "ext4";
      options = [
        "nofail"
        "x-systemd.device-timeout=5s"
      ];
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
    priority = 100;
  };

  swapDevices = [
    {
      device = "/mnt/seagate/.nixos-swapfile";
      size = 8 * 1024;
      priority = 10;
    }
  ];
}
