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
        # den/aspects/home-manager-host.nix adds the jj-starship and
        # nushellWith overlays and the Home Manager settings.
        environment.systemPackages = [
          inputs.fh.packages.x86_64-linux.default
          pkgs.jj-starship
        ];
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
