{ den, lib, ... }:

{
  # Hosts are small composition declarations. Hardware and storage remain
  # platform-local; reusable behavior is selected explicitly here.
  den.aspects.asus.includes = [
    den.aspects.workstation
    den.aspects.system-files
    den.aspects.desktop-niri
    den.aspects.laptop
    den.aspects.development
    den.aspects.remote
    den.aspects.xr
    den.aspects.gpu-amd
    den.aspects.asus-platform
    den.aspects.asus-storage
  ];

  den.aspects.asus-headless.includes = [
    den.aspects.base
    den.aspects.server
    den.aspects.headless
    den.aspects.system-files
    den.aspects.asus-platform
    den.aspects.asus-storage
  ];

  den.aspects.asus-usb.includes = [
    den.aspects.workstation
    den.aspects.system-files
    den.aspects.desktop-niri
    den.aspects.laptop
    den.aspects.development
    den.aspects.remote
    den.aspects.xr
    den.aspects.gpu-amd
    den.aspects.asus-platform
    den.aspects.asus-usb-hardware
  ];

  den.aspects.homelab.includes = [
    den.aspects.base
    den.aspects.paseo
    den.aspects.opencode-server
    den.aspects.server
    den.aspects.headless
    den.aspects.system-files
    den.aspects.remote
    den.aspects.homelab-platform
  ];

  den.schema.user.classes = lib.mkDefault [ "user" ];
}
