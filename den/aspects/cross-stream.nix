{ config, ... }:

{
  # Workstations get cross.stream from Home Manager; this serves hosts
  # without it.
  den.aspects.cross-stream = {
    meta = config.myConfig.aspectPolicy.server;
    nixos.imports = [ ../../modules/nixos/cross-stream.nix ];
  };
}
