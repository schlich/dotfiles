{
  config,
  den,
  inputs,
  ...
}:
{
  den.aspects.workstation = {
    meta = config.myConfig.aspectPolicy.workstation;
    includes = [
      den.aspects.base
      den.aspects.paseo
    ];
    nixos =
      { pkgs, ... }:
      {
        imports = [
          ../../modules/nixos/codex.nix
          ../../modules/nixos/docker.nix
        ];
        nixpkgs.overlays = [
          inputs.jj-starship.overlays.default
          inputs.nushellWith.overlays.default
        ];
        environment.systemPackages = [
          inputs.fh.packages.x86_64-linux.default
          pkgs.jj-starship
        ];
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "hm-backup";
          extraSpecialArgs = { inherit inputs; };
        };
      };
  };

  den.aspects.jj-ci-webhook = {
    meta = config.myConfig.aspectPolicy.workstation;
    nixos = {
      imports = [ ../../modules/nixos/jj-ci-webhook.nix ];
      services.jj-ci-webhook = {
        enable = true;
        funnel.enable = true;
      };
    };
  };
}
