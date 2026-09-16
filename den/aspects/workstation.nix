{
  config,
  den,
  inputs,
  ...
}:
{
  den.aspects.workstation = {
    meta = config.myConfig.aspectPolicy.workstation;
    includes = [ den.aspects.base ];
    nixos =
      { pkgs, ... }:
      {
        imports = [
          ../../modules/nixos/workstation.nix
          ../../modules/nixos/codex.nix
          ../../modules/nixos/docker.nix
          ../../modules/nixos/jj-ci-webhook.nix
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
}
