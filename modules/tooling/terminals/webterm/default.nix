{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  webterm = import ./package.nix { inherit inputs lib pkgs; };
in
{
  home.packages = [ webterm ];

  dotfiles.nixpkgsWatch.webterm = {
    inherit (webterm) version;
    reason = "replace modules/tooling/terminals/webterm with pkgs.webterm and drop the webterm input";
  };
}
