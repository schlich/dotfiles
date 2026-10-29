{
  lib,
  pkgs,
  ...
}:

let
  dagger = import ./dagger-package.nix { inherit lib pkgs; };
in
{
  # `dagger check` builds the flake checks in containers, the same checks that
  # Dagger Cloud runs after each push (docs/dagger.md).
  home.packages = [ dagger ];

  dotfiles.nixpkgsWatch.dagger = {
    inherit (dagger) version;
    reason = "replace modules/programs/dagger-package.nix with pkgs.dagger in dagger.nix and flake.nix";
  };
}
