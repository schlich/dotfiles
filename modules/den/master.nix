{
  den,
  lib,
  ...
}:
{
  den.aspects.master =
    { host, ... }:
    let
      profile = host.profile;
    in
    {
      description = "Resolve reusable capabilities from typed host facts.";
      includes =
        (
          if profile.role == "workstation" then
            [ den.aspects.workstation ]
          else if profile.role == "wsl" then
            [ den.aspects.wsl ]
          else
            [ den.aspects.server ]
        )
        ++ [ den.aspects.system-files ]
        ++ lib.optionals (profile.desktop == "niri") [ den.aspects.desktop-niri ]
        ++ lib.optionals profile.portable [ den.aspects.laptop ]
        ++ lib.optionals profile.development [ den.aspects.development ]
        ++ lib.optionals profile.xr [ den.aspects.xr ]
        ++ lib.optionals profile.secrets [ den.aspects.secrets ]
        ++ lib.optionals profile.remote [ den.aspects.remote ]
        ++ lib.optionals (profile.gpu == "amd") [ den.aspects.gpu-amd ];
    };

  den.aspects.asus.includes = [
    den.aspects.master
    den.aspects.asus-platform
    den.aspects.asus-storage
  ];
  den.aspects.asus-headless.includes = [
    den.aspects.master
    den.aspects.asus-platform
    den.aspects.asus-storage
  ];
  den.aspects.asus-usb.includes = [
    den.aspects.master
    den.aspects.asus-platform
    den.aspects.asus-usb-hardware
  ];
  den.aspects.homelab.includes = [
    den.aspects.master
    den.aspects.homelab-platform
  ];

  den.schema.user.classes = lib.mkDefault [ "user" ];
}
