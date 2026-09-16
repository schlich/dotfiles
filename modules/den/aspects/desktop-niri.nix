{
  config,
  inputs,
  ...
}:
{
  den.aspects.desktop-niri = {
    meta = config.myConfig.aspectPolicy.desktop-niri;
    nixos =
      { config, ... }:
      {
        imports = [
          inputs.noctalia-greeter.nixosModules.default
          inputs.niri.nixosModules.niri
          ../../../modules/nixos/desktop.nix
        ];
        assertions = [
          {
            assertion = config.programs.niri.enable;
            message = "desktop=niri requires the Niri session module.";
          }
        ];
      };
  };
}
