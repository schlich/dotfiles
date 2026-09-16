{ config, ... }:
{
  den.aspects.platforms = {
    provides.asus = {
      meta = config.myConfig.aspectPolicy.host-profile;
      nixos.imports = [ ../../hosts/asus/default.nix ];
    };

    provides.homelab = {
      meta = config.myConfig.aspectPolicy.host-profile;
      nixos.imports = [ ../../hosts/homelab/default.nix ];
    };
  };

  den.aspects.storage = {
    provides."asus-internal" = {
      meta = config.myConfig.aspectPolicy.storage;
      nixos.imports = [ ../../hosts/asus/storage-internal.nix ];
    };

    provides."asus-usb" = {
      meta = config.myConfig.aspectPolicy.storage;
      nixos.imports = [ ../../hosts/asus/hardware-configuration.nix ];
    };

    # Homelab storage is fully described by its platform hardware module.
    provides."homelab-internal" = {
      meta = config.myConfig.aspectPolicy.storage;
    };
  };

  den.aspects.headless = {
    meta = config.myConfig.aspectPolicy.server;
    nixos.imports = [ ../../modules/nixos/headless.nix ];
  };
}
