{ config, ... }:
{
  den.aspects.xr = {
    meta = config.myConfig.aspectPolicy.xr;
    nixos =
      { config, ... }:
      {
        assertions = [
          {
            assertion = config.programs.immersed.enable;
            message = "The XR aspect requires the existing Immersed integration.";
          }
        ];
      };
  };
}
