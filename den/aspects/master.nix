{
  config,
  den,
  lib,
  ...
}:
{
  den.aspects.master = {
    meta = config.myConfig.aspectPolicy.master;
    includes = [
      (
        { host }:
        {
          includes = [
            (
              if host.profile.role == "workstation" then
                den.aspects.workstation
              else if host.profile.role == "server" then
                den.aspects.server
              else
                den.aspects.wsl
            )
            (
              if host.profile.platform == "asus" then den.aspects.asus-platform else den.aspects.homelab-platform
            )
          ]
          ++ lib.optionals (host.profile.role == "server") [ den.aspects.headless ]
          ++ lib.optionals (host.profile.desktop == "niri") [ den.aspects.desktop-niri ]
          ++ lib.optionals host.profile.portable [ den.aspects.laptop ]
          ++ lib.optionals host.profile.development [ den.aspects.development ]
          ++ lib.optionals host.profile.remote [ den.aspects.remote ]
          ++ lib.optionals host.profile.xr [ den.aspects.xr ]
          ++ lib.optionals (host.profile.gpu == "amd") [ den.aspects.gpu-amd ]
          ++ lib.optionals host.profile.secrets [ den.aspects.secrets ]
          ++ lib.optionals (host.profile.platform == "asus" && host.profile.storage == "internal") [
            den.aspects.asus-storage
          ]
          ++ lib.optionals (host.profile.platform == "asus" && host.profile.storage == "usb") [
            den.aspects.asus-usb-hardware
          ];
        }
      )
    ];
  };

  den.schema.host.includes = [ den.aspects.master ];
}
