{
  inputs,
  lib,
  pkgs,
}:

# Luvus from its upstream flake, whose wrapper puts its runtime tools ahead of
# PATH: every pane the server spawns, agents included, ran plain git before the
# profile's wrapped git and committed without an identity. Append them
# instead, as that wrapper's own comment intends.
let
  upstream = inputs.luvus.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
pkgs.runCommand "luvus-${upstream.version}"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    inherit (upstream) meta;
  }
  ''
    makeWrapper ${upstream}/bin/.luvus-wrapped "$out/bin/luvus" \
      --suffix PATH : ${
        lib.makeBinPath [
          pkgs.git
          pkgs.gh
          pkgs.openssh
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.procps
        ]
      }
  ''
