{
  inputs,
  lib,
  pkgs,
}:

# Luvus from its upstream flake, whose wrapper puts its runtime tools ahead of
# PATH: every pane the server spawns, agents included, ran plain git before the
# profile's wrapped git and committed without an identity. Append them
# instead, as that wrapper's own comment intends.
#
# Two open upstream pull requests make it work with a Nushell shell; their
# diffs are vendored in luvus-patches/ against the locked revision:
# - #546 types the task worker's launch line in Nushell syntax in a Nushell
#   pane, so `luvus task start` and the board start workers there;
# - #551 (with #550) runs luvus's remote POSIX scripts under `sh`, so
#   `--remote` and machine provisioning work when the remote login shell is
#   Nushell.
let
  upstream = inputs.luvus.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./luvus-patches/546-nushell-worker-launch.patch
      ./luvus-patches/551-remote-posix-under-sh.patch
    ];
  });
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
