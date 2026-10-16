{ lib, pkgs }:

# `closure-diff OLD NEW`: dix's package and version diff between two closures,
# whatever dix release nixpkgs carries. dix 3 moved the diff into a `diff`
# subcommand (`dix diff OLD NEW`); 2.x takes the paths directly. Choosing here
# keeps every caller working across that bump without an edit.
let
  inherit (pkgs) dix;
  diffArgs = lib.optional (lib.versionAtLeast dix.version "3") "diff";
in
pkgs.writeShellApplication {
  name = "closure-diff";
  # dix falls back to Nix commands when it cannot read the store database.
  runtimeInputs = [
    dix
    pkgs.nix
  ];
  text = ''
    if [ "$#" -ne 2 ]; then
      echo "Usage: closure-diff OLD NEW" >&2
      exit 2
    fi
    exec dix ${lib.escapeShellArgs diffArgs} "$1" "$2"
  '';
  meta.description = "Package and version diff between two Nix closures, through dix";
}
