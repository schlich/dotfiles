{ den, lib, ... }:
let
  profileTools = import ./profile.nix { inherit lib; };

  # Every host is composed the same way: the aspects its profile and
  # services facts select (den/profile.nix), then what every host needs,
  # then its platform. Hardware and storage remain platform-local.
  hostIncludes =
    name:
    { platform }:
    map (aspect: den.aspects.${aspect}) (profileTools.hostAspects den.hosts.x86_64-linux.${name})
    ++ [
      den.aspects.system-files
      den.aspects.deploy-policy
      den.aspects.fleet-network
    ]
    ++ platform;
in

{
  den.aspects.asus.includes = hostIncludes "asus" {
    platform = [
      den.aspects.asus-platform
      den.aspects.asus-storage
    ];
  };

  den.aspects.asus-headless.includes = hostIncludes "asus-headless" {
    platform = [
      den.aspects.asus-platform
      den.aspects.asus-storage
    ];
  };

  den.aspects.asus-usb.includes = hostIncludes "asus-usb" {
    platform = [
      den.aspects.asus-platform
      den.aspects.asus-usb-hardware
    ];
  };

  den.aspects.homelab.includes = hostIncludes "homelab" {
    platform = [ den.aspects.homelab-platform ];
  };

  den.schema.user.classes = lib.mkDefault [ "user" ];
}
