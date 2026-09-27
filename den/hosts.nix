{ den, lib, ... }:
let
  profileTools = import ./profile.nix { inherit lib; };
  aspectsFor = host: map (name: den.aspects.${name}) (profileTools.behaviorAspects host.profile);
  host = name: den.hosts.x86_64-linux.${name};
in

{
  # Hosts are small composition declarations. Hardware and storage remain
  # platform-local; reusable behavior follows the host's typed profile.
  den.aspects.asus.includes = aspectsFor (host "asus") ++ [
    den.aspects.jj-ci-webhook
    den.aspects.system-files
    den.aspects.asus-platform
    den.aspects.asus-storage
  ];

  den.aspects.asus-headless.includes = aspectsFor (host "asus-headless") ++ [
    den.aspects.system-files
    den.aspects.asus-platform
    den.aspects.asus-storage
  ];

  den.aspects.asus-usb.includes = aspectsFor (host "asus-usb") ++ [
    den.aspects.system-files
    den.aspects.asus-platform
    den.aspects.asus-usb-hardware
  ];

  den.aspects.homelab.includes =
    let
      behavior = aspectsFor (host "homelab");
    in
    # Keep the service aspects right after base so package order stays stable.
    [
      (builtins.head behavior)
      den.aspects.paseo
      den.aspects.opencode-server
    ]
    ++ builtins.tail behavior
    ++ [
      den.aspects.system-files
      den.aspects.homelab-platform
    ];

  den.schema.user.classes = lib.mkDefault [ "user" ];
}
