{ config, ... }:
{
  den.aspects.nix-observability = {
    meta = config.myConfig.aspectPolicy.nix-observability;
    nixos.imports = [ ../../modules/nixos/nix-observability.nix ];
  };

  # The home half, which users on a host with the viewer include
  # (den/aspects/users/schlich.nix): ci sends each dispatch and landing to the
  # viewer as a trace when the run ends; `ci trace export` sends the ones
  # recorded before. The port is the viewer's OTLP port in
  # modules/nixos/nix-observability.nix.
  den.aspects.nix-observability-home = {
    meta = config.myConfig.aspectPolicy.nix-observability;
    homeManager = {
      imports = [ ../../modules/programs/ci.nix ];
      dotfiles.ci.tracesEndpoint = "http://127.0.0.1:4318/v1/traces";
    };
  };
}
