{ config, ... }:
{
  den.aspects.asus-platform = {
    meta = config.myConfig.aspectPolicy.storage;
    nixos.imports = [ ../../hosts/asus/default.nix ];
  };

  den.aspects.asus-storage = {
    meta = config.myConfig.aspectPolicy.storage;
    nixos.imports = [ ../../hosts/asus/storage-internal.nix ];
  };

  den.aspects.asus-usb-hardware = {
    meta = config.myConfig.aspectPolicy.storage;
    nixos.imports = [ ../../hosts/asus/hardware-configuration.nix ];
  };

  den.aspects.homelab-platform = {
    meta = config.myConfig.aspectPolicy.server;
    nixos.imports = [
      ../../hosts/homelab/default.nix
      ../../modules/nixos/homelab.nix
    ];
  };

  den.aspects.headless = {
    meta = config.myConfig.aspectPolicy.server;
    nixos.imports = [ ../../modules/nixos/headless.nix ];
  };
}
