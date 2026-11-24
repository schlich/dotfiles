{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  taskers = import ./package.nix { inherit inputs lib pkgs; };
in
{
  home.packages = [ taskers ];

  dotfiles.nixpkgsWatch.taskers = {
    inherit (taskers) version;
    reason = "replace modules/tooling/terminals/taskers with pkgs.taskers and drop the taskers input";
  };
}
