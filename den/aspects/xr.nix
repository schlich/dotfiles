{ config, ... }:
{
  den.aspects.xr = {
    meta = config.myConfig.aspectPolicy.xr;
    nixos =
      { pkgs, ... }:
      {
        # WiVRn streams OpenXR to a standalone headset; wayvr brings the
        # Wayland desktop into that session.
        services.wivrn = {
          enable = true;
          autoStart = true;
          openFirewall = true;
        };
        hardware.uinput.enable = true;
        users.users.schlich.extraGroups = [ "uinput" ];
        environment.systemPackages = [ pkgs.wayvr ];
      };
  };
}
