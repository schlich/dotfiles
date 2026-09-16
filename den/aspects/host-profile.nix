{
  config,
  den,
  lib,
  ...
}:
{
  den.aspects.host-profile = {
    meta = config.myConfig.aspectPolicy.host-profile;
    includes = [
      (
        { host }:
        let
          platform = builtins.getAttr host.profile.platform den.aspects.platforms;
          storage = builtins.getAttr "${host.profile.platform}-${host.profile.storage}" den.aspects.storage;
        in
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
            platform
            storage
          ]
          ++ lib.optionals (host.profile.role == "server") [ den.aspects.headless ]
          ++ lib.optionals (host.profile.platform == "homelab") [ den.aspects.homelab ]
          ++ lib.optionals (host.profile.desktop == "niri") [ den.aspects.desktop-niri ]
          ++ lib.optionals (host.profile.desktop == "niri") [ den.aspects.input-stack ]
          ++ lib.optionals host.profile.portable [ den.aspects.laptop ]
          ++ lib.optionals host.profile.development [ den.aspects.development ]
          ++ lib.optionals host.profile.remote [ den.aspects.remote ]
          ++ lib.optionals host.profile.xr [ den.aspects.xr ]
          ++ lib.optionals (host.profile.gpu == "amd") [ den.aspects.gpu-amd ]
          ++ lib.optionals host.profile.secrets [ den.aspects.secrets ];
        }
      )
    ];
  };

  den.schema.host.includes = [ den.aspects.host-profile ];
}
