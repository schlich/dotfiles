{
  config,
  den,
  inputs,
  ...
}:
{
  den.aspects.workstation = {
    meta = config.myConfig.aspectPolicy.workstation;
    # The Paseo daemon runs only where a host's `services.paseo` asks for it.
    includes = [ den.aspects.base ];
    nixos =
      { pkgs, ... }:
      {
        imports = [
          inputs.iets.nixosModules.default
          ../../modules/nixos/codex.nix
          ../../modules/nixos/docker.nix
        ];
        # iets answers nix, nix-build, nix-shell, nix-instantiate and
        # nix-eval-jobs, and runs the real Nix for what it lacks; the daemon
        # and store tools stay Nix. system-switch keeps the real Nix.
        iets.classic.enable = true;
        # den/aspects/home-manager-host.nix adds the nushellWith overlay and
        # the Home Manager settings. fh and jj-starship come from nixpkgs,
        # whose cache has them built; their flakes rebuilt them from source
        # on every nixpkgs update.
        environment.systemPackages = [
          pkgs.fh
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
