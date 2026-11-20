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
  # Dagger Cloud runs after each push (docs/delivery/dagger.md).
  home.packages = [ dagger ];

  dotfiles.nixpkgsWatch.dagger = {
    inherit (dagger) version;
    repo = "dagger/dagger";
    reason = "replace modules/programs/vcs/dagger-package.nix with pkgs.dagger in dagger.nix and flake.nix";
  };
}
