{ config, lib, ... }:

let
  persistent = config.impermanence.enable;
  btrfsUuid = "27a94ece-bfea-4870-ac2e-6723e07db334";
  btrfsDevice = "/dev/disk/by-uuid/${btrfsUuid}";
  btrfsOptions = [
    "compress=zstd:3"
    "discard=async"
    "noatime"
  ];
in
{
  imports = [
    ./hardware-common.nix
    ./impermanence.nix
  ];

  # Off until `persist-migrate` has filled @persist; see impermanence.nix.
  impermanence = {
    enable = false;
    wipe = false;
  };

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
      # The bind mounts into /home are set up during activation.
      neededForBoot = persistent;
    };
    "/persist" = lib.mkIf persistent {
      device = btrfsDevice;
      fsType = "btrfs";
      options = btrfsOptions ++ [ "subvol=@persist" ];
      neededForBoot = true;
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
      neededForBoot = persistent;
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
    # The swapfile's own subvolume: btrfs cannot snapshot a subvolume holding
    # an active swapfile, and a top-level one stays out of @root's snapshots
    # and the impermanence wipe. Swapfiles are NOCOW, so compression does not
    # apply. `nofail` keeps the machine booting without swap if @swap is
    # missing.
    "/swap" = {
      device = btrfsDevice;
      fsType = "btrfs";
      options = [
        "subvol=@swap"
        "noatime"
        "nofail"
      ];
    };
  };

  # Disk-backed swap inside the LUKS volume, with zswap compressing pages in
  # RAM in front of it. zram held every swapped page in RAM with no way out,
  # so cold pages from idle agent sessions filled it and systemd-oomd killed
  # the Claude app; the Seagate swapfile is absent whenever that drive is
  # unplugged. zswap writes its coldest pages through to this file instead.
  boot.zswap.enable = true;

  swapDevices = [
    {
      device = "/swap/swapfile";
      size = 16 * 1024;
    }
  ];
}
