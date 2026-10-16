{ den, lib, ... }:
let
  profileTools = import ./profile.nix { inherit lib; };

  # Every host is composed the same way: its profile's behavior aspects, with
  # host services kept right after the first one (base or workstation) so
  # package order stays stable, then what every host needs, then its
  # platform. Hardware and storage remain platform-local.
  hostIncludes =
    name:
    {
      services ? [ ],
      platform,
    }:
    let
      behavior = map (aspect: den.aspects.${aspect}) (
        profileTools.behaviorAspects den.hosts.x86_64-linux.${name}.profile
      );
    in
    [ (builtins.head behavior) ]
    ++ services
    ++ builtins.tail behavior
    ++ [
      den.aspects.system-files
      den.aspects.deploy-policy
      den.aspects.fleet-network
    ]
    ++ platform;
in

{
  den.aspects.asus.includes = hostIncludes "asus" {
    services = [
      den.aspects.jj-ci-webhook
      den.aspects.nix-observability
    ];
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
    services = [
      den.aspects.paseo
      den.aspects.opencode-server
      den.aspects.cross-stream
    ];
    platform = [ den.aspects.homelab-platform ];
  };

  den.schema.user.classes = lib.mkDefault [ "user" ];
}
